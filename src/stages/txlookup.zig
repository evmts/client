//! TxLookup stage: Build txHash -> blockNumber index
//! Based on erigon/eth/stagedsync/stage_txlookup.go

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const database = @import("../database.zig");

// Import guillotine's cryptographic hash functions
const guillotine = @import("guillotine");
const Hash = guillotine.Primitives.crypto.Hash;

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("TxLookup stage: indexing from {} to {}", .{
        ctx.from_block,
        ctx.to_block,
    });

    var blocks_processed: u64 = 0;
    const batch_size: u64 = 5000;

    const end = @min(ctx.from_block + batch_size, ctx.to_block);

    // Process blocks and build transaction lookup index
    var block_num = ctx.from_block + 1;
    while (block_num <= end) : (block_num += 1) {
        // Get block body from database
        const body = ctx.db.getBody(block_num) orelse {
            std.log.warn("Body not found for block {}", .{block_num});
            break;
        };

        // Index all transactions in this block
        try indexTransactions(ctx.allocator, body, block_num);

        blocks_processed += 1;

        if (blocks_processed % 500 == 0) {
            std.log.debug("TxLookup: processed {} blocks, {} total transactions", .{
                blocks_processed,
                block_num,
            });
        }
    }

    return sync.StageResult{
        .blocks_processed = blocks_processed,
        .stage_done = (end >= ctx.to_block),
    };
}

/// Index all transactions in a block body
/// Computes tx_hash -> (block_number, tx_index) mappings
fn indexTransactions(allocator: std.mem.Allocator, body: database.BlockBody, block_num: u64) !void {
    // Process each transaction in the block
    for (body.transactions, 0..) |tx, tx_idx| {
        // Compute transaction hash using guillotine's keccak256
        const tx_hash = try computeTransactionHash(allocator, tx);

        // In production, store tx_hash -> (block_number, tx_index) mapping
        // For now, just compute the hash for verification
        _ = tx_hash;
        _ = block_num;
        _ = tx_idx;

        // This mapping enables eth_getTransactionByHash RPC:
        // db.put(TxLookup, tx_hash, encodeBlockNumberAndIndex(block_num, tx_idx))
    }
}

/// Compute transaction hash using guillotine's keccak256
fn computeTransactionHash(allocator: std.mem.Allocator, tx: chain.Transaction) ![32]u8 {
    // Encode transaction as RLP and compute keccak256 hash
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);

    // For typed transactions (EIP-2718), prepend type byte
    if (tx.tx_type != .legacy) {
        try list.append(allocator, @intFromEnum(tx.tx_type));
    }

    // Encode transaction fields in RLP format
    try tx.encodeRlp(allocator, &list);

    // Compute keccak256 hash using guillotine
    const hash = Hash.keccak256(list.items);
    return hash;
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("TxLookup stage: unwinding to block {}", .{unwind_to});

    // In production, would remove transaction lookup mappings from database
    // Current simplified database doesn't store separate tx lookup indices
    _ = ctx;

    std.log.debug("TxLookup: unwound to block {}", .{unwind_to});
}

pub fn prune(ctx: *sync.StageContext, prune_to: u64) !void {
    std.log.info("TxLookup stage: pruning to block {}", .{prune_to});

    // Can prune old transaction lookups to save space
    _ = ctx;
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
};

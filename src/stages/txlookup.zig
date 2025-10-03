//! TxLookup stage: Build txHash -> blockNumber index
//! Based on erigon/eth/stagedsync/stage_txlookup.go

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const kv = @import("../kv/kv.zig");
const tables = @import("../kv/tables.zig");

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("TxLookup stage: indexing from {} to {}", .{
        ctx.from_block,
        ctx.to_block,
    });

    var blocks_processed: u64 = 0;
    const batch_size: u64 = 5000;

    const end = @min(ctx.from_block + batch_size, ctx.to_block);

    var tx = try ctx.kv_tx.beginTx(true);
    defer tx.commit() catch {};

    var block_num = ctx.from_block + 1;
    while (block_num <= end) : (block_num += 1) {
        // Get block body
        const block_key = tables.Encoding.encodeBlockNumber(block_num);
        const body_data = try tx.get(.Bodies, &block_key) orelse {
            std.log.warn("Body not found for block {}", .{block_num});
            break;
        };

        // Parse transactions and build lookup
        try indexTransactions(tx, block_num, body_data);

        blocks_processed += 1;

        if (blocks_processed % 500 == 0) {
            std.log.debug("TxLookup: processed {} blocks", .{blocks_processed});
        }
    }

    return sync.StageResult{
        .blocks_processed = blocks_processed,
        .stage_done = (end >= ctx.to_block),
    };
}

fn indexTransactions(tx: *kv.Transaction, block_num: u64, body_data: []const u8) !void {
    // Simplified: In production, decode RLP body, extract transaction hashes
    _ = body_data;

    // For each transaction in block:
    // tx.put(.TxLookup, tx_hash, block_number)

    // Store block number for quick access
    const block_key = tables.Encoding.encodeBlockNumber(block_num);
    _ = try tx.get(.Bodies, &block_key);
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("TxLookup stage: unwinding to block {}", .{unwind_to});

    var tx = try ctx.kv_tx.beginTx(true);
    defer tx.commit() catch {};

    // Remove transaction lookups for unwound blocks
    var block_num = unwind_to + 1;
    while (block_num <= ctx.to_block) : (block_num += 1) {
        const block_key = tables.Encoding.encodeBlockNumber(block_num);
        const body_data = try tx.get(.Bodies, &block_key) orelse continue;

        // Parse transactions and remove lookups
        _ = body_data; // Simplified
    }
}

pub fn prune(ctx: *sync.StageContext, prune_to: u64) !void {
    std.log.info("TxLookup stage: pruning to block {}", .{prune_to});

    // Can prune old transaction lookups to save space
    _ = ctx;
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
    .pruneFn = prune,
};

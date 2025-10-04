//! BlockHashes stage: Build blockNumber -> blockHash index
//! Based on erigon/eth/stagedsync/stage_blockhashes.go

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const database = @import("../database.zig");

// Import guillotine's cryptographic hash functions
const guillotine = @import("guillotine");
const Hash = guillotine.Primitives.crypto.Hash;

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("BlockHashes stage: building index from {} to {}", .{
        ctx.from_block,
        ctx.to_block,
    });

    var blocks_processed: u64 = 0;
    const batch_size: u64 = 10000;

    const end = @min(ctx.from_block + batch_size, ctx.to_block);

    // Process blocks and build hash index
    var block_num = ctx.from_block + 1;
    while (block_num <= end) : (block_num += 1) {
        // Get header from database
        const header = ctx.db.getHeader(block_num) orelse {
            std.log.warn("Header not found for block {}", .{block_num});
            break;
        };

        // Compute header hash using guillotine's keccak256
        const header_hash = try computeHeaderHash(ctx.allocator, header);

        // Store the hash mapping for fast lookups
        // In production, this would be stored in the database
        // For now, we're using the in-memory database which doesn't have
        // separate hash index tables. The hash can be recomputed on demand.

        _ = header_hash; // Hash computed but not stored in simplified DB

        blocks_processed += 1;

        if (blocks_processed % 1000 == 0) {
            std.log.debug("BlockHashes: processed {} blocks", .{blocks_processed});
        }
    }

    return sync.StageResult{
        .blocks_processed = blocks_processed,
        .stage_done = (end >= ctx.to_block),
    };
}

/// Compute the header hash using guillotine's keccak256
fn computeHeaderHash(allocator: std.mem.Allocator, header: chain.Header) ![32]u8 {
    // Encode header as RLP and compute keccak256 hash
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);

    // Encode header fields in RLP format
    try header.encodeRlp(allocator, &list);

    // Compute keccak256 hash using guillotine
    const hash = Hash.keccak256(list.items);
    return hash;
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("BlockHashes stage: unwinding to block {}", .{unwind_to});

    // In production, would remove hash mappings from database
    // Current simplified database doesn't store separate hash indices
    _ = ctx;

    std.log.debug("BlockHashes: unwound to block {}", .{unwind_to});
}

pub fn prune(ctx: *sync.StageContext, prune_to: u64) !void {
    _ = ctx;
    _ = prune_to;
    // BlockHashes are not pruned in Erigon
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
};

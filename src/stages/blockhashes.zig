//! BlockHashes stage: Build blockNumber -> blockHash index
//! Based on erigon/eth/stagedsync/stage_blockhashes.go

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const kv = @import("../kv/kv.zig");
const tables = @import("../kv/tables.zig");

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("BlockHashes stage: building index from {} to {}", .{
        ctx.from_block,
        ctx.to_block,
    });

    var blocks_processed: u64 = 0;
    const batch_size: u64 = 10000;

    const end = @min(ctx.from_block + batch_size, ctx.to_block);

    var tx = try ctx.kv_tx.beginTx(true);
    defer tx.commit() catch {};

    var block_num = ctx.from_block + 1;
    while (block_num <= end) : (block_num += 1) {
        // Get header
        const header_key = tables.Encoding.encodeBlockNumber(block_num);
        const header_data = try tx.get(.Headers, &header_key) orelse {
            std.log.warn("Header not found for block {}", .{block_num});
            break;
        };

        // Extract hash from header (first 32 bytes after RLP decoding)
        // Simplified: In production, properly decode RLP header
        var hash: [32]u8 = undefined;
        const hash_data = try std.crypto.hash.sha3.Keccak256.hash(header_data, .{});
        @memcpy(&hash, &hash_data);

        // Store blockNumber -> blockHash mapping
        try tx.put(.CanonicalHashes, &header_key, &hash);

        // Store blockHash -> blockNumber mapping
        try tx.put(.HeaderNumbers, &hash, &header_key);

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

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("BlockHashes stage: unwinding to block {}", .{unwind_to});

    var tx = try ctx.kv_tx.beginTx(true);
    defer tx.commit() catch {};

    // Remove block hashes from unwind_to+1 onwards
    var block_num = unwind_to + 1;
    while (block_num <= ctx.to_block) : (block_num += 1) {
        const header_key = tables.Encoding.encodeBlockNumber(block_num);

        // Get hash before deleting
        if (try tx.get(.CanonicalHashes, &header_key)) |hash| {
            try tx.delete(.HeaderNumbers, hash);
        }

        try tx.delete(.CanonicalHashes, &header_key);
    }
}

pub fn prune(ctx: *sync.StageContext, prune_to: u64) !void {
    _ = ctx;
    _ = prune_to;
    // BlockHashes are not pruned in Erigon
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
    .pruneFn = prune,
};

//! Senders stage: Recover transaction senders via ECDSA
//! Based on erigon/eth/stagedsync/stage_senders.go

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const kv = @import("../kv/kv.zig");
const tables = @import("../kv/tables.zig");

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("Senders stage: recovering from {} to {}", .{
        ctx.from_block,
        ctx.to_block,
    });

    var blocks_processed: u64 = 0;
    const batch_size: u64 = 1000;

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

        // Parse transactions from body
        // Simplified: In production, properly decode RLP bodies
        const senders = try recoverSenders(ctx.allocator, body_data);
        defer ctx.allocator.free(senders);

        // Store senders
        if (senders.len > 0) {
            try tx.put(.Senders, &block_key, senders);
        }

        blocks_processed += 1;

        if (blocks_processed % 100 == 0) {
            std.log.debug("Senders: processed {} blocks", .{blocks_processed});
        }
    }

    return sync.StageResult{
        .blocks_processed = blocks_processed,
        .stage_done = (end >= ctx.to_block),
    };
}

fn recoverSenders(allocator: std.mem.Allocator, body_data: []const u8) ![]u8 {
    // Simplified: In production, decode RLP body, extract transactions,
    // recover ECDSA public keys, derive addresses
    _ = body_data;

    // Return empty senders list for now
    return try allocator.alloc(u8, 0);
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("Senders stage: unwinding to block {}", .{unwind_to});

    var tx = try ctx.kv_tx.beginTx(true);
    defer tx.commit() catch {};

    var block_num = unwind_to + 1;
    while (block_num <= ctx.to_block) : (block_num += 1) {
        const block_key = tables.Encoding.encodeBlockNumber(block_num);
        try tx.delete(.Senders, &block_key);
    }
}

pub fn prune(ctx: *sync.StageContext, prune_to: u64) !void {
    _ = ctx;
    _ = prune_to;
    // Senders can be pruned for full nodes
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
    .pruneFn = prune,
};

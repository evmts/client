//! Headers stage: Download and validate block headers

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const database = @import("../database.zig");

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("Headers stage: syncing from {} to {}", .{ ctx.from_block, ctx.to_block });

    // In production: Download headers from P2P network
    // For minimal implementation: Generate synthetic headers
    var blocks_processed: u64 = 0;
    const batch_size: u64 = 1000;

    const end = @min(ctx.from_block + batch_size, ctx.to_block);

    var block_num = ctx.from_block + 1;
    while (block_num <= end) : (block_num += 1) {
        const header = try generateSyntheticHeader(ctx.allocator, block_num);
        try ctx.db.putHeader(block_num, header);
        blocks_processed += 1
;
    }

    return sync.StageResult{
        .blocks_processed = blocks_processed,
        .stage_done = (end >= ctx.to_block),
    };
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("Headers stage: unwinding to block {}", .{unwind_to});

    // In production: Remove headers and update canonical chain
    // For minimal implementation: Just log the unwind
    _ = ctx;
}

fn generateSyntheticHeader(allocator: std.mem.Allocator, number: u64) !chain.Header {
    _ = allocator;
    const primitives = @import("primitives");

    var parent_hash = [_]u8{0} ** 32;
    if (number > 0) {
        // Simple parent hash derivation
        std.mem.writeInt(u64, parent_hash[0..8], number - 1, .big);
    }

    return chain.Header{
        .parent_hash = parent_hash,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = chain.U256.zero(),
        .number = number,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 1609459200 + (number * 12), // ~12 second blocks
        .extra_data = &[_]u8{},
        .mix_digest = [_]u8{0} ** 32,
        .nonce = chain.encodeNonce(0),
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = chain.U256.fromInt(1000000000), // 1 gwei
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
    };
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
};

test "headers stage execution" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    var ctx = sync.StageContext{
        .allocator = std.testing.allocator,
        .db = &db,
        .stage = .headers,
        .from_block = 0,
        .to_block = 10,
    };

    const result = try execute(&ctx);
    try std.testing.expect(result.blocks_processed > 0);

    // Verify headers were stored
    const header = db.getHeader(1);
    try std.testing.expect(header != null);
    try std.testing.expectEqual(@as(u64, 1), header.?.number);
}

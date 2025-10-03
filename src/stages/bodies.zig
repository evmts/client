//! Bodies stage: Download block bodies (transactions)

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const database = @import("../database.zig");

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("Bodies stage: syncing from {} to {}", .{ ctx.from_block, ctx.to_block });

    // In production: Download bodies from P2P network
    // For minimal implementation: Generate synthetic bodies
    var blocks_processed: u64 = 0;
    const batch_size: u64 = 500;

    const end = @min(ctx.from_block + batch_size, ctx.to_block);

    var block_num = ctx.from_block + 1;
    while (block_num <= end) : (block_num += 1) {
        // Verify header exists first (staged sync invariant)
        const header = ctx.db.getHeader(block_num) orelse {
            std.log.err("Header not found for block {}", .{block_num});
            return error.HeaderNotFound;
        };
        _ = header;

        const body = try generateSyntheticBody(ctx.allocator);
        try ctx.db.putBody(block_num, body);
        blocks_processed += 1;
    }

    return sync.StageResult{
        .blocks_processed = blocks_processed,
        .stage_done = (end >= ctx.to_block),
    };
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("Bodies stage: unwinding to block {}", .{unwind_to});
    _ = ctx;
}

fn generateSyntheticBody(allocator: std.mem.Allocator) !database.BlockBody {
    // Empty block for simplicity
    const transactions = try allocator.alloc(chain.Transaction, 0);
    const uncles = try allocator.alloc(chain.Header, 0);

    return database.BlockBody{
        .transactions = transactions,
        .uncles = uncles,
    };
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
};

test "bodies stage execution" {
    const primitives = @import("primitives");
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    // Setup: Add headers first
    const header = chain.Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = primitives.U256.zero(),
        .number = 1,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 0,
        .extra_data = &[_]u8{},
        .mix_hash = [_]u8{0} ** 32,
        .nonce = 0,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
    };
    try db.putHeader(1, header);

    var ctx = sync.StageContext{
        .allocator = std.testing.allocator,
        .db = &db,
        .stage = .bodies,
        .from_block = 0,
        .to_block = 1,
    };

    const result = try execute(&ctx);
    try std.testing.expectEqual(@as(u64, 1), result.blocks_processed);

    // Verify body was stored
    const body = db.getBody(1);
    try std.testing.expect(body != null);
}

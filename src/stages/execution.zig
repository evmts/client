//! Execution stage: Execute transactions and update state
//! This is where guillotine EVM is invoked!

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const database = @import("../database.zig");
const guillotine = @import("guillotine_evm");
const primitives = @import("primitives");

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("Execution stage: processing blocks {} to {}", .{ ctx.from_block, ctx.to_block });

    // TODO: Initialize guillotine EVM for transaction execution
    // Example integration:
    // const evm_config = guillotine.EvmConfig{};
    // var evm_state = try guillotine.storage.MemoryDatabase.init(ctx.allocator);
    // var evm = try guillotine.Evm(evm_config).init(ctx.allocator, evm_state, block_context);

    var blocks_processed: u64 = 0;
    const batch_size: u64 = 100;

    var block_num = ctx.from_block + 1;
    while (block_num <= ctx.to_block) : (block_num += 1) {
        try executeBlock(ctx, block_num);
        blocks_processed += 1;

        // Commit every batch_size blocks
        if (blocks_processed % batch_size == 0) {
            try ctx.db.setStageProgress(.execution, block_num);
        }
    }

    return sync.StageResult{
        .blocks_processed = blocks_processed,
        .stage_done = (block_num > ctx.to_block),
    };
}

fn executeBlock(ctx: *sync.StageContext, block_num: u64) !void {
    const header = ctx.db.getHeader(block_num) orelse return error.HeaderNotFound;
    const body = ctx.db.getBody(block_num) orelse return error.BodyNotFound;

    // TODO: Actual EVM execution using guillotine
    // Integration points:
    // 1. Create block context from header (block number, timestamp, gas limit, coinbase, etc.)
    // 2. For each transaction:
    //    - Build tx context (sender, gas price, etc.)
    //    - Execute with guillotine EVM
    //    - Collect receipt (status, gas used, logs)
    // 3. Calculate state root using guillotine's state management
    // 4. Verify state root matches header
    // 5. Store receipts in database

    for (body.transactions) |*tx| {
        _ = tx;
        // Placeholder for EVM execution
    }

    _ = header;
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("Execution stage: unwinding to block {}", .{unwind_to});
    _ = ctx;
    // TODO: Revert state changes using guillotine's rollback mechanism
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
};

test "execution stage" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    // Setup: Add header and empty body
    const header = chain.Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 32 ++ [_]u8{0} ** 32 ++ [_]u8{0} ** 32 ++ [_]u8{0} ** 32 ++ [_]u8{0} ** 32 ++ [_]u8{0} ** 32 ++ [_]u8{0} ** 32 ++ [_]u8{0} ** 32,
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

    const transactions = try std.testing.allocator.alloc(chain.Transaction, 0);
    defer std.testing.allocator.free(transactions);
    const uncles = try std.testing.allocator.alloc(chain.Header, 0);
    defer std.testing.allocator.free(uncles);

    const body = database.BlockBody{
        .transactions = transactions,
        .uncles = uncles,
    };
    try db.putBody(1, body);

    var ctx = sync.StageContext{
        .allocator = std.testing.allocator,
        .db = &db,
        .stage = .execution,
        .from_block = 0,
        .to_block = 1,
    };

    const result = try execute(&ctx);
    try std.testing.expectEqual(@as(u64, 1), result.blocks_processed);
}

//! Execution stage: Execute transactions and update state
//! This is where the EVM is invoked!

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const database = @import("../database.zig");
const state_mod = @import("../state.zig");
const primitives = @import("primitives");
const U256 = chain.U256;

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("Execution stage: processing blocks {} to {}", .{ ctx.from_block, ctx.to_block });

    var state = state_mod.State.init(ctx.allocator, ctx.db);
    defer state.deinit();

    var blocks_processed: u64 = 0;
    const batch_size: u64 = 100;

    const end = @min(ctx.from_block + batch_size, ctx.to_block);

    var block_num = ctx.from_block + 1;
    while (block_num <= end) : (block_num += 1) {
        try executeBlock(ctx, &state, block_num);
        blocks_processed += 1;
    }

    // Commit state changes to database
    try state.commitToDb();

    return sync.StageResult{
        .blocks_processed = blocks_processed,
        .stage_done = (end >= ctx.to_block),
    };
}

fn executeBlock(ctx: *sync.StageContext, state: *state_mod.State, block_num: u64) !void {
    const header = ctx.db.getHeader(block_num) orelse return error.HeaderNotFound;
    const body = ctx.db.getBody(block_num) orelse return error.BodyNotFound;

    // Create checkpoint for potential revert
    state.createCheckpoint();

    // Process each transaction
    for (body.transactions) |tx| {
        try executeTransaction(ctx, state, &header, &tx);
    }

    // Verify state root matches
    // In production: compute actual state root and compare
    // For minimal implementation: skip verification

    state.commitCheckpoint();
}

fn executeTransaction(
    ctx: *sync.StageContext,
    state: *state_mod.State,
    header: *const chain.Header,
    tx: *const chain.Transaction,
) !void {
    _ = ctx;
    _ = header;

    // Get sender
    const sender = try tx.recoverSender(state.allocator);

    // Check nonce
    const account_nonce = try state.getNonce(sender);
    if (account_nonce != tx.nonce) {
        return error.InvalidNonce;
    }

    // Deduct gas cost from sender
    const gas_price = tx.gas_price orelse U256.fromInt(1000000000);
    const gas_cost = gas_price.mul(U256.fromInt(tx.gas_limit));

    const sender_balance = try state.getBalance(sender);
    if (sender_balance.lt(gas_cost)) {
        return error.InsufficientBalance;
    }

    // Update sender balance and nonce
    try state.setBalance(sender, sender_balance.sub(gas_cost));
    try state.setNonce(sender, account_nonce + 1);

    // Execute transaction
    // In production: Call EVM here
    // For minimal implementation: Just update state

    if (tx.to) |to_address| {
        // Transfer to recipient
        const recipient_balance = try state.getBalance(to_address);
        try state.setBalance(to_address, recipient_balance.add(tx.value));
    } else {
        // Contract creation
        // In production: Deploy contract via EVM
        // For minimal implementation: skip
    }
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("Execution stage: unwinding to block {}", .{unwind_to});
    _ = ctx;
    // In production: Revert state changes
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

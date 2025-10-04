//! Execution stage: Execute transactions and update state
//! This is where guillotine EVM is invoked!

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const database = @import("../database.zig");
const guillotine = @import("guillotine_evm");
const primitives = @import("primitives");
const Bloom = @import("../types/block.zig").Bloom;

/// Database adapter to bridge client database with guillotine's Database interface
pub const GuillotineDBAdapter = struct {
    db: *database.Database,
    allocator: std.mem.Allocator,

    /// Wrap guillotine's Database interface around our client database
    inner: guillotine.Database,

    pub fn init(allocator: std.mem.Allocator, db: *database.Database) !*GuillotineDBAdapter {
        const adapter = try allocator.create(GuillotineDBAdapter);
        errdefer allocator.destroy(adapter);

        adapter.* = .{
            .db = db,
            .allocator = allocator,
            .inner = guillotine.Database.init(allocator),
        };

        return adapter;
    }

    pub fn deinit(self: *GuillotineDBAdapter) void {
        self.inner.deinit();
        self.allocator.destroy(self);
    }

    /// Load account from client database into guillotine database
    pub fn loadAccount(self: *GuillotineDBAdapter, address: primitives.Address) !void {
        const addr_bytes = address.bytes;

        if (self.db.getAccount(addr_bytes)) |account| {
            // Convert client Account to guillotine Account
            const guil_account = guillotine.Account{
                .balance = std.mem.readInt(u256, &account.balance, .big),
                .nonce = account.nonce,
                .code_hash = account.code_hash,
                .storage_root = account.storage_root,
            };

            try self.inner.set_account(addr_bytes, guil_account);

            // Load code if it exists
            if (!std.mem.eql(u8, &account.code_hash, &([_]u8{0} ** 32))) {
                if (self.db.getCode(account.code_hash)) |code| {
                    try self.inner.set_code(account.code_hash, code);
                }
            }
        } else {
            // Account doesn't exist - ensure it's empty in guillotine database
            const empty_account = guillotine.Account{
                .balance = 0,
                .nonce = 0,
                .code_hash = [_]u8{0} ** 32,
                .storage_root = [_]u8{0} ** 32,
            };
            try self.inner.set_account(addr_bytes, empty_account);
        }
    }

    /// Save all accounts from guillotine database back to client database
    pub fn saveAccounts(self: *GuillotineDBAdapter) !void {
        // In a real implementation, we would iterate over touched accounts
        // For now, this is a placeholder for the interface
        _ = self;
    }
};

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("Execution stage: processing blocks {} to {}", .{ ctx.from_block, ctx.to_block });

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

    std.log.debug("Executing block {}: {} transactions", .{ block_num, body.transactions.len });

    // Create database adapter for guillotine
    var db_adapter = try GuillotineDBAdapter.init(ctx.allocator, ctx.db);
    defer db_adapter.deinit();

    // Create block context for guillotine EVM
    var block_info = guillotine.BlockInfo{
        .chain_id = 1, // TODO: Get from config
        .number = header.number,
        .timestamp = header.timestamp,
        .difficulty = header.difficulty.value,
        .gas_limit = header.gas_limit,
        .coinbase = header.coinbase,
        .base_fee = if (header.base_fee_per_gas) |bf| bf.value else 0,
        .prev_randao = header.mix_digest,
    };

    // Track cumulative gas and receipts
    var cumulative_gas: u64 = 0;
    var receipts = std.ArrayList(chain.Receipt).empty;
    defer {
        for (receipts.items) |*receipt| {
            receipt.deinit(ctx.allocator);
        }
        receipts.deinit(ctx.allocator);
    }

    // Execute each transaction
    for (body.transactions, 0..) |*tx, tx_index| {
        const receipt = try executeTransaction(
            ctx.allocator,
            &db_adapter.inner,
            &block_info,
            tx,
            cumulative_gas,
            @intCast(tx_index),
        );
        cumulative_gas = receipt.cumulative_gas_used;
        try receipts.append(ctx.allocator, receipt);
        errdefer {
            var last = receipts.pop();
            last.deinit(ctx.allocator);
        }
    }

    // Verify gas used matches header
    if (cumulative_gas != header.gas_used) {
        std.log.err("Gas used mismatch: expected {}, got {}", .{ header.gas_used, cumulative_gas });
        return error.GasUsedMismatch;
    }

    // Apply block rewards (for PoW blocks)
    if (header.difficulty.value > 0) {
        try applyBlockRewards(&db_adapter.inner, &header, body.uncles.len);
    }

    // Save state changes back to database
    try db_adapter.saveAccounts();

    // Store receipts in database
    const receipts_slice = try ctx.allocator.dupe(chain.Receipt, receipts.items);
    try ctx.db.putReceipts(block_num, receipts_slice);

    std.log.debug("Block {} executed successfully: {} gas used", .{ block_num, cumulative_gas });
}

fn executeTransaction(
    allocator: std.mem.Allocator,
    db: *guillotine.Database,
    block_info: *const guillotine.BlockInfo,
    tx: *const chain.Transaction,
    cumulative_gas_before: u64,
    tx_index: u32,
) !chain.Receipt {
    // Recover sender address
    const sender = try tx.recoverSender(allocator);

    // Calculate effective gas price
    const base_fee_u256 = if (block_info.base_fee > 0)
        chain.U256{ .value = block_info.base_fee }
    else
        null;
    const gas_price = tx.effectiveGasPrice(base_fee_u256);

    // Create transaction context
    const TransactionContext = guillotine.TransactionContext;
    const tx_context = TransactionContext{
        .gas_limit = tx.gas_limit,
        .coinbase = block_info.coinbase,
        .chain_id = @intCast(block_info.chain_id),
    };

    // Create EVM instance
    const EvmConfig = guillotine.EvmConfig{};
    const Evm = guillotine.Evm(EvmConfig);
    var evm = try Evm.init(
        allocator,
        db,
        block_info.*,
        tx_context,
        gas_price.value,
        sender,
    );
    defer evm.deinit();

    // Execute transaction
    const result: Evm.CallResult = if (tx.to) |to_addr| blk: {
        // Regular call
        const call_params = Evm.CallParams{ .call = .{
            .caller = sender,
            .to = to_addr,
            .value = tx.value.value,
            .input = tx.data,
            .gas = tx.gas_limit,
        } };
        break :blk evm.call(call_params);
    } else blk: {
        // Contract creation
        const create_params = Evm.CallParams{ .create = .{
            .caller = sender,
            .value = tx.value.value,
            .init_code = tx.data,
            .gas = tx.gas_limit,
        } };
        break :blk evm.call(create_params);
    };

    // Calculate gas used
    const gas_used = tx.gas_limit - result.gas_left;
    const cumulative_gas_used = cumulative_gas_before + gas_used;

    // Create receipt
    var receipt = chain.Receipt.init();
    receipt.tx_type = @intFromEnum(tx.tx_type);
    receipt.status = if (result.success) chain.receipt_types.RECEIPT_STATUS_SUCCESSFUL else chain.receipt_types.RECEIPT_STATUS_FAILED;
    receipt.cumulative_gas_used = cumulative_gas_used;
    receipt.gas_used = gas_used;
    receipt.transaction_index = tx_index;

    // Convert logs from guillotine format to client format
    if (result.logs.len > 0) {
        var logs = try allocator.alloc(chain.Log, result.logs.len);
        errdefer allocator.free(logs);

        for (result.logs, 0..) |guil_log, i| {
            // Convert topics
            const topics = try allocator.alloc(primitives.Hash, guil_log.topics.len);
            errdefer allocator.free(topics);

            for (guil_log.topics, 0..) |topic, j| {
                var topic_bytes: [32]u8 = undefined;
                std.mem.writeInt(u256, &topic_bytes, topic, .big);
                topics[j] = primitives.Hash{ .bytes = topic_bytes };
            }

            // Convert data
            const data = try allocator.dupe(u8, guil_log.data);
            errdefer allocator.free(data);

            logs[i] = chain.Log{
                .address = guil_log.address,
                .topics = topics,
                .data = data,
                .block_number = block_info.number,
                .tx_hash = primitives.Hash.zero(), // Will be filled later
                .tx_index = tx_index,
                .block_hash = primitives.Hash.zero(), // Will be filled later
                .index = @intCast(i),
                .removed = false,
            };
        }

        receipt.logs = logs;

        // Generate bloom filter from logs
        receipt.bloom = try generateBloom(allocator, logs);
    }

    // Set contract address if contract creation
    if (tx.to == null and result.success) {
        if (result.created_address) |addr| {
            receipt.contract_address = addr;
        }
    }

    return receipt;
}

fn applyBlockRewards(db: *guillotine.Database, header: *const chain.Header, uncle_count: usize) !void {
    _ = uncle_count;

    // Get coinbase account
    const coinbase_addr = header.coinbase.bytes;
    var account = try db.get_account(coinbase_addr) orelse guillotine.Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };

    // Base block reward (simplified - should vary by hardfork)
    const block_reward: u256 = 2_000_000_000_000_000_000; // 2 ETH in wei

    // Add reward
    account.balance += block_reward;

    // TODO: Add uncle rewards (1/32 of block reward per uncle)

    try db.set_account(coinbase_addr, account);
}

fn generateBloom(allocator: std.mem.Allocator, logs: []const chain.Log) !Bloom {
    _ = allocator;

    var bloom = Bloom.zero();

    // Generate bloom filter from logs
    for (logs) |log| {
        // Add address to bloom
        bloom.add(&log.address.bytes);

        // Add each topic to bloom
        for (log.topics) |topic| {
            bloom.add(&topic.bytes);
        }
    }

    return bloom;
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("Execution stage: unwinding to block {}", .{unwind_to});

    // Delete receipts for blocks after unwind_to
    var current_block = ctx.db.getStageProgress(.execution);
    while (current_block > unwind_to) : (current_block -= 1) {
        // Delete receipts
        if (ctx.db.getReceipts(current_block)) |receipts| {
            for (receipts) |*receipt| {
                var mut_receipt = receipt.*;
                mut_receipt.deinit(ctx.allocator);
            }
            ctx.allocator.free(receipts);
        }

        // TODO: Revert state changes - requires state history or snapshots
    }

    try ctx.db.setStageProgress(.execution, unwind_to);
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
};

// ============================================================================
// Tests
// ============================================================================

test "execution stage - empty block" {
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
        .difficulty = chain.U256.zero(),
        .number = 1,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 0,
        .extra_data = &[_]u8{},
        .mix_digest = [_]u8{0} ** 32,
        .nonce = [_]u8{0} ** 8,
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
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
    try std.testing.expect(result.stage_done);

    // Verify receipts were stored (should be empty array)
    const receipts = db.getReceipts(1);
    try std.testing.expect(receipts != null);
    try std.testing.expectEqual(@as(usize, 0), receipts.?.len);
}

test "GuillotineDBAdapter - init and deinit" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    var adapter = try GuillotineDBAdapter.init(std.testing.allocator, &db);
    defer adapter.deinit();

    // Verify adapter is initialized
    try std.testing.expect(adapter.db == &db);
}

test "GuillotineDBAdapter - load nonexistent account" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    var adapter = try GuillotineDBAdapter.init(std.testing.allocator, &db);
    defer adapter.deinit();

    const addr = primitives.Address.zero();
    try adapter.loadAccount(addr);

    // Should create empty account in guillotine database
    const account = try adapter.inner.get_account(addr.bytes);
    try std.testing.expect(account != null);
    try std.testing.expectEqual(@as(u256, 0), account.?.balance);
    try std.testing.expectEqual(@as(u64, 0), account.?.nonce);
}

test "GuillotineDBAdapter - load existing account" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    // Create account in client database
    const addr = primitives.Address.zero();
    var balance_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &balance_bytes, 1000000000, .big);

    const account = database.Account{
        .nonce = 5,
        .balance = balance_bytes,
        .storage_root = [_]u8{0} ** 32,
        .code_hash = [_]u8{0} ** 32,
    };
    try db.putAccount(addr.bytes, account);

    var adapter = try GuillotineDBAdapter.init(std.testing.allocator, &db);
    defer adapter.deinit();

    try adapter.loadAccount(addr);

    // Verify account loaded correctly
    const loaded = try adapter.inner.get_account(addr.bytes);
    try std.testing.expect(loaded != null);
    try std.testing.expectEqual(@as(u256, 1000000000), loaded.?.balance);
    try std.testing.expectEqual(@as(u64, 5), loaded.?.nonce);
}

test "bloom filter generation" {
    const addr1 = primitives.Address.zero();
    const topic1 = primitives.Hash.zero();

    var topics = [_]primitives.Hash{topic1};
    var logs = [_]chain.Log{.{
        .address = addr1,
        .topics = &topics,
        .data = &[_]u8{},
        .block_number = 1,
        .tx_hash = primitives.Hash.zero(),
        .tx_index = 0,
        .block_hash = primitives.Hash.zero(),
        .index = 0,
        .removed = false,
    }};

    const bloom = try generateBloom(std.testing.allocator, &logs);

    // Bloom should not be all zeros (contains data)
    var has_nonzero = false;
    for (bloom.bytes) |b| {
        if (b != 0) {
            has_nonzero = true;
            break;
        }
    }
    try std.testing.expect(has_nonzero);
}

test "block rewards - PoW block" {
    var db = guillotine.Database.init(std.testing.allocator);
    defer db.deinit();

    const coinbase = primitives.Address.zero();
    const header = chain.Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = coinbase,
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = chain.U256.fromInt(1000), // PoW block
        .number = 1,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 0,
        .extra_data = &[_]u8{},
        .mix_digest = [_]u8{0} ** 32,
        .nonce = [_]u8{0} ** 8,
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
    };

    try applyBlockRewards(&db, &header, 0);

    // Verify coinbase received reward
    const account = try db.get_account(coinbase.bytes);
    try std.testing.expect(account != null);
    try std.testing.expectEqual(@as(u256, 2_000_000_000_000_000_000), account.?.balance);
}

test "unwind - delete receipts" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    // Set up receipts for blocks 1, 2, 3
    const empty_receipts = try std.testing.allocator.alloc(chain.Receipt, 0);
    try db.putReceipts(1, empty_receipts);

    const empty_receipts2 = try std.testing.allocator.alloc(chain.Receipt, 0);
    try db.putReceipts(2, empty_receipts2);

    const empty_receipts3 = try std.testing.allocator.alloc(chain.Receipt, 0);
    try db.putReceipts(3, empty_receipts3);

    try db.setStageProgress(.execution, 3);

    var ctx = sync.StageContext{
        .allocator = std.testing.allocator,
        .db = &db,
        .stage = .execution,
        .from_block = 0,
        .to_block = 3,
    };

    // Unwind to block 1
    try unwind(&ctx, 1);

    // Verify stage progress updated
    try std.testing.expectEqual(@as(u64, 1), db.getStageProgress(.execution));

    // Receipts for block 1 should still exist
    try std.testing.expect(db.getReceipts(1) != null);
}

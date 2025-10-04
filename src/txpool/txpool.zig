//! Transaction pool (mempool)
//! Based on erigon/txnprovider and erigon-lib/txpool
//!
//! Manages pending transactions before they're included in blocks

const std = @import("std");
const chain = @import("../chain.zig");
const primitives = @import("primitives");
const crypto = primitives.crypto;
const GasConstants = primitives.GasConstants;

/// Transaction pool configuration
pub const TxPoolConfig = struct {
    /// Maximum number of pending transactions
    max_pending: usize,
    /// Maximum number of queued transactions
    max_queued: usize,
    /// Price bump percentage for replacement (10 = 10%)
    price_bump: u8,
    /// Account slots (transactions per account)
    account_slots: usize,
    /// Global slots (total pool size)
    global_slots: usize,
    /// Lifetime of transactions in pool (seconds)
    lifetime: u64,
    /// Minimum gas price to accept (wei)
    min_gas_price: u256,
    /// Block gas limit for validation
    block_gas_limit: u64,

    pub fn default() TxPoolConfig {
        return .{
            .max_pending = 10000,
            .max_queued = 5000,
            .price_bump = 10, // 10% bump required for replacement
            .account_slots = 16,
            .global_slots = 10000,
            .lifetime = 3 * 3600, // 3 hours in seconds
            .min_gas_price = 1_000_000_000, // 1 gwei
            .block_gas_limit = 30_000_000,
        };
    }
};

/// Transaction validation error
pub const TxValidationError = error{
    /// Transaction nonce is too low
    NonceTooLow,
    /// Transaction nonce is too high (gap)
    NonceTooHigh,
    /// Insufficient funds for gas * price + value
    InsufficientFunds,
    /// Gas limit exceeds block gas limit
    GasLimitExceeded,
    /// Intrinsic gas too low
    IntrinsicGasTooLow,
    /// Transaction already in pool
    AlreadyKnown,
    /// Replacement transaction underpriced
    Underpriced,
    /// Transaction pool is full
    TxPoolFull,
    /// Invalid signature
    InvalidSignature,
    /// Gas price too low
    GasPriceTooLow,
    /// Too many transactions from sender
    TooManyTransactionsFromSender,
} || std.mem.Allocator.Error;

/// Transaction status in pool
pub const TxStatus = enum {
    /// Transaction is pending (executable)
    pending,
    /// Transaction is queued (waiting for nonce gap)
    queued,
    /// Transaction is being processed
    processing,
};

/// Pool transaction with metadata
pub const PoolTransaction = struct {
    tx: chain.Transaction,
    tx_hash: [32]u8,
    from: [20]u8,
    status: TxStatus,
    timestamp: u64,
    gas_price: u256,

    pub fn effectiveGasPrice(self: *const PoolTransaction, base_fee: ?u64) u256 {
        return switch (self.tx.tx_type) {
            .legacy, .access_list => self.gas_price,
            .dynamic_fee => blk: {
                const tip = self.tx.gas_tip_cap orelse chain.U256.fromInt(0);
                const cap = self.tx.gas_fee_cap orelse chain.U256.fromInt(0);
                const base = if (base_fee) |bf| chain.U256.fromInt(bf) else chain.U256.fromInt(0);

                // min(tip, cap - base_fee) + base_fee
                const max_tip = if (cap.value > base.value)
                    chain.U256{ .value = cap.value - base.value }
                else
                    chain.U256.fromInt(0);

                const effective_tip = if (tip.value < max_tip.value) tip else max_tip;
                break :blk chain.U256{ .value = effective_tip.value + base.value };
            },
            else => self.gas_price,
        };
    }
};

/// Account state for balance/nonce tracking
pub const AccountState = struct {
    balance: u256,
    nonce: u64,
};

/// Transaction pool
pub const TxPool = struct {
    allocator: std.mem.Allocator,
    config: TxPoolConfig,
    /// Pending transactions (ready to be mined) - sorted by gas price
    pending_txs: std.AutoHashMap([20]u8, std.ArrayList(PoolTransaction)),
    /// Queued transactions (future nonces) - sorted by nonce
    queued_txs: std.AutoHashMap([20]u8, std.ArrayList(PoolTransaction)),
    /// All transactions by hash
    all: std.AutoHashMap([32]u8, *PoolTransaction),
    /// Account states (balance and nonce)
    accounts: std.AutoHashMap([20]u8, AccountState),

    pub fn init(allocator: std.mem.Allocator, config: TxPoolConfig) TxPool {
        return .{
            .allocator = allocator,
            .config = config,
            .pending_txs = std.AutoHashMap([20]u8, std.ArrayList(PoolTransaction)).init(allocator),
            .queued_txs = std.AutoHashMap([20]u8, std.ArrayList(PoolTransaction)).init(allocator),
            .all = std.AutoHashMap([32]u8, *PoolTransaction).init(allocator),
            .accounts = std.AutoHashMap([20]u8, AccountState).init(allocator),
        };
    }

    pub fn deinit(self: *TxPool) void {
        // Free pending transactions
        var pending_iter = self.pending_txs.valueIterator();
        while (pending_iter.next()) |txs| {
            txs.deinit(self.allocator);
        }
        self.pending_txs.deinit();

        // Free queued transactions
        var queued_iter = self.queued_txs.valueIterator();
        while (queued_iter.next()) |txs| {
            txs.deinit(self.allocator);
        }
        self.queued_txs.deinit();

        // Free all transactions map
        var all_iter = self.all.valueIterator();
        while (all_iter.next()) |tx_ptr| {
            self.allocator.destroy(tx_ptr.*);
        }
        self.all.deinit();

        self.accounts.deinit();
    }

    /// Set account state for validation
    pub fn setAccountState(self: *TxPool, address: [20]u8, balance: u256, nonce: u64) !void {
        try self.accounts.put(address, .{ .balance = balance, .nonce = nonce });
    }

    /// Add transaction to pool with full validation
    pub fn add(self: *TxPool, tx: chain.Transaction) TxValidationError!void {
        // Recover sender address with signature verification
        const from = try self.recoverSender(&tx);

        // Calculate transaction hash
        const tx_hash = try tx.hash(self.allocator);

        // Check if already in pool
        if (self.all.contains(tx_hash)) {
            // Check if this is a replacement transaction
            try self.handleReplacement(tx_hash, &tx, from);
            return;
        }

        // Get account state
        const account = self.accounts.get(from) orelse .{
            .balance = 0,
            .nonce = 0,
        };

        // Validate transaction
        try self.validateTransaction(&tx, from, account);

        // Create pool transaction
        const gas_price = self.extractGasPrice(&tx);
        const pool_tx_ptr = try self.allocator.create(PoolTransaction);
        errdefer self.allocator.destroy(pool_tx_ptr);

        pool_tx_ptr.* = PoolTransaction{
            .tx = tx,
            .tx_hash = tx_hash,
            .from = from,
            .status = if (tx.nonce == account.nonce) .pending else .queued,
            .timestamp = @as(u64, @intCast(std.time.timestamp())),
            .gas_price = gas_price,
        };

        // Add to all transactions
        try self.all.put(tx_hash, pool_tx_ptr);
        errdefer _ = self.all.remove(tx_hash);

        // Add to pending or queued
        if (pool_tx_ptr.status == .pending) {
            try self.addToPending(pool_tx_ptr);
        } else {
            try self.addToQueued(pool_tx_ptr);
        }

        // Check and evict if pool is full
        try self.evictIfNeeded();

        std.log.info("TxPool: Added transaction {x} from {x}", .{
            std.fmt.fmtSliceHexLower(&tx_hash),
            std.fmt.fmtSliceHexLower(&from),
        });
    }

    /// Remove transaction from pool by hash
    pub fn remove(self: *TxPool, tx_hash: [32]u8) void {
        if (self.all.fetchRemove(tx_hash)) |kv| {
            const tx_ptr = kv.value;

            // Remove from pending or queued
            self.removeFromPending(tx_ptr.from, tx_hash);
            self.removeFromQueued(tx_ptr.from, tx_hash);

            self.allocator.destroy(tx_ptr);

            std.log.debug("TxPool: Removed transaction {x}", .{
                std.fmt.fmtSliceHexLower(&tx_hash),
            });
        }
    }

    /// Get transaction by hash
    pub fn get(self: *TxPool, tx_hash: [32]u8) ?*const PoolTransaction {
        return self.all.get(tx_hash);
    }

    /// Get pending transactions for mining (sorted by gas price)
    pub fn pending(self: *TxPool, limit: usize) ![]PoolTransaction {
        var result = std.ArrayList(PoolTransaction){};
        errdefer result.deinit(self.allocator);

        var iter = self.pending_txs.valueIterator();
        while (iter.next()) |txs| {
            for (txs.items) |tx| {
                if (result.items.len >= limit) break;
                try result.append(self.allocator, tx);
            }
            if (result.items.len >= limit) break;
        }

        // Sort by gas price (highest first)
        std.mem.sort(PoolTransaction, result.items, {}, compareByGasPrice);

        return result.toOwnedSlice(self.allocator);
    }

    /// Prune old and invalid transactions
    pub fn prune(self: *TxPool) !void {
        const now = @as(u64, @intCast(std.time.timestamp()));
        var to_remove = std.ArrayList([32]u8){};
        defer to_remove.deinit(self.allocator);

        var all_iter = self.all.iterator();
        while (all_iter.next()) |entry| {
            const tx_ptr = entry.value_ptr.*;

            // Remove if expired
            if (now - tx_ptr.timestamp > self.config.lifetime) {
                try to_remove.append(self.allocator, tx_ptr.tx_hash);
                continue;
            }

            // Remove if nonce too low
            if (self.accounts.get(tx_ptr.from)) |account| {
                if (tx_ptr.tx.nonce < account.nonce) {
                    try to_remove.append(self.allocator, tx_ptr.tx_hash);
                    continue;
                }
            }
        }

        // Remove collected transactions
        for (to_remove.items) |tx_hash| {
            self.remove(tx_hash);
        }

        std.log.debug("TxPool: Pruned {d} transactions", .{to_remove.items.len});
    }

    // ========================================================================
    // Private helper functions
    // ========================================================================

    /// Recover sender address from transaction signature
    fn recoverSender(self: *TxPool, tx: *const chain.Transaction) TxValidationError!primitives.Address {
        // Get signing hash
        const msg_hash = tx.signingHash(self.allocator) catch return TxValidationError.InvalidSignature;

        // Extract signature components
        const r = tx.r.value;
        const s = tx.s.value;
        const v_value = @as(u8, @intCast(tx.v.value & 0xFF));

        // Calculate recovery_id from v
        const recovery_id = if (v_value >= 27) v_value - 27 else v_value;

        // Verify signature validity
        if (!crypto.secp256k1.unaudited_validate_signature(r, s)) {
            return TxValidationError.InvalidSignature;
        }

        // Recover address
        const address = crypto.secp256k1.unaudited_recover_address(&msg_hash, recovery_id, r, s) catch {
            return TxValidationError.InvalidSignature;
        };

        return address;
    }

    /// Calculate intrinsic gas for transaction
    fn calculateIntrinsicGas(tx: *const chain.Transaction) u64 {
        var gas: u64 = if (tx.to == null) GasConstants.TxGasContractCreation else GasConstants.TxGas;

        // Count zero and non-zero bytes
        var zero_bytes: u64 = 0;
        var non_zero_bytes: u64 = 0;
        for (tx.data) |byte| {
            if (byte == 0) {
                zero_bytes += 1;
            } else {
                non_zero_bytes += 1;
            }
        }

        // Add data costs
        gas += zero_bytes * GasConstants.TxDataZeroGas;
        gas += non_zero_bytes * GasConstants.TxDataNonZeroGas;

        // Add access list costs (EIP-2930)
        if (tx.access_list) |access_list| {
            for (access_list) |entry| {
                gas += 2400; // TxAccessListAddressGas
                gas += entry.storage_keys.len * 1900; // TxAccessListStorageKeyGas
            }
        }

        // Add authorization costs (EIP-7702)
        if (tx.authorizations) |auths| {
            gas += auths.len * 25000; // PerEmptyAccountCost
        }

        return gas;
    }

    /// Validate transaction against pool rules
    fn validateTransaction(
        self: *TxPool,
        tx: *const chain.Transaction,
        from: [20]u8,
        account: AccountState,
    ) TxValidationError!void {
        // Check gas limit
        if (tx.gas_limit > self.config.block_gas_limit) {
            return TxValidationError.GasLimitExceeded;
        }

        // Check intrinsic gas
        const intrinsic_gas = calculateIntrinsicGas(tx);
        if (tx.gas_limit < intrinsic_gas) {
            return TxValidationError.IntrinsicGasTooLow;
        }

        // Check nonce
        if (tx.nonce < account.nonce) {
            return TxValidationError.NonceTooLow;
        }

        // Check gas price
        const gas_price = self.extractGasPrice(tx);
        if (gas_price < self.config.min_gas_price) {
            return TxValidationError.GasPriceTooLow;
        }

        // Check sender has sufficient balance
        const max_cost = @as(u256, tx.gas_limit) * gas_price + tx.value.value;
        if (account.balance < max_cost) {
            return TxValidationError.InsufficientFunds;
        }

        // Check per-account transaction limit
        const sender_tx_count = self.countTransactionsFrom(from);
        if (sender_tx_count >= self.config.account_slots) {
            return TxValidationError.TooManyTransactionsFromSender;
        }
    }

    /// Extract gas price from transaction
    fn extractGasPrice(self: *TxPool, tx: *const chain.Transaction) u256 {
        _ = self;
        return switch (tx.tx_type) {
            .legacy, .access_list => tx.gas_price orelse chain.U256.fromInt(0),
            .dynamic_fee => tx.gas_fee_cap orelse chain.U256.fromInt(0),
            else => chain.U256.fromInt(0),
        }.value;
    }

    /// Handle replacement transaction (must have 10% higher gas price)
    fn handleReplacement(
        self: *TxPool,
        tx_hash: [32]u8,
        new_tx: *const chain.Transaction,
        from: [20]u8,
    ) TxValidationError!void {
        const old_tx_ptr = self.all.get(tx_hash) orelse return;

        // Calculate new gas price
        const new_gas_price = self.extractGasPrice(new_tx);

        // Calculate minimum replacement price (old price * 1.10)
        const min_replacement_price = old_tx_ptr.gas_price * 110 / 100;

        if (new_gas_price < min_replacement_price) {
            return TxValidationError.Underpriced;
        }

        // Remove old transaction
        self.remove(tx_hash);

        // Add new transaction
        try self.add(new_tx.*);

        std.log.info("TxPool: Replaced transaction {x} from {x}", .{
            std.fmt.fmtSliceHexLower(&tx_hash),
            std.fmt.fmtSliceHexLower(&from),
        });
    }

    /// Add transaction to pending queue (sorted by gas price descending)
    fn addToPending(self: *TxPool, tx_ptr: *PoolTransaction) TxValidationError!void {
        const result = try self.pending_txs.getOrPut(tx_ptr.from);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(PoolTransaction){};
        }

        try result.value_ptr.*.append(self.allocator, tx_ptr.*);

        // Sort by gas price (highest first) for mining
        std.mem.sort(PoolTransaction, result.value_ptr.*.items, {}, compareByGasPrice);
    }

    /// Add transaction to queued queue (sorted by nonce)
    fn addToQueued(self: *TxPool, tx_ptr: *PoolTransaction) TxValidationError!void {
        const result = try self.queued_txs.getOrPut(tx_ptr.from);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(PoolTransaction){};
        }

        try result.value_ptr.*.append(self.allocator, tx_ptr.*);

        // Sort by nonce for sequential execution
        std.mem.sort(PoolTransaction, result.value_ptr.*.items, {}, compareByNonce);
    }

    /// Remove transaction from pending queue
    fn removeFromPending(self: *TxPool, from: [20]u8, tx_hash: [32]u8) void {
        if (self.pending_txs.getPtr(from)) |txs| {
            var i: usize = 0;
            while (i < txs.items.len) {
                if (std.mem.eql(u8, &txs.items[i].tx_hash, &tx_hash)) {
                    _ = txs.swapRemove(i);
                    return;
                }
                i += 1;
            }
        }
    }

    /// Remove transaction from queued queue
    fn removeFromQueued(self: *TxPool, from: [20]u8, tx_hash: [32]u8) void {
        if (self.queued_txs.getPtr(from)) |txs| {
            var i: usize = 0;
            while (i < txs.items.len) {
                if (std.mem.eql(u8, &txs.items[i].tx_hash, &tx_hash)) {
                    _ = txs.swapRemove(i);
                    return;
                }
                i += 1;
            }
        }
    }

    /// Count transactions from a specific address
    fn countTransactionsFrom(self: *TxPool, from: [20]u8) usize {
        var count: usize = 0;

        if (self.pending_txs.get(from)) |txs| {
            count += txs.items.len;
        }

        if (self.queued_txs.get(from)) |txs| {
            count += txs.items.len;
        }

        return count;
    }

    /// Evict lowest gas price transactions when pool is full
    fn evictIfNeeded(self: *TxPool) TxValidationError!void {
        while (self.all.count() > self.config.global_slots) {
            // Find lowest gas price transaction
            var lowest_tx: ?*PoolTransaction = null;
            var lowest_price: u256 = std.math.maxInt(u256);

            var all_iter = self.all.valueIterator();
            while (all_iter.next()) |tx_ptr| {
                if (tx_ptr.*.gas_price < lowest_price) {
                    lowest_price = tx_ptr.*.gas_price;
                    lowest_tx = tx_ptr.*;
                }
            }

            if (lowest_tx) |tx| {
                self.remove(tx.tx_hash);
                std.log.debug("TxPool: Evicted transaction {x} with gas price {d}", .{
                    std.fmt.fmtSliceHexLower(&tx.tx_hash),
                    tx.gas_price,
                });
            } else {
                break;
            }
        }
    }

    /// Compare transactions by gas price (for priority queue)
    fn compareByGasPrice(_: void, a: PoolTransaction, b: PoolTransaction) bool {
        return a.gas_price > b.gas_price;
    }

    /// Compare transactions by nonce (for queued transactions)
    fn compareByNonce(_: void, a: PoolTransaction, b: PoolTransaction) bool {
        return a.tx.nonce < b.tx.nonce;
    }

    /// Promote queued transactions to pending when nonce gap is filled
    pub fn promoteExecutables(self: *TxPool) TxValidationError!void {
        var queued_iter = self.queued_txs.iterator();
        while (queued_iter.next()) |entry| {
            const from = entry.key_ptr.*;
            const txs = entry.value_ptr.*;

            const account = self.accounts.get(from) orelse continue;

            // Find transactions that can be promoted
            var i: usize = 0;
            while (i < txs.items.len) {
                const tx = &txs.items[i];
                if (tx.tx.nonce < account.nonce) {
                    // Nonce too low, remove
                    _ = txs.swapRemove(i);
                    continue;
                }
                if (tx.tx.nonce == account.nonce) {
                    // Promote to pending
                    var tx_copy = tx.*;
                    tx_copy.status = .pending;
                    try self.addToPending(&tx_copy);
                    _ = txs.swapRemove(i);
                    continue;
                }
                i += 1;
            }
        }
    }

    /// Get pool statistics
    pub fn stats(self: *TxPool) TxPoolStats {
        return .{
            .pending = self.countPending(),
            .queued = self.countQueued(),
            .total = self.all.count(),
        };
    }

    fn countPending(self: *TxPool) usize {
        var count: usize = 0;
        var iter = self.pending_txs.valueIterator();
        while (iter.next()) |txs| {
            count += txs.items.len;
        }
        return count;
    }

    fn countQueued(self: *TxPool) usize {
        var count: usize = 0;
        var iter = self.queued_txs.valueIterator();
        while (iter.next()) |txs| {
            count += txs.items.len;
        }
        return count;
    }
};

pub const TxPoolStats = struct {
    pending: usize,
    queued: usize,
    total: usize,
};

// ============================================================================
// Tests
// ============================================================================

test "txpool basic operations" {
    var pool = TxPool.init(std.testing.allocator, TxPoolConfig.default());
    defer pool.deinit();

    const stats = pool.stats();
    try std.testing.expectEqual(@as(usize, 0), stats.total);
    try std.testing.expectEqual(@as(usize, 0), stats.pending);
    try std.testing.expectEqual(@as(usize, 0), stats.queued);
}

test "txpool account state management" {
    var pool = TxPool.init(std.testing.allocator, TxPoolConfig.default());
    defer pool.deinit();

    const addr = [_]u8{0x1} ** 20;
    try pool.setAccountState(addr, 1000000000000000000, 42);

    const account = pool.accounts.get(addr).?;
    try std.testing.expectEqual(@as(u256, 1000000000000000000), account.balance);
    try std.testing.expectEqual(@as(u64, 42), account.nonce);
}

test "txpool intrinsic gas calculation" {
    const tx_simple = chain.Transaction{
        .tx_type = .legacy,
        .chain_id = null,
        .nonce = 0,
        .gas_limit = 21000,
        .gas_price = chain.U256.fromInt(1000000000),
        .gas_tip_cap = null,
        .gas_fee_cap = null,
        .to = primitives.Address.zero(),
        .value = chain.U256.fromInt(0),
        .data = &[_]u8{},
        .access_list = null,
        .blob_hashes = null,
        .max_fee_per_blob_gas = null,
        .authorizations = null,
        .v = chain.U256.fromInt(27),
        .r = chain.U256.fromInt(0),
        .s = chain.U256.fromInt(0),
    };

    const intrinsic_gas = TxPool.calculateIntrinsicGas(&tx_simple);
    try std.testing.expectEqual(@as(u64, 21000), intrinsic_gas);

    // Test with data
    const data = [_]u8{ 0x01, 0x02, 0x00, 0x00, 0x03 };
    const tx_with_data = chain.Transaction{
        .tx_type = .legacy,
        .chain_id = null,
        .nonce = 0,
        .gas_limit = 50000,
        .gas_price = chain.U256.fromInt(1000000000),
        .gas_tip_cap = null,
        .gas_fee_cap = null,
        .to = primitives.Address.zero(),
        .value = chain.U256.fromInt(0),
        .data = &data,
        .access_list = null,
        .blob_hashes = null,
        .max_fee_per_blob_gas = null,
        .authorizations = null,
        .v = chain.U256.fromInt(27),
        .r = chain.U256.fromInt(0),
        .s = chain.U256.fromInt(0),
    };

    const intrinsic_gas_data = TxPool.calculateIntrinsicGas(&tx_with_data);
    // 21000 + (2 zero bytes * 4) + (3 non-zero bytes * 16) = 21000 + 8 + 48 = 21056
    try std.testing.expectEqual(@as(u64, 21056), intrinsic_gas_data);
}

test "txpool gas price extraction" {
    var pool = TxPool.init(std.testing.allocator, TxPoolConfig.default());
    defer pool.deinit();

    // Legacy transaction
    const tx_legacy = chain.Transaction{
        .tx_type = .legacy,
        .chain_id = null,
        .nonce = 0,
        .gas_limit = 21000,
        .gas_price = chain.U256.fromInt(1000000000),
        .gas_tip_cap = null,
        .gas_fee_cap = null,
        .to = null,
        .value = chain.U256.fromInt(0),
        .data = &[_]u8{},
        .access_list = null,
        .blob_hashes = null,
        .max_fee_per_blob_gas = null,
        .authorizations = null,
        .v = chain.U256.fromInt(27),
        .r = chain.U256.fromInt(0),
        .s = chain.U256.fromInt(0),
    };

    const gas_price = pool.extractGasPrice(&tx_legacy);
    try std.testing.expectEqual(@as(u256, 1000000000), gas_price);

    // EIP-1559 transaction
    const tx_1559 = chain.Transaction{
        .tx_type = .dynamic_fee,
        .chain_id = chain.U256.fromInt(1),
        .nonce = 0,
        .gas_limit = 21000,
        .gas_price = null,
        .gas_tip_cap = chain.U256.fromInt(2000000000),
        .gas_fee_cap = chain.U256.fromInt(100000000000),
        .to = null,
        .value = chain.U256.fromInt(0),
        .data = &[_]u8{},
        .access_list = null,
        .blob_hashes = null,
        .max_fee_per_blob_gas = null,
        .authorizations = null,
        .v = chain.U256.fromInt(0),
        .r = chain.U256.fromInt(0),
        .s = chain.U256.fromInt(0),
    };

    const gas_price_1559 = pool.extractGasPrice(&tx_1559);
    try std.testing.expectEqual(@as(u256, 100000000000), gas_price_1559);
}

test "txpool stats" {
    var pool = TxPool.init(std.testing.allocator, TxPoolConfig.default());
    defer pool.deinit();

    const stats = pool.stats();
    try std.testing.expectEqual(@as(usize, 0), stats.total);
    try std.testing.expectEqual(@as(usize, 0), stats.pending);
    try std.testing.expectEqual(@as(usize, 0), stats.queued);
}

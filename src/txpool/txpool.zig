//! Transaction pool (mempool)
//! Based on erigon/txnprovider and erigon-lib/txpool
//!
//! Manages pending transactions before they're included in blocks

const std = @import("std");
const chain = @import("../chain.zig");

/// Transaction pool configuration
pub const TxPoolConfig = struct {
    /// Maximum number of pending transactions
    max_pending: usize,
    /// Maximum number of queued transactions
    max_queued: usize,
    /// Price bump percentage for replacement
    price_bump: u8,
    /// Account slots (transactions per account)
    account_slots: usize,
    /// Global slots
    global_slots: usize,
    /// Lifetime of transactions in pool
    lifetime: u64,

    pub fn default() TxPoolConfig {
        return .{
            .max_pending = 10000,
            .max_queued = 5000,
            .price_bump = 10, // 10% bump required for replacement
            .account_slots = 16,
            .global_slots = 10000,
            .lifetime = 3 * 3600, // 3 hours in seconds
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
};

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
        _ = base_fee;
        // Simplified: In production, calculate effective gas price based on EIP-1559
        return self.gas_price;
    }
};

/// Transaction pool
pub const TxPool = struct {
    allocator: std.mem.Allocator,
    config: TxPoolConfig,
    /// Pending transactions (ready to be mined)
    pending: std.AutoHashMap([20]u8, std.ArrayList(PoolTransaction)),
    /// Queued transactions (future nonces)
    queued: std.AutoHashMap([20]u8, std.ArrayList(PoolTransaction)),
    /// All transactions by hash
    all: std.AutoHashMap([32]u8, *PoolTransaction),
    /// Account nonces
    nonces: std.AutoHashMap([20]u8, u64),

    pub fn init(allocator: std.mem.Allocator, config: TxPoolConfig) TxPool {
        return .{
            .allocator = allocator,
            .config = config,
            .pending = std.AutoHashMap([20]u8, std.ArrayList(PoolTransaction)).init(allocator),
            .queued = std.AutoHashMap([20]u8, std.ArrayList(PoolTransaction)).init(allocator),
            .all = std.AutoHashMap([32]u8, *PoolTransaction).init(allocator),
            .nonces = std.AutoHashMap([20]u8, u64).init(allocator),
        };
    }

    pub fn deinit(self: *TxPool) void {
        // Free pending transactions
        var pending_iter = self.pending.valueIterator();
        while (pending_iter.next()) |txs| {
            txs.deinit(self.allocator);
        }
        self.pending.deinit();

        // Free queued transactions
        var queued_iter = self.queued.valueIterator();
        while (queued_iter.next()) |txs| {
            txs.deinit(self.allocator);
        }
        self.queued.deinit();

        // Free all transactions map
        var all_iter = self.all.valueIterator();
        while (all_iter.next()) |tx_ptr| {
            self.allocator.destroy(tx_ptr.*);
        }
        self.all.deinit();

        self.nonces.deinit();
    }

    /// Add transaction to pool
    pub fn addTransaction(self: *TxPool, tx: chain.Transaction) !void {
        // Validate transaction
        try self.validateTransaction(&tx);

        // Recover sender
        const from = try tx.recoverSender(self.allocator);

        // Calculate transaction hash
        const tx_hash = try tx.hash(self.allocator);

        // Check if already known
        if (self.all.contains(tx_hash)) {
            return TxValidationError.AlreadyKnown;
        }

        // Get account nonce
        const account_nonce = self.nonces.get(from.bytes) orelse 0;

        // Create pool transaction
        const pool_tx_ptr = try self.allocator.create(PoolTransaction);
        pool_tx_ptr.* = PoolTransaction{
            .tx = tx,
            .tx_hash = tx_hash,
            .from = from.bytes,
            .status = if (tx.nonce == account_nonce) .pending else .queued,
            .timestamp = @as(u64, @intCast(std.time.timestamp())),
            .gas_price = tx.gas_price orelse chain.U256.fromInt(0),
        };

        // Add to all transactions
        try self.all.put(tx_hash, pool_tx_ptr);

        // Add to pending or queued
        if (pool_tx_ptr.status == .pending) {
            try self.addToPending(pool_tx_ptr);
        } else {
            try self.addToQueued(pool_tx_ptr);
        }

        std.log.info("TxPool: Added transaction {x} from {x}", .{
            std.fmt.fmtSliceHexLower(tx_hash[0..8]),
            std.fmt.fmtSliceHexLower(from.bytes[0..8]),
        });
    }

    fn validateTransaction(self: *TxPool, tx: *const chain.Transaction) !void {
        // Check gas limit
        const block_gas_limit: u64 = 30_000_000; // Simplified
        if (tx.gas_limit > block_gas_limit) {
            return TxValidationError.GasLimitExceeded;
        }

        // Check intrinsic gas
        const intrinsic_gas: u64 = 21000; // Simplified
        if (tx.gas_limit < intrinsic_gas) {
            return TxValidationError.IntrinsicGasTooLow;
        }

        // Check pool capacity
        if (self.all.count() >= self.config.max_pending + self.config.max_queued) {
            return TxValidationError.TxPoolFull;
        }
    }

    fn addToPending(self: *TxPool, tx_ptr: *PoolTransaction) !void {
        const result = try self.pending.getOrPut(tx_ptr.from);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(PoolTransaction).empty;
        }

        try result.value_ptr.append(self.allocator, tx_ptr.*);

        // Sort by nonce
        std.mem.sort(PoolTransaction, result.value_ptr.items, {}, compareByNonce);
    }

    fn addToQueued(self: *TxPool, tx_ptr: *PoolTransaction) !void {
        const result = try self.queued.getOrPut(tx_ptr.from);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(PoolTransaction).empty;
        }

        try result.value_ptr.append(self.allocator, tx_ptr.*);

        // Sort by nonce
        std.mem.sort(PoolTransaction, result.value_ptr.items, {}, compareByNonce);
    }

    fn compareByNonce(_: void, a: PoolTransaction, b: PoolTransaction) bool {
        return a.tx.nonce < b.tx.nonce;
    }

    /// Get pending transactions for mining
    pub fn getPending(self: *TxPool, limit: usize) ![]const PoolTransaction {
        var result = std.ArrayList(PoolTransaction).empty;
        defer result.deinit(self.allocator);

        var iter = self.pending.valueIterator();
        while (iter.next()) |txs| {
            for (txs.items) |tx| {
                if (result.items.len >= limit) break;
                try result.append(self.allocator, tx);
            }
        }

        // Sort by gas price (highest first)
        std.mem.sort(PoolTransaction, result.items, {}, compareByGasPrice);

        return result.toOwnedSlice(self.allocator);
    }

    fn compareByGasPrice(_: void, a: PoolTransaction, b: PoolTransaction) bool {
        return a.gas_price.value > b.gas_price.value;
    }

    /// Remove transaction from pool
    pub fn removeTransaction(self: *TxPool, tx_hash: [32]u8) void {
        if (self.all.fetchRemove(tx_hash)) |kv| {
            const tx_ptr = kv.value;
            self.allocator.destroy(tx_ptr);

            std.log.debug("TxPool: Removed transaction {x}", .{
                std.fmt.fmtSliceHexLower(tx_hash[0..8]),
            });
        }
    }

    /// Promote queued transactions to pending when nonce gap is filled
    pub fn promoteExecutables(self: *TxPool) !void {
        var queued_iter = self.queued.iterator();
        while (queued_iter.next()) |entry| {
            const from = entry.key_ptr.*;
            const txs = entry.value_ptr.*;

            const account_nonce = self.nonces.get(from) orelse 0;

            // Find transactions that can be promoted
            var i: usize = 0;
            while (i < txs.items.len) {
                const tx = &txs.items[i];
                if (tx.tx.nonce < account_nonce) {
                    // Nonce too low, remove
                    _ = txs.swapRemove(i);
                    continue;
                }
                if (tx.tx.nonce == account_nonce) {
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
        var iter = self.pending.valueIterator();
        while (iter.next()) |txs| {
            count += txs.items.len;
        }
        return count;
    }

    fn countQueued(self: *TxPool) usize {
        var count: usize = 0;
        var iter = self.queued.valueIterator();
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

test "txpool basic operations" {
    var pool = TxPool.init(std.testing.allocator, TxPoolConfig.default());
    defer pool.deinit();

    const stats = pool.stats();
    try std.testing.expectEqual(@as(usize, 0), stats.total);
}

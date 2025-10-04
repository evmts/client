//! IntraBlockState - State changes during block execution
//! Based on Erigon's core/state/intra_block_state.go
//!
//! Provides:
//! - In-memory caching of state changes
//! - Journal for snapshot/revert
//! - Access list for EIP-2929 warm/cold gas accounting
//! - Refund tracking

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const database = @import("database.zig");
const AccessList = @import("access_list.zig").AccessList;
const U256 = @import("chain.zig").U256;

pub const StateError = error{
    OutOfMemory,
    AccountNotFound,
    StorageNotFound,
    InsufficientBalance,
    NonceOverflow,
};

/// Journal entry for reverting state changes
const JournalEntry = union(enum) {
    account_touched: Address,
    balance_change: struct {
        address: Address,
        previous: u256,
    },
    nonce_change: struct {
        address: Address,
        previous: u64,
    },
    storage_change: struct {
        address: Address,
        slot: [32]u8,
        previous: [32]u8,
    },
    code_change: struct {
        address: Address,
        previous_hash: [32]u8,
    },
    access_list_address: Address,
    access_list_slot: struct {
        address: Address,
        slot: [32]u8,
    },
    refund_change: u64,
};

const StorageKey = struct {
    address: [20]u8,
    slot: [32]u8,

    pub fn eql(a: StorageKey, b: StorageKey) bool {
        return std.mem.eql(u8, &a.address, &b.address) and
            std.mem.eql(u8, &a.slot, &b.slot);
    }

    pub fn hash(key: StorageKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&key.address);
        hasher.update(&key.slot);
        return hasher.final();
    }
};

/// IntraBlockState - manages state changes during block execution
pub const IntraBlockState = struct {
    allocator: std.mem.Allocator,
    db: *database.Database,

    // Cached state objects
    accounts: std.AutoHashMap([20]u8, database.Account),
    storage: std.AutoHashMap(StorageKey, [32]u8),

    // Journal for rollback
    journal: std.ArrayList(JournalEntry),
    snapshots: std.ArrayList(usize),

    // Access list (EIP-2929)
    access_list: AccessList,

    // Refund counter
    refund: u64,

    // Transaction metadata
    tx_index: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db: *database.Database) Self {
        return .{
            .allocator = allocator,
            .db = db,
            .accounts = std.AutoHashMap([20]u8, database.Account).init(allocator),
            .storage = std.AutoHashMap(StorageKey, [32]u8).init(allocator),
            .journal = std.ArrayList(JournalEntry).init(allocator),
            .snapshots = std.ArrayList(usize).init(allocator),
            .access_list = AccessList.init(allocator),
            .refund = 0,
            .tx_index = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.accounts.deinit();
        self.storage.deinit();
        self.journal.deinit();
        self.snapshots.deinit();
        self.access_list.deinit();
    }

    // =========================================================================
    // Snapshot / Revert
    // =========================================================================

    /// Create a snapshot for potential rollback
    pub fn snapshot(self: *Self) !usize {
        const id = self.snapshots.items.len;
        try self.snapshots.append(self.journal.items.len);
        return id;
    }

    /// Revert to snapshot
    pub fn revertToSnapshot(self: *Self, snapshot_id: usize) !void {
        if (snapshot_id >= self.snapshots.items.len) return StateError.AccountNotFound;

        const journal_len = self.snapshots.items[snapshot_id];

        // Revert journal entries
        while (self.journal.items.len > journal_len) {
            const entry = self.journal.pop();
            try self.revertJournalEntry(entry);
        }

        // Remove snapshots after this one
        self.snapshots.shrinkRetainingCapacity(snapshot_id);
    }

    fn revertJournalEntry(self: *Self, entry: JournalEntry) !void {
        switch (entry) {
            .account_touched => {}, // No revert needed
            .balance_change => |change| {
                if (self.accounts.getPtr(change.address.bytes)) |account| {
                    account.balance = change.previous;
                }
            },
            .nonce_change => |change| {
                if (self.accounts.getPtr(change.address.bytes)) |account| {
                    account.nonce = change.previous;
                }
            },
            .storage_change => |change| {
                const key = StorageKey{
                    .address = change.address,
                    .slot = change.slot,
                };
                try self.storage.put(key, change.previous);
            },
            .code_change => |change| {
                if (self.accounts.getPtr(change.address.bytes)) |account| {
                    account.code_hash = change.previous_hash;
                }
            },
            .access_list_address => |address| {
                self.access_list.deleteAddress(address);
            },
            .access_list_slot => |data| {
                self.access_list.deleteSlot(data.address, data.slot);
            },
            .refund_change => |previous| {
                self.refund = previous;
            },
        }
    }

    // =========================================================================
    // Access List (EIP-2929)
    // =========================================================================

    /// Add address to access list and return gas cost
    /// Returns cold cost (2600) for first access, warm cost (100) for subsequent
    pub fn accessAddress(self: *Self, address: Address) !u64 {
        const added = try self.access_list.addAddress(address);
        if (added) {
            try self.journal.append(.{ .access_list_address = address });
            return @import("access_list.zig").GAS_COLD_ACCOUNT_ACCESS;
        }
        return @import("access_list.zig").GAS_WARM_ACCOUNT_ACCESS;
    }

    /// Add storage slot to access list and return gas cost
    /// Returns cold cost (2100) for first access, warm cost (100) for subsequent
    pub fn accessStorageSlot(self: *Self, address: Address, slot: [32]u8) !u64 {
        const result = try self.access_list.addSlot(address, slot);

        if (result.address_added) {
            try self.journal.append(.{ .access_list_address = address });
        }
        if (result.slot_added) {
            try self.journal.append(.{ .access_list_slot = .{ .address = address, .slot = slot } });
            return @import("access_list.zig").GAS_COLD_SLOAD;
        }
        return @import("access_list.zig").GAS_WARM_SLOAD;
    }

    /// Check if address is in access list
    pub fn isAddressWarm(self: *const Self, address: Address) bool {
        return self.access_list.containsAddress(address);
    }

    /// Check if storage slot is in access list
    pub fn isSlotWarm(self: *const Self, address: Address, slot: [32]u8) bool {
        const result = self.access_list.contains(address, slot);
        return result.slot_present;
    }

    /// Prepare access list for transaction (pre-warm addresses)
    pub fn prepareAccessList(self: *Self, tx_origin: Address, tx_to: ?Address, precompiles: []const Address) !void {
        // Always warm: tx.origin, tx.to (if set), precompiles
        _ = try self.access_list.addAddress(tx_origin);

        if (tx_to) |to| {
            _ = try self.access_list.addAddress(to);
        }

        for (precompiles) |addr| {
            _ = try self.access_list.addAddress(addr);
        }
    }

    // =========================================================================
    // Account Operations
    // =========================================================================

    /// Get account balance
    pub fn getBalance(self: *Self, address: Address) !u256 {
        const account = try self.getAccount(address);
        return account.balance;
    }

    /// Get account nonce
    pub fn getNonce(self: *Self, address: Address) !u64 {
        const account = try self.getAccount(address);
        return account.nonce;
    }

    /// Get account code hash
    pub fn getCodeHash(self: *Self, address: Address) ![32]u8 {
        const account = try self.getAccount(address);
        return account.code_hash;
    }

    /// Check if account has delegated designation (EIP-7702)
    pub fn hasDelegatedDesignation(self: *Self, address: Address) !bool {
        const code_hash = try self.getCodeHash(address);
        // Check if code hash starts with EIP-7702 prefix (0xef0100)
        if (code_hash[0] == 0xef and code_hash[1] == 0x01 and code_hash[2] == 0x00) {
            return true;
        }
        return false;
    }

    /// Set account nonce
    pub fn setNonce(self: *Self, address: Address, nonce: u64) !void {
        var account = try self.getAccount(address);

        try self.journal.append(.{
            .nonce_change = .{
                .address = address,
                .previous = account.nonce,
            },
        });

        account.nonce = nonce;
        try self.accounts.put(address.bytes, account);
    }

    /// Subtract balance from account
    pub fn subBalance(self: *Self, address: Address, amount: u256) !void {
        var account = try self.getAccount(address);

        if (account.balance < amount) {
            return StateError.InsufficientBalance;
        }

        try self.journal.append(.{
            .balance_change = .{
                .address = address,
                .previous = account.balance,
            },
        });

        account.balance -= amount;
        try self.accounts.put(address.bytes, account);
    }

    /// Add balance to account
    pub fn addBalance(self: *Self, address: Address, amount: u256) !void {
        var account = try self.getAccount(address);

        try self.journal.append(.{
            .balance_change = .{
                .address = address,
                .previous = account.balance,
            },
        });

        account.balance += amount;
        try self.accounts.put(address.bytes, account);
    }

    /// Get account (from cache or database)
    fn getAccount(self: *Self, address: Address) !database.Account {
        if (self.accounts.get(address.bytes)) |account| {
            return account;
        }

        // Load from database
        const account = self.db.getAccount(address.bytes) orelse database.Account.empty();
        try self.accounts.put(address.bytes, account);
        return account;
    }

    // =========================================================================
    // Storage Operations
    // =========================================================================

    /// Get storage value
    pub fn getStorage(self: *Self, address: Address, slot: U256) ![32]u8 {
        const key = StorageKey{
            .address = address.bytes,
            .slot = slot.toBytes(),
        };

        if (self.storage.get(key)) |value| {
            return value;
        }

        // Load from database (for now return zero)
        const zero = [_]u8{0} ** 32;
        try self.storage.put(key, zero);
        return zero;
    }

    /// Set storage value
    pub fn setStorage(self: *Self, address: Address, slot: U256, value: [32]u8) !void {
        const key = StorageKey{
            .address = address.bytes,
            .slot = slot.toBytes(),
        };

        const previous = self.storage.get(key) orelse [_]u8{0} ** 32;

        try self.journal.append(.{
            .storage_change = .{
                .address = address.bytes,
                .slot = key.slot,
                .previous = previous,
            },
        });

        try self.storage.put(key, value);
    }

    // =========================================================================
    // Refund Management
    // =========================================================================

    /// Add gas refund
    pub fn addRefund(self: *Self, amount: u64) !void {
        try self.journal.append(.{ .refund_change = self.refund });
        self.refund += amount;
    }

    /// Subtract gas refund
    pub fn subRefund(self: *Self, amount: u64) !void {
        try self.journal.append(.{ .refund_change = self.refund });
        if (self.refund >= amount) {
            self.refund -= amount;
        } else {
            self.refund = 0;
        }
    }

    /// Get refund amount
    pub fn getRefund(self: *const Self) u64 {
        return self.refund;
    }
};

// Legacy State type for compatibility
pub const State = IntraBlockState;

test "intra block state - snapshot and revert" {
    const testing = std.testing;

    var db = database.Database.init(testing.allocator);
    defer db.deinit();

    var ibs = IntraBlockState.init(testing.allocator, &db);
    defer ibs.deinit();

    var addr: Address = undefined;
    @memset(&addr.bytes, 0x01);

    // Set initial balance
    try ibs.addBalance(addr, 1000);
    try testing.expectEqual(@as(u256, 1000), try ibs.getBalance(addr));

    // Create snapshot
    const snap = try ibs.snapshot();

    // Modify balance
    try ibs.subBalance(addr, 500);
    try testing.expectEqual(@as(u256, 500), try ibs.getBalance(addr));

    // Revert
    try ibs.revertToSnapshot(snap);
    try testing.expectEqual(@as(u256, 1000), try ibs.getBalance(addr));
}

test "intra block state - access list integration" {
    const testing = std.testing;

    var db = database.Database.init(testing.allocator);
    defer db.deinit();

    var ibs = IntraBlockState.init(testing.allocator, &db);
    defer ibs.deinit();

    var addr: Address = undefined;
    @memset(&addr.bytes, 0x01);

    // First access should be cold
    const cost1 = try ibs.accessAddress(addr);
    try testing.expectEqual(@as(u64, 2600), cost1);

    // Second access should be warm
    const cost2 = try ibs.accessAddress(addr);
    try testing.expectEqual(@as(u64, 100), cost2);

    // Create snapshot and revert
    const snap = try ibs.snapshot();

    var addr2: Address = undefined;
    @memset(&addr2.bytes, 0x02);
    _ = try ibs.accessAddress(addr2);

    try ibs.revertToSnapshot(snap);

    // addr2 should be cold after revert
    const cost3 = try ibs.accessAddress(addr2);
    try testing.expectEqual(@as(u64, 2600), cost3);
}

test "intra block state - refund tracking" {
    const testing = std.testing;

    var db = database.Database.init(testing.allocator);
    defer db.deinit();

    var ibs = IntraBlockState.init(testing.allocator, &db);
    defer ibs.deinit();

    try ibs.addRefund(100);
    try testing.expectEqual(@as(u64, 100), ibs.getRefund());

    const snap = try ibs.snapshot();

    try ibs.addRefund(50);
    try testing.expectEqual(@as(u64, 150), ibs.getRefund());

    try ibs.revertToSnapshot(snap);
    try testing.expectEqual(@as(u64, 100), ibs.getRefund());
}

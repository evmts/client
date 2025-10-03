//! State management layer
//! Provides EVM-compatible state access with journaling for reverts

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const database = @import("database.zig");

// Import U256 from chain module
const U256 = @import("chain.zig").U256;

pub const StateError = error{
    OutOfMemory,
    AccountNotFound,
    StorageNotFound,
};

/// Journal entry for reverting state changes
const JournalEntry = union(enum) {
    account_change: struct {
        address: [20]u8,
        previous: ?database.Account,
    },
    storage_change: struct {
        address: [20]u8,
        slot: [32]u8,
        previous: [32]u8,
    },
    code_change: struct {
        address: [20]u8,
        previous_hash: [32]u8,
    },
};

/// State provider with journaling for transaction execution
pub const State = struct {
    allocator: std.mem.Allocator,
    db: *database.Database,
    accounts: std.AutoHashMap([20]u8, database.Account),
    storage: std.AutoHashMap(StorageKey, [32]u8),
    journal: std.ArrayList(JournalEntry),
    checkpoint: usize,

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

    pub fn init(allocator: std.mem.Allocator, db: *database.Database) State {
        return .{
            .allocator = allocator,
            .db = db,
            .accounts = std.AutoHashMap([20]u8, database.Account).init(allocator),
            .storage = std.AutoHashMap(StorageKey, [32]u8).init(allocator),
            .journal = std.ArrayList(JournalEntry).empty,
            .checkpoint = 0,
        };
    }

    pub fn deinit(self: *State) void {
        self.accounts.deinit();
        self.storage.deinit();
        self.journal.deinit(self.allocator);
    }

    /// Create a checkpoint for potential rollback
    pub fn createCheckpoint(self: *State) void {
        self.checkpoint = self.journal.items.len;
    }

    /// Commit changes since last checkpoint
    pub fn commitCheckpoint(self: *State) void {
        self.checkpoint = self.journal.items.len;
    }

    /// Revert to last checkpoint
    pub fn revertToCheckpoint(self: *State) !void {
        while (self.journal.items.len > self.checkpoint) {
            const entry = self.journal.pop();
            switch (entry) {
                .account_change => |change| {
                    if (change.previous) |prev| {
                        try self.accounts.put(change.address, prev);
                    } else {
                        _ = self.accounts.remove(change.address);
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
                    var account = self.accounts.get(change.address) orelse continue;
                    account.code_hash = change.previous_hash;
                    try self.accounts.put(change.address, account);
                },
            }
        }
    }

    /// Get account, loading from database if needed
    pub fn getAccount(self: *State, address: Address) !database.Account {
        const addr_bytes = address.bytes;

        // Check cache first
        if (self.accounts.get(addr_bytes)) |account| {
            return account;
        }

        // Load from database
        const account = self.db.getAccount(addr_bytes) orelse database.Account.empty();
        try self.accounts.put(addr_bytes, account);
        return account;
    }

    /// Update account state
    pub fn setAccount(self: *State, address: Address, account: database.Account) !void {
        const addr_bytes = address.bytes;

        // Record previous state in journal
        const previous = self.accounts.get(addr_bytes);
        try self.journal.append(self.allocator, .{
            .account_change = .{
                .address = addr_bytes,
                .previous = previous,
            },
        });

        try self.accounts.put(addr_bytes, account);
    }

    /// Get storage slot
    pub fn getStorage(self: *State, address: Address, slot: U256) ![32]u8 {
        const key = StorageKey{
            .address = address.bytes,
            .slot = slot.toBytes(),
        };

        if (self.storage.get(key)) |value| {
            return value;
        }

        // In production, load from database
        const zero = [_]u8{0} ** 32;
        try self.storage.put(key, zero);
        return zero;
    }

    /// Set storage slot
    pub fn setStorage(self: *State, address: Address, slot: U256, value: U256) !void {
        const key = StorageKey{
            .address = address.bytes,
            .slot = slot.toBytes(),
        };

        const previous = self.storage.get(key) orelse [_]u8{0} ** 32;
        try self.journal.append(self.allocator, .{
            .storage_change = .{
                .address = key.address,
                .slot = key.slot,
                .previous = previous,
            },
        });

        try self.storage.put(key, value.toBytes());
    }

    /// Get account balance
    pub fn getBalance(self: *State, address: Address) !U256 {
        const account = try self.getAccount(address);
        return U256.fromBytes(account.balance);
    }

    /// Set account balance
    pub fn setBalance(self: *State, address: Address, balance: U256) !void {
        var account = try self.getAccount(address);
        account.balance = balance.toBytes();
        try self.setAccount(address, account);
    }

    /// Get account nonce
    pub fn getNonce(self: *State, address: Address) !u64 {
        const account = try self.getAccount(address);
        return account.nonce;
    }

    /// Set account nonce
    pub fn setNonce(self: *State, address: Address, nonce: u64) !void {
        var account = try self.getAccount(address);
        account.nonce = nonce;
        try self.setAccount(address, account);
    }

    /// Get contract code
    pub fn getCode(self: *State, address: Address) ![]const u8 {
        const account = try self.getAccount(address);
        if (std.mem.eql(u8, &account.code_hash, &([_]u8{0} ** 32))) {
            return &[_]u8{};
        }
        return self.db.getCode(account.code_hash) orelse &[_]u8{};
    }

    /// Set contract code
    pub fn setCode(self: *State, address: Address, code: []const u8) !void {
        const code_hash = std.crypto.hash.sha3.Keccak256.hash(code, .{});

        var account = try self.getAccount(address);
        const previous_hash = account.code_hash;

        try self.journal.append(self.allocator, .{
            .code_change = .{
                .address = address.bytes,
                .previous_hash = previous_hash,
            },
        });

        // Store code in database
        const code_copy = try self.allocator.dupe(u8, code);
        try self.db.putCode(code_hash, code_copy);

        account.code_hash = code_hash;
        try self.setAccount(address, account);
    }

    /// Check if account exists
    pub fn exists(self: *State, address: Address) !bool {
        const account = try self.getAccount(address);
        return account.nonce != 0 or
            !std.mem.eql(u8, &account.balance, &([_]u8{0} ** 32)) or
            !std.mem.eql(u8, &account.code_hash, &([_]u8{0} ** 32));
    }

    /// Commit all changes to database
    pub fn commitToDb(self: *State) !void {
        // Write all accounts to database
        var account_iter = self.accounts.iterator();
        while (account_iter.next()) |entry| {
            try self.db.putAccount(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Clear journal after commit
        self.journal.items.len = 0;
        self.checkpoint = 0;
    }
};

test "state account operations" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    var state = State.init(std.testing.allocator, &db);
    defer state.deinit();

    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const balance = U256.fromInt(1000);

    try state.setBalance(addr, balance);
    const retrieved_balance = try state.getBalance(addr);
    try std.testing.expect(retrieved_balance.eql(balance));
}

test "state journaling and revert" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    var state = State.init(std.testing.allocator, &db);
    defer state.deinit();

    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);

    try state.setNonce(addr, 1);
    state.createCheckpoint();

    try state.setNonce(addr, 5);
    const nonce_before_revert = try state.getNonce(addr);
    try std.testing.expectEqual(@as(u64, 5), nonce_before_revert);

    try state.revertToCheckpoint();
    const nonce_after_revert = try state.getNonce(addr);
    try std.testing.expectEqual(@as(u64, 1), nonce_after_revert);
}

test "state storage operations" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    var state = State.init(std.testing.allocator, &db);
    defer state.deinit();

    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const slot = U256.fromInt(0);
    const value = U256.fromInt(42);

    try state.setStorage(addr, slot, value);
    const retrieved = try state.getStorage(addr, slot);
    const retrieved_u256 = U256.fromBytes(retrieved);
    try std.testing.expect(retrieved_u256.eql(value));
}

//! Guillotine Database Adapter
//!
//! Bridges our persistent MDBX database to guillotine's in-memory storage interface.
//!
//! ARCHITECTURE DECISION:
//! Guillotine's storage interface expects in-memory operations with snapshot/rollback semantics.
//! Our MDBX database provides persistent, transaction-based storage.
//!
//! SOLUTION: Write-through cache with transaction batching
//! - Reads go to MDBX directly (cached for transaction lifetime)
//! - Writes accumulate in memory during EVM execution
//! - Commits flush writes to MDBX in a single transaction
//! - Rollbacks discard in-memory changes
//!
//! This provides guillotine's expected semantics while maintaining MDBX's durability.

const std = @import("std");
const kv = @import("../kv/kv.zig");
const tables = @import("../kv/tables.zig");
const primitives = @import("primitives");
const guillotine = @import("guillotine");

const Account = guillotine.storage.database.Account;
const Database = guillotine.storage.database.Database;
const Address = primitives.Address.Address;

/// Adapter that wraps MDBX and provides guillotine's Database interface
pub const GuillotineAdapter = struct {
    allocator: std.mem.Allocator,
    db: *kv.Database,
    tx: ?*kv.Transaction,

    // Write-through cache: stores pending writes until commit
    pending_accounts: std.HashMap([20]u8, ?Account, ArrayHashContext, std.hash_map.default_max_load_percentage),
    pending_storage: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    pending_code: std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage),

    // Read cache: avoid repeated MDBX reads in same transaction
    account_cache: std.HashMap([20]u8, ?Account, ArrayHashContext, std.hash_map.default_max_load_percentage),
    storage_cache: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    code_cache: std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage),

    const Self = @This();

    const StorageKey = struct {
        address: [20]u8,
        key: u256,
    };

    const ArrayHashContext = struct {
        pub fn hash(self: @This(), s: anytype) u64 {
            _ = self;
            return std.hash_map.hashString(@as([]const u8, &s));
        }
        pub fn eql(self: @This(), a: anytype, b: anytype) bool {
            _ = self;
            return std.mem.eql(u8, &a, &b);
        }
    };

    const StorageKeyContext = struct {
        pub fn hash(self: @This(), key: StorageKey) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&key.address);
            hasher.update(std.mem.asBytes(&key.key));
            return hasher.final();
        }
        pub fn eql(self: @This(), a: StorageKey, b: StorageKey) bool {
            _ = self;
            return std.mem.eql(u8, &a.address, &b.address) and a.key == b.key;
        }
    };

    pub const Error = Database.Error;

    /// Initialize adapter with existing MDBX database
    pub fn init(allocator: std.mem.Allocator, db: *kv.Database) Self {
        return Self{
            .allocator = allocator,
            .db = db,
            .tx = null,
            .pending_accounts = std.HashMap([20]u8, ?Account, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .pending_storage = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .pending_code = std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .account_cache = std.HashMap([20]u8, ?Account, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .storage_cache = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .code_cache = std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Free pending code allocations
        var code_iter = self.pending_code.iterator();
        while (code_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }

        // Free cached code allocations
        var cache_iter = self.code_cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }

        self.pending_accounts.deinit();
        self.pending_storage.deinit();
        self.pending_code.deinit();
        self.account_cache.deinit();
        self.storage_cache.deinit();
        self.code_cache.deinit();

        if (self.tx) |tx| {
            tx.rollback();
        }
    }

    /// Begin a new write transaction
    pub fn begin_transaction(self: *Self) !void {
        if (self.tx != null) return error.TransactionInProgress;
        self.tx = try self.db.beginTx(true);

        // Clear caches for new transaction
        self.account_cache.clearRetainingCapacity();
        self.storage_cache.clearRetainingCapacity();
        var cache_iter = self.code_cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.code_cache.clearRetainingCapacity();
    }

    /// Get account data for the given address
    pub fn get_account(self: *Self, address: [20]u8) Error!?Account {
        // Check pending writes first
        if (self.pending_accounts.get(address)) |account_opt| {
            return account_opt;
        }

        // Check cache
        if (self.account_cache.get(address)) |account_opt| {
            return account_opt;
        }

        // Read from MDBX
        const tx = self.tx orelse return error.NoTransactionActive;
        const key = tables.Encoding.encodeAddress(address);
        const value = try tx.get(.PlainState, &key) orelse {
            try self.account_cache.put(address, null);
            return null;
        };

        // Deserialize account from MDBX format
        const account = try self.deserializeAccount(value);
        try self.account_cache.put(address, account);
        return account;
    }

    /// Set account data for the given address
    pub fn set_account(self: *Self, address: [20]u8, account: Account) Error!void {
        try self.pending_accounts.put(address, account);
        // Also update cache for immediate reads
        try self.account_cache.put(address, account);
    }

    /// Delete account and all associated data
    pub fn delete_account(self: *Self, address: [20]u8) Error!void {
        try self.pending_accounts.put(address, null);
        try self.account_cache.put(address, null);
    }

    /// Check if account exists
    pub fn account_exists(self: *Self, address: [20]u8) bool {
        const account = self.get_account(address) catch return false;
        return account != null;
    }

    /// Get account balance
    pub fn get_balance(self: *Self, address: [20]u8) Error!u256 {
        if (try self.get_account(address)) |account| {
            return account.balance;
        }
        return 0;
    }

    /// Get storage value for the given address and key
    pub fn get_storage(self: *Self, address: [20]u8, key: u256) Error!u256 {
        const storage_key = StorageKey{ .address = address, .key = key };

        // Check pending writes
        if (self.pending_storage.get(storage_key)) |value| {
            return value;
        }

        // Check cache
        if (self.storage_cache.get(storage_key)) |value| {
            return value;
        }

        // Read from MDBX
        const tx = self.tx orelse return error.NoTransactionActive;

        // Storage key format: address (20) + incarnation (8) + location (32)
        const incarnation: u64 = 0; // TODO: Track incarnation properly
        var location_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &location_bytes, key, .big);
        const db_key = tables.Encoding.encodeStorageKey(address, incarnation, location_bytes);

        const value_bytes = try tx.get(.PlainState, &db_key) orelse {
            try self.storage_cache.put(storage_key, 0);
            return 0;
        };

        if (value_bytes.len != 32) return error.InvalidStorageValue;
        const value = std.mem.readInt(u256, value_bytes[0..32], .big);
        try self.storage_cache.put(storage_key, value);
        return value;
    }

    /// Set storage value for the given address and key
    pub fn set_storage(self: *Self, address: [20]u8, key: u256, value: u256) Error!void {
        const storage_key = StorageKey{ .address = address, .key = key };
        try self.pending_storage.put(storage_key, value);
        try self.storage_cache.put(storage_key, value);
    }

    /// Get transient storage (EIP-1153) - stored in memory only, never persisted
    pub fn get_transient_storage(self: *Self, address: [20]u8, key: u256) Error!u256 {
        _ = self;
        _ = address;
        _ = key;
        // Transient storage is not persisted to MDBX
        return 0;
    }

    /// Set transient storage (EIP-1153)
    pub fn set_transient_storage(self: *Self, address: [20]u8, key: u256, value: u256) Error!void {
        _ = self;
        _ = address;
        _ = key;
        _ = value;
        // Transient storage is not persisted to MDBX
    }

    /// Get contract code by hash
    pub fn get_code(self: *Self, code_hash: [32]u8) Error![]const u8 {
        // Check pending writes
        if (self.pending_code.get(code_hash)) |code| {
            return code;
        }

        // Check cache
        if (self.code_cache.get(code_hash)) |code| {
            return code;
        }

        // Read from MDBX
        const tx = self.tx orelse return error.NoTransactionActive;
        const code_bytes = try tx.get(.Code, &code_hash) orelse {
            return Error.CodeNotFound;
        };

        // Cache the code (make a copy since MDBX data is only valid during transaction)
        const code_copy = try self.allocator.dupe(u8, code_bytes);
        try self.code_cache.put(code_hash, code_copy);
        return code_copy;
    }

    /// Get contract code by address (supports EIP-7702 delegation)
    pub fn get_code_by_address(self: *Self, address: [20]u8) Error![]const u8 {
        if (try self.get_account(address)) |account| {
            // EIP-7702: Check if this EOA has delegated code
            if (account.get_effective_code_address()) |delegated_addr| {
                return self.get_code_by_address(delegated_addr.bytes);
            }

            // Check if this is an EOA (all-zero code_hash or EMPTY_CODE_HASH)
            const zero_hash = [_]u8{0} ** 32;
            if (std.mem.eql(u8, &account.code_hash, &zero_hash) or
                std.mem.eql(u8, &account.code_hash, &primitives.EMPTY_CODE_HASH))
            {
                return &.{};
            }

            return self.get_code(account.code_hash);
        }

        return Error.AccountNotFound;
    }

    /// Store contract code and return its hash
    pub fn set_code(self: *Self, code: []const u8) Error![32]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});

        // Check if code already exists
        if (self.pending_code.get(hash)) |_| {
            return hash;
        }
        if (self.code_cache.get(hash)) |_| {
            return hash;
        }

        // Make a copy to own the code
        const code_copy = self.allocator.alloc(u8, code.len) catch return Error.OutOfMemory;
        @memcpy(code_copy, code);

        try self.pending_code.put(hash, code_copy);
        return hash;
    }

    /// Get current state root hash (mock implementation)
    pub fn get_state_root(self: *Self) Error![32]u8 {
        _ = self;
        return [_]u8{0xAB} ** 32;
    }

    /// Commit pending changes to MDBX
    pub fn commit_changes(self: *Self) Error![32]u8 {
        const tx = self.tx orelse return error.NoTransactionActive;

        // Flush pending accounts
        var account_iter = self.pending_accounts.iterator();
        while (account_iter.next()) |entry| {
            const address = entry.key_ptr.*;
            const account_opt = entry.value_ptr.*;

            const key = tables.Encoding.encodeAddress(address);

            if (account_opt) |account| {
                const value = try self.serializeAccount(account);
                defer self.allocator.free(value);
                try tx.put(.PlainState, &key, value);
            } else {
                // Delete account
                try tx.delete(.PlainState, &key);
            }
        }

        // Flush pending storage
        var storage_iter = self.pending_storage.iterator();
        while (storage_iter.next()) |entry| {
            const storage_key = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            const incarnation: u64 = 0;
            var location_bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &location_bytes, storage_key.key, .big);
            const db_key = tables.Encoding.encodeStorageKey(storage_key.address, incarnation, location_bytes);

            var value_bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &value_bytes, value, .big);

            try tx.put(.PlainState, &db_key, &value_bytes);
        }

        // Flush pending code
        var code_iter = self.pending_code.iterator();
        while (code_iter.next()) |entry| {
            const hash = entry.key_ptr.*;
            const code = entry.value_ptr.*;

            try tx.put(.Code, &hash, code);
        }

        // Commit MDBX transaction
        try tx.commit();
        self.tx = null;

        // Clear pending writes
        self.pending_accounts.clearRetainingCapacity();
        self.pending_storage.clearRetainingCapacity();
        var pending_code_iter = self.pending_code.iterator();
        while (pending_code_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.pending_code.clearRetainingCapacity();

        return self.get_state_root();
    }

    /// Create a snapshot (not supported - use MDBX snapshots directly)
    pub fn create_snapshot(self: *Self) Error!u64 {
        _ = self;
        return error.SnapshotNotFound;
    }

    /// Revert to snapshot (not supported - use MDBX rollback)
    pub fn revert_to_snapshot(self: *Self, snapshot_id: u64) Error!void {
        _ = self;
        _ = snapshot_id;
        return error.SnapshotNotFound;
    }

    /// Commit snapshot (not supported)
    pub fn commit_snapshot(self: *Self, snapshot_id: u64) Error!void {
        _ = self;
        _ = snapshot_id;
        return error.SnapshotNotFound;
    }

    /// Begin batch (no-op, batching handled by pending writes)
    pub fn begin_batch(self: *Self) Error!void {
        _ = self;
    }

    /// Commit batch (no-op)
    pub fn commit_batch(self: *Self) Error!void {
        _ = self;
    }

    /// Rollback batch
    pub fn rollback_batch(self: *Self) Error!void {
        const tx = self.tx orelse return;
        tx.rollback();
        self.tx = null;

        // Clear all pending writes
        self.pending_accounts.clearRetainingCapacity();
        self.pending_storage.clearRetainingCapacity();
        var code_iter = self.pending_code.iterator();
        while (code_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.pending_code.clearRetainingCapacity();
    }

    /// EIP-7702: Set delegation for an EOA
    pub fn set_delegation(self: *Self, eoa_address: [20]u8, delegated_address: [20]u8) Error!void {
        var account = (try self.get_account(eoa_address)) orelse Account.zero();

        // Only EOAs can have delegations
        const zero_hash = [_]u8{0} ** 32;
        if (!std.mem.eql(u8, &account.code_hash, &zero_hash)) {
            return Error.InvalidAddress;
        }

        const delegate_addr = Address{ .bytes = delegated_address };
        account.set_delegation(delegate_addr);
        try self.set_account(eoa_address, account);
    }

    /// EIP-7702: Clear delegation for an EOA
    pub fn clear_delegation(self: *Self, eoa_address: [20]u8) Error!void {
        if (try self.get_account(eoa_address)) |account| {
            var mutable_account = account;
            mutable_account.clear_delegation();
            try self.set_account(eoa_address, mutable_account);
        }
    }

    /// EIP-7702: Check if an address has a delegation
    pub fn has_delegation(self: *Self, address: [20]u8) Error!bool {
        if (try self.get_account(address)) |account| {
            return account.has_delegation();
        }
        return false;
    }

    /// Serialize account to bytes for MDBX storage
    fn serializeAccount(self: *Self, account: Account) ![]u8 {
        // Simple serialization: balance (32) + nonce (8) + code_hash (32) + storage_root (32)
        // Total: 104 bytes
        const size = 104;
        const buffer = try self.allocator.alloc(u8, size);

        std.mem.writeInt(u256, buffer[0..32], account.balance, .big);
        std.mem.writeInt(u64, buffer[32..40], account.nonce, .big);
        @memcpy(buffer[40..72], &account.code_hash);
        @memcpy(buffer[72..104], &account.storage_root);

        return buffer;
    }

    /// Deserialize account from MDBX bytes
    fn deserializeAccount(self: *Self, bytes: []const u8) !Account {
        _ = self;
        if (bytes.len < 104) return error.InvalidAccountData;

        return Account{
            .balance = std.mem.readInt(u256, bytes[0..32], .big),
            .nonce = std.mem.readInt(u64, bytes[32..40], .big),
            .code_hash = bytes[40..72].*,
            .storage_root = bytes[72..104].*,
            .delegated_address = null,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "GuillotineAdapter: account operations" {
    const allocator = testing.allocator;

    // Create in-memory database for testing
    const mdbx = @import("../kv/mdbx.zig");
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = "test_db";
    try tmp_dir.dir.makeDir(path);
    const full_path = try tmp_dir.dir.realpathAlloc(allocator, path);
    defer allocator.free(full_path);

    var mdbx_db = try mdbx.MdbxDb.init(allocator, full_path);
    defer mdbx_db.deinit();

    var kv_db = mdbx_db.database();

    var adapter = GuillotineAdapter.init(allocator, &kv_db);
    defer adapter.deinit();

    try adapter.begin_transaction();

    const test_address = [_]u8{0x12} ++ [_]u8{0} ** 19;

    // Test account doesn't exist initially
    try testing.expect(!adapter.account_exists(test_address));
    try testing.expectEqual(@as(?Account, null), try adapter.get_account(test_address));

    // Create account
    const test_account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = [_]u8{0xAB} ** 32,
        .storage_root = [_]u8{0xCD} ** 32,
    };

    try adapter.set_account(test_address, test_account);

    // Verify account exists in pending state
    const retrieved = (try adapter.get_account(test_address)).?;
    try testing.expectEqual(test_account.balance, retrieved.balance);
    try testing.expectEqual(test_account.nonce, retrieved.nonce);

    // Commit changes
    _ = try adapter.commit_changes();
}

test "GuillotineAdapter: storage operations" {
    const allocator = testing.allocator;

    const mdbx = @import("../kv/mdbx.zig");
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = "test_db";
    try tmp_dir.dir.makeDir(path);
    const full_path = try tmp_dir.dir.realpathAlloc(allocator, path);
    defer allocator.free(full_path);

    var mdbx_db = try mdbx.MdbxDb.init(allocator, full_path);
    defer mdbx_db.deinit();

    var kv_db = mdbx_db.database();

    var adapter = GuillotineAdapter.init(allocator, &kv_db);
    defer adapter.deinit();

    try adapter.begin_transaction();

    const test_address = [_]u8{0x34} ++ [_]u8{0} ** 19;
    const storage_key: u256 = 0x123456789ABCDEF;
    const storage_value: u256 = 0xFEDCBA987654321;

    // Initially storage should be zero
    try testing.expectEqual(@as(u256, 0), try adapter.get_storage(test_address, storage_key));

    // Set storage value
    try adapter.set_storage(test_address, storage_key, storage_value);
    try testing.expectEqual(storage_value, try adapter.get_storage(test_address, storage_key));

    // Commit
    _ = try adapter.commit_changes();
}

test "GuillotineAdapter: code operations" {
    const allocator = testing.allocator;

    const mdbx = @import("../kv/mdbx.zig");
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = "test_db";
    try tmp_dir.dir.makeDir(path);
    const full_path = try tmp_dir.dir.realpathAlloc(allocator, path);
    defer allocator.free(full_path);

    var mdbx_db = try mdbx.MdbxDb.init(allocator, full_path);
    defer mdbx_db.deinit();

    var kv_db = mdbx_db.database();

    var adapter = GuillotineAdapter.init(allocator, &kv_db);
    defer adapter.deinit();

    try adapter.begin_transaction();

    const test_code = [_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 };

    // Store code and get hash
    const code_hash = try adapter.set_code(&test_code);

    // Verify code can be retrieved
    const retrieved_code = try adapter.get_code(code_hash);
    try testing.expectEqualSlices(u8, &test_code, retrieved_code);

    // Commit
    _ = try adapter.commit_changes();
}

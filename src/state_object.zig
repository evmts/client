//! StateObject - Represents a single Ethereum account being modified during execution
//! Based on Erigon's core/state/state_object.go
//!
//! This is the core structure that the EVM operates on. It maintains:
//! - Current and original account state
//! - Multi-tier storage caching for correct SSTORE gas calculation
//! - Code caching
//! - Dirty flags for optimization

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const database = @import("database.zig");
const U256 = @import("chain.zig").U256;

/// Storage is a map from storage keys to values (both 256-bit)
pub const Storage = std.AutoHashMap([32]u8, [32]u8);

/// StateObject represents an Ethereum account being modified
pub const StateObject = struct {
    allocator: std.mem.Allocator,

    /// Account address
    address: Address,

    /// Current account state
    data: database.Account,

    /// Original account state from database (for change tracking)
    original: database.Account,

    /// Contract bytecode (lazy loaded)
    code: ?[]const u8,

    /// Storage caching - 3-tier system for correct gas calculation
    ///
    /// originStorage: Original values from database (cached forever, never modified)
    /// Used for: Deduplication, SSTORE gas cost calculation
    origin_storage: Storage,

    /// blockOriginStorage: Values at start of current block
    /// Used for: EIP-2200/3529 SSTORE gas refund calculation
    block_origin_storage: Storage,

    /// dirtyStorage: Modified storage in current transaction
    /// Used for: Current values, write buffer
    dirty_storage: Storage,

    /// fakeStorage: Debug mode storage override (optional)
    /// Used for: Testing and debugging
    fake_storage: ?Storage,

    /// Flags
    dirty_code: bool,
    selfdestructed: bool,
    deleted: bool,
    newly_created: bool,
    created_contract: bool,

    const Self = @This();

    /// Create new state object for existing account
    pub fn init(
        allocator: std.mem.Allocator,
        address: Address,
        data: database.Account,
    ) Self {
        return .{
            .allocator = allocator,
            .address = address,
            .data = data,
            .original = data,
            .code = null,
            .origin_storage = Storage.init(allocator),
            .block_origin_storage = Storage.init(allocator),
            .dirty_storage = Storage.init(allocator),
            .fake_storage = null,
            .dirty_code = false,
            .selfdestructed = false,
            .deleted = false,
            .newly_created = false,
            .created_contract = false,
        };
    }

    /// Create new state object for newly created account
    pub fn initNewlyCreated(
        allocator: std.mem.Allocator,
        address: Address,
    ) Self {
        var obj = Self.init(allocator, address, database.Account.empty());
        obj.newly_created = true;
        return obj;
    }

    pub fn deinit(self: *Self) void {
        self.origin_storage.deinit();
        self.block_origin_storage.deinit();
        self.dirty_storage.deinit();
        if (self.fake_storage) |*fake| {
            fake.deinit();
        }
        if (self.code) |code| {
            self.allocator.free(code);
        }
    }

    /// Get current storage value with dirty cache check
    pub fn getState(self: *Self, key: [32]u8) ![32]u8 {
        // If fake storage is set (debug mode), use it
        if (self.fake_storage) |*fake| {
            return fake.get(key) orelse [_]u8{0} ** 32;
        }

        // Check dirty storage first (current transaction changes)
        if (self.dirty_storage.get(key)) |value| {
            return value;
        }

        // Then check committed storage
        return self.getCommittedState(key);
    }

    /// Get committed storage value (either cached or from DB)
    pub fn getCommittedState(self: *Self, key: [32]u8) ![32]u8 {
        // Check origin cache first
        if (self.origin_storage.get(key)) |value| {
            return value;
        }

        // TODO: Load from database via StateReader
        // For now, return zero and cache it
        const zero = [_]u8{0} ** 32;
        try self.origin_storage.put(key, zero);
        return zero;
    }

    /// Set storage value (must be called through IntraBlockState for journaling)
    pub fn setState(self: *Self, key: [32]u8, value: [32]u8) !void {
        // If fake storage exists, update it instead
        if (self.fake_storage) |*fake| {
            try fake.put(key, value);
            return;
        }

        // Update dirty storage
        try self.dirty_storage.put(key, value);
    }

    /// Set entire storage (debug mode only)
    pub fn setStorage(self: *Self, storage: Storage) !void {
        // Allocate fake storage if needed
        if (self.fake_storage == null) {
            self.fake_storage = Storage.init(self.allocator);
        }

        // Copy all entries
        var iter = storage.iterator();
        while (iter.next()) |entry| {
            try self.fake_storage.?.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    /// Get account balance
    pub fn balance(self: *const Self) U256 {
        return U256.fromBytes(self.data.balance);
    }

    /// Set account balance (must be called through IntraBlockState for journaling)
    pub fn setBalance(self: *Self, amount: U256) void {
        self.data.balance = amount.toBytes();
    }

    /// Get account nonce
    pub fn nonce(self: *const Self) u64 {
        return self.data.nonce;
    }

    /// Set account nonce (must be called through IntraBlockState for journaling)
    pub fn setNonce(self: *Self, new_nonce: u64) void {
        self.data.nonce = new_nonce;
    }

    /// Get contract code (lazy loads from database)
    pub fn code(self: *Self) ![]const u8 {
        // If already loaded, return it
        if (self.code) |c| {
            return c;
        }

        // Check if account has code
        const empty_hash = [_]u8{0} ** 32;
        if (std.mem.eql(u8, &self.data.code_hash, &empty_hash)) {
            return &[_]u8{};
        }

        // TODO: Load from database via StateReader
        // For now, return empty
        return &[_]u8{};
    }

    /// Set contract code (must be called through IntraBlockState for journaling)
    pub fn setCode(self: *Self, code_hash: [32]u8, new_code: []const u8) !void {
        // Store code copy
        const code_copy = try self.allocator.dupe(u8, new_code);
        if (self.code) |old_code| {
            self.allocator.free(old_code);
        }
        self.code = code_copy;
        self.data.code_hash = code_hash;
        self.dirty_code = true;
    }

    /// Get account address
    pub fn getAddress(self: *const Self) Address {
        return self.address;
    }

    /// Get code hash
    pub fn codeHash(self: *const Self) [32]u8 {
        return self.data.code_hash;
    }

    /// Set incarnation (for contract recreation)
    pub fn setIncarnation(self: *Self, incarnation: u64) void {
        self.data.incarnation = incarnation;
    }

    /// Get incarnation
    pub fn incarnation(self: *const Self) u64 {
        return self.data.incarnation;
    }

    /// Check if object has uncommitted changes
    pub fn isDirty(self: *const Self) bool {
        // Check if code changed
        if (self.dirty_code) return true;

        // Check if storage changed
        if (self.dirty_storage.count() > 0) return true;

        // Check if account data changed
        if (self.data.nonce != self.original.nonce) return true;
        if (!std.mem.eql(u8, &self.data.balance, &self.original.balance)) return true;
        if (!std.mem.eql(u8, &self.data.code_hash, &self.original.code_hash)) return true;

        return false;
    }

    /// Mark account as self-destructed
    pub fn markSelfdestructed(self: *Self) void {
        self.selfdestructed = true;
    }

    /// Check if account is self-destructed
    pub fn isSelfdestructed(self: *const Self) bool {
        return self.selfdestructed;
    }

    /// Mark account as deleted
    pub fn markDeleted(self: *Self) void {
        self.deleted = true;
    }

    /// Check if account is empty (EIP-161)
    /// An account is empty if nonce=0, balance=0, and code hash is empty
    pub fn isEmpty(self: *const Self) bool {
        const empty_hash = [_]u8{0} ** 32;
        const zero_balance = [_]u8{0} ** 32;

        return self.data.nonce == 0 and
            std.mem.eql(u8, &self.data.balance, &zero_balance) and
            std.mem.eql(u8, &self.data.code_hash, &empty_hash);
    }

    /// Update storage in database (flush dirty storage)
    pub fn updateStorage(self: *Self, writer: anytype) !void {
        var iter = self.dirty_storage.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            // Get block origin value for deduplication
            const block_origin = self.block_origin_storage.get(key) orelse [_]u8{0} ** 32;

            // Write to database
            try writer.writeAccountStorage(
                self.address,
                self.data.incarnation,
                key,
                block_origin,
                value,
            );

            // Update origin storage cache
            try self.origin_storage.put(key, value);
        }
    }

    /// Deep copy for snapshots
    pub fn deepCopy(self: *const Self) !Self {
        var copy = Self{
            .allocator = self.allocator,
            .address = self.address,
            .data = self.data,
            .original = self.original,
            .code = null,
            .origin_storage = Storage.init(self.allocator),
            .block_origin_storage = Storage.init(self.allocator),
            .dirty_storage = Storage.init(self.allocator),
            .fake_storage = null,
            .dirty_code = self.dirty_code,
            .selfdestructed = self.selfdestructed,
            .deleted = self.deleted,
            .newly_created = self.newly_created,
            .created_contract = self.created_contract,
        };

        // Copy code if present
        if (self.code) |c| {
            copy.code = try self.allocator.dupe(u8, c);
        }

        // Copy storage maps
        var iter = self.origin_storage.iterator();
        while (iter.next()) |entry| {
            try copy.origin_storage.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        iter = self.block_origin_storage.iterator();
        while (iter.next()) |entry| {
            try copy.block_origin_storage.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        iter = self.dirty_storage.iterator();
        while (iter.next()) |entry| {
            try copy.dirty_storage.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Copy fake storage if present
        if (self.fake_storage) |*fake| {
            var fake_copy = Storage.init(self.allocator);
            var fake_iter = fake.iterator();
            while (fake_iter.next()) |entry| {
                try fake_copy.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            copy.fake_storage = fake_copy;
        }

        return copy;
    }
};

test "state_object creation" {
    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const account = database.Account.empty();

    var obj = StateObject.init(std.testing.allocator, addr, account);
    defer obj.deinit();

    try std.testing.expect(obj.nonce() == 0);
    try std.testing.expect(!obj.isDirty());
}

test "state_object storage operations" {
    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const account = database.Account.empty();

    var obj = StateObject.init(std.testing.allocator, addr, account);
    defer obj.deinit();

    const key = [_]u8{1} ++ [_]u8{0} ** 31;
    const value = [_]u8{42} ++ [_]u8{0} ** 31;

    // Initially should be zero
    const initial = try obj.getState(key);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &initial);

    // Set value
    try obj.setState(key, value);

    // Should now return the value
    const retrieved = try obj.getState(key);
    try std.testing.expectEqualSlices(u8, &value, &retrieved);

    // Object should be dirty
    try std.testing.expect(obj.isDirty());
}

test "state_object balance operations" {
    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const account = database.Account.empty();

    var obj = StateObject.init(std.testing.allocator, addr, account);
    defer obj.deinit();

    const balance = U256.fromInt(1000);
    obj.setBalance(balance);

    const retrieved = obj.balance();
    try std.testing.expect(retrieved.eql(balance));
    try std.testing.expect(obj.isDirty());
}

test "state_object nonce operations" {
    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const account = database.Account.empty();

    var obj = StateObject.init(std.testing.allocator, addr, account);
    defer obj.deinit();

    obj.setNonce(5);
    try std.testing.expectEqual(@as(u64, 5), obj.nonce());
    try std.testing.expect(obj.isDirty());
}

test "state_object empty check" {
    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const account = database.Account.empty();

    var obj = StateObject.init(std.testing.allocator, addr, account);
    defer obj.deinit();

    // Should be empty initially
    try std.testing.expect(obj.isEmpty());

    // Set nonce - no longer empty
    obj.setNonce(1);
    try std.testing.expect(!obj.isEmpty());
}

test "state_object self-destruct" {
    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const account = database.Account.empty();

    var obj = StateObject.init(std.testing.allocator, addr, account);
    defer obj.deinit();

    try std.testing.expect(!obj.isSelfdestructed());

    obj.markSelfdestructed();
    try std.testing.expect(obj.isSelfdestructed());
}

test "state_object deep copy" {
    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const account = database.Account.empty();

    var obj = StateObject.init(std.testing.allocator, addr, account);
    defer obj.deinit();

    obj.setNonce(5);
    const key = [_]u8{1} ++ [_]u8{0} ** 31;
    const value = [_]u8{42} ++ [_]u8{0} ** 31;
    try obj.setState(key, value);

    var copy = try obj.deepCopy();
    defer copy.deinit();

    // Copy should have same data
    try std.testing.expectEqual(obj.nonce(), copy.nonce());
    const copied_value = try copy.getState(key);
    try std.testing.expectEqualSlices(u8, &value, &copied_value);

    // Modifying copy shouldn't affect original
    copy.setNonce(10);
    try std.testing.expectEqual(@as(u64, 5), obj.nonce());
    try std.testing.expectEqual(@as(u64, 10), copy.nonce());
}

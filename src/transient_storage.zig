//! Transient Storage (EIP-1153)
//! Based on Erigon's core/state/transient_storage.go
//!
//! EIP-1153 introduces transient storage opcodes (TLOAD/TSTORE)
//! that provide cheap temporary storage cleared between transactions.
//!
//! Key differences from regular storage:
//! - Cleared at the end of each transaction (not persisted)
//! - Much cheaper gas cost (100 gas vs 20,000+ for SSTORE)
//! - Use cases: reentrancy locks, temporary flags, cross-contract communication
//! - Must still be journaled for proper revert semantics

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const U256 = @import("chain.zig").U256;

/// Storage key type (32 bytes)
const StorageKey = [32]u8;

/// Storage value type (32 bytes)
const StorageValue = [32]u8;

/// Inner storage map for a single address (key -> value)
const AddressStorage = std.AutoHashMap(StorageKey, StorageValue);

/// TransientStorage - per-transaction temporary storage
/// Implements EIP-1153: Transient storage opcodes
pub const TransientStorage = struct {
    allocator: std.mem.Allocator,

    /// Map from address to its transient storage
    storage: std.AutoHashMap(Address, AddressStorage),

    const Self = @This();

    /// Create new transient storage instance
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .storage = std.AutoHashMap(Address, AddressStorage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all inner storage maps
        var iter = self.storage.valueIterator();
        while (iter.next()) |addr_storage| {
            addr_storage.deinit();
        }
        self.storage.deinit();
    }

    /// Set transient storage value (TSTORE opcode)
    /// Gas cost: 100 (much cheaper than SSTORE)
    pub fn set(self: *Self, address: Address, key: StorageKey, value: StorageValue) !void {
        // Get or create storage for this address
        const result = try self.storage.getOrPut(address);
        if (!result.found_existing) {
            result.value_ptr.* = AddressStorage.init(self.allocator);
        }

        // Set the value
        try result.value_ptr.put(key, value);
    }

    /// Get transient storage value (TLOAD opcode)
    /// Gas cost: 100
    /// Returns zero if key doesn't exist
    pub fn get(self: *Self, address: Address, key: StorageKey) StorageValue {
        // Get storage for this address
        const addr_storage = self.storage.get(address) orelse {
            // No storage for this address - return zero
            return [_]u8{0} ** 32;
        };

        // Get value or return zero
        return addr_storage.get(key) orelse [_]u8{0} ** 32;
    }

    /// Clear all transient storage
    /// Must be called at the end of each transaction
    pub fn clear(self: *Self) void {
        // Free all inner storage maps
        var iter = self.storage.valueIterator();
        while (iter.next()) |addr_storage| {
            addr_storage.deinit();
        }

        // Clear outer map
        self.storage.clearRetainingCapacity();
    }

    /// Copy transient storage (for snapshots)
    pub fn copy(self: *const Self) !Self {
        var new_storage = Self.init(self.allocator);

        // Copy all address storage maps
        var outer_iter = self.storage.iterator();
        while (outer_iter.next()) |outer_entry| {
            const address = outer_entry.key_ptr.*;
            const addr_storage = outer_entry.value_ptr.*;

            // Create new storage map for this address
            var new_addr_storage = AddressStorage.init(self.allocator);

            // Copy all entries
            var inner_iter = addr_storage.iterator();
            while (inner_iter.next()) |inner_entry| {
                try new_addr_storage.put(inner_entry.key_ptr.*, inner_entry.value_ptr.*);
            }

            try new_storage.storage.put(address, new_addr_storage);
        }

        return new_storage;
    }

    /// Get number of addresses with transient storage
    pub fn count(self: *const Self) usize {
        return self.storage.count();
    }

    /// Check if address has any transient storage
    pub fn hasStorage(self: *const Self, address: Address) bool {
        if (self.storage.get(address)) |addr_storage| {
            return addr_storage.count() > 0;
        }
        return false;
    }
};

// Tests

test "transient_storage basic operations" {
    var ts = TransientStorage.init(std.testing.allocator);
    defer ts.deinit();

    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const key = [_]u8{1} ++ [_]u8{0} ** 31;
    const value = [_]u8{42} ++ [_]u8{0} ** 31;

    // Initially should return zero
    const initial = ts.get(addr, key);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &initial);

    // Set value
    try ts.set(addr, key, value);

    // Should now return the value
    const retrieved = ts.get(addr, key);
    try std.testing.expectEqualSlices(u8, &value, &retrieved);
}

test "transient_storage multiple addresses" {
    var ts = TransientStorage.init(std.testing.allocator);
    defer ts.deinit();

    const addr1 = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const addr2 = primitives.Address.fromBytes([_]u8{2} ++ [_]u8{0} ** 19);
    const key = [_]u8{1} ++ [_]u8{0} ** 31;
    const value1 = [_]u8{42} ++ [_]u8{0} ** 31;
    const value2 = [_]u8{99} ++ [_]u8{0} ** 31;

    try ts.set(addr1, key, value1);
    try ts.set(addr2, key, value2);

    // Each address should have its own value
    const retrieved1 = ts.get(addr1, key);
    const retrieved2 = ts.get(addr2, key);

    try std.testing.expectEqualSlices(u8, &value1, &retrieved1);
    try std.testing.expectEqualSlices(u8, &value2, &retrieved2);
}

test "transient_storage multiple keys" {
    var ts = TransientStorage.init(std.testing.allocator);
    defer ts.deinit();

    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const key1 = [_]u8{1} ++ [_]u8{0} ** 31;
    const key2 = [_]u8{2} ++ [_]u8{0} ** 31;
    const value1 = [_]u8{42} ++ [_]u8{0} ** 31;
    const value2 = [_]u8{99} ++ [_]u8{0} ** 31;

    try ts.set(addr, key1, value1);
    try ts.set(addr, key2, value2);

    const retrieved1 = ts.get(addr, key1);
    const retrieved2 = ts.get(addr, key2);

    try std.testing.expectEqualSlices(u8, &value1, &retrieved1);
    try std.testing.expectEqualSlices(u8, &value2, &retrieved2);
}

test "transient_storage clear" {
    var ts = TransientStorage.init(std.testing.allocator);
    defer ts.deinit();

    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const key = [_]u8{1} ++ [_]u8{0} ** 31;
    const value = [_]u8{42} ++ [_]u8{0} ** 31;

    try ts.set(addr, key, value);

    // Value should exist
    var retrieved = ts.get(addr, key);
    try std.testing.expectEqualSlices(u8, &value, &retrieved);

    // Clear all storage
    ts.clear();

    // Value should now be zero
    retrieved = ts.get(addr, key);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &retrieved);
}

test "transient_storage copy" {
    var ts = TransientStorage.init(std.testing.allocator);
    defer ts.deinit();

    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const key = [_]u8{1} ++ [_]u8{0} ** 31;
    const value = [_]u8{42} ++ [_]u8{0} ** 31;

    try ts.set(addr, key, value);

    // Make a copy
    var copy = try ts.copy();
    defer copy.deinit();

    // Copy should have same value
    const retrieved = copy.get(addr, key);
    try std.testing.expectEqualSlices(u8, &value, &retrieved);

    // Modifying copy shouldn't affect original
    const new_value = [_]u8{99} ++ [_]u8{0} ** 31;
    try copy.set(addr, key, new_value);

    const original_value = ts.get(addr, key);
    const copied_value = copy.get(addr, key);

    try std.testing.expectEqualSlices(u8, &value, &original_value);
    try std.testing.expectEqualSlices(u8, &new_value, &copied_value);
}

test "transient_storage count and hasStorage" {
    var ts = TransientStorage.init(std.testing.allocator);
    defer ts.deinit();

    const addr1 = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const addr2 = primitives.Address.fromBytes([_]u8{2} ++ [_]u8{0} ** 19);
    const key = [_]u8{1} ++ [_]u8{0} ** 31;
    const value = [_]u8{42} ++ [_]u8{0} ** 31;

    try std.testing.expectEqual(@as(usize, 0), ts.count());
    try std.testing.expect(!ts.hasStorage(addr1));

    try ts.set(addr1, key, value);
    try std.testing.expectEqual(@as(usize, 1), ts.count());
    try std.testing.expect(ts.hasStorage(addr1));
    try std.testing.expect(!ts.hasStorage(addr2));

    try ts.set(addr2, key, value);
    try std.testing.expectEqual(@as(usize, 2), ts.count());
    try std.testing.expect(ts.hasStorage(addr2));
}

test "transient_storage overwrite value" {
    var ts = TransientStorage.init(std.testing.allocator);
    defer ts.deinit();

    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const key = [_]u8{1} ++ [_]u8{0} ** 31;
    const value1 = [_]u8{42} ++ [_]u8{0} ** 31;
    const value2 = [_]u8{99} ++ [_]u8{0} ** 31;

    try ts.set(addr, key, value1);
    var retrieved = ts.get(addr, key);
    try std.testing.expectEqualSlices(u8, &value1, &retrieved);

    // Overwrite
    try ts.set(addr, key, value2);
    retrieved = ts.get(addr, key);
    try std.testing.expectEqualSlices(u8, &value2, &retrieved);
}

test "transient_storage stress test" {
    var ts = TransientStorage.init(std.testing.allocator);
    defer ts.deinit();

    // Create 100 addresses with 10 keys each
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var addr_bytes = [_]u8{0} ** 20;
        addr_bytes[0] = @intCast(i);
        const addr = primitives.Address.fromBytes(addr_bytes);

        var j: usize = 0;
        while (j < 10) : (j += 1) {
            var key = [_]u8{0} ** 32;
            key[0] = @intCast(j);
            var value = [_]u8{0} ** 32;
            value[0] = @intCast(i + j);

            try ts.set(addr, key, value);
        }
    }

    // Verify all values
    try std.testing.expectEqual(@as(usize, 100), ts.count());

    i = 0;
    while (i < 100) : (i += 1) {
        var addr_bytes = [_]u8{0} ** 20;
        addr_bytes[0] = @intCast(i);
        const addr = primitives.Address.fromBytes(addr_bytes);

        var j: usize = 0;
        while (j < 10) : (j += 1) {
            var key = [_]u8{0} ** 32;
            key[0] = @intCast(j);
            var expected_value = [_]u8{0} ** 32;
            expected_value[0] = @intCast(i + j);

            const retrieved = ts.get(addr, key);
            try std.testing.expectEqualSlices(u8, &expected_value, &retrieved);
        }
    }
}

//! Journal - State modification tracking for rollback support
//! Based on Erigon's core/state/journal.go
//!
//! The journal tracks all state changes during transaction execution.
//! Each entry can be reverted in reverse order (LIFO) for proper rollback semantics.
//!
//! Key features:
//! - All modifications are journaled
//! - Snapshot/revert support
//! - Dirty tracking for optimization
//! - Support for all EVM state changes

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const U256 = @import("chain.zig").U256;

/// Journal entry - represents a single reversible state change
pub const JournalEntry = union(enum) {
    /// Account creation
    create_object: struct {
        account: Address,
    },

    /// Account reset (contract recreation)
    reset_object: struct {
        account: Address,
        // prev state object would be stored in IntraBlockState
    },

    /// Self-destruct
    selfdestruct: struct {
        account: Address,
        prev_selfdestructed: bool,
        prev_balance: [32]u8,  // u256 as bytes
        was_committed: bool,
    },

    /// Balance change
    balance_change: struct {
        account: Address,
        prev: [32]u8,  // u256 as bytes
        was_committed: bool,
    },

    /// Balance increase (optimized - no read first)
    balance_increase: struct {
        account: Address,
        increase: [32]u8,  // u256 as bytes
    },

    /// Balance increase transfer (marks BalanceIncrease as transferred)
    balance_increase_transfer: struct {
        account: Address,
    },

    /// Nonce change
    nonce_change: struct {
        account: Address,
        prev: u64,
        was_committed: bool,
    },

    /// Storage change
    storage_change: struct {
        account: Address,
        key: [32]u8,
        prev_value: [32]u8,  // u256 as bytes
        was_committed: bool,
    },

    /// Fake storage change (debug mode)
    fake_storage_change: struct {
        account: Address,
        key: [32]u8,
        prev_value: [32]u8,  // u256 as bytes
    },

    /// Code change
    code_change: struct {
        account: Address,
        prev_hash: [32]u8,
        was_committed: bool,
        // prev_code stored separately in IntraBlockState
    },

    /// Refund change
    refund_change: struct {
        prev: u64,
    },

    /// Log added
    add_log: struct {
        tx_index: usize,
    },

    /// Touch (RIPEMD precompile consensus exception)
    touch: struct {
        account: Address,
    },

    /// Access list - address added
    access_list_address: struct {
        address: Address,
    },

    /// Access list - storage slot added
    access_list_slot: struct {
        address: Address,
        slot: [32]u8,
    },

    /// Transient storage change (EIP-1153)
    transient_storage: struct {
        account: Address,
        key: [32]u8,
        prev_value: [32]u8,  // u256 as bytes
    },

    /// Get the address that was dirtied by this entry (if any)
    pub fn getDirtiedAddress(self: *const JournalEntry) ?Address {
        return switch (self.*) {
            .create_object => |e| e.account,
            .reset_object => null,  // Reset doesn't dirty the account
            .selfdestruct => |e| e.account,
            .balance_change => |e| e.account,
            .balance_increase => |e| e.account,
            .balance_increase_transfer => null,
            .nonce_change => |e| e.account,
            .storage_change => |e| e.account,
            .fake_storage_change => |e| e.account,
            .code_change => |e| e.account,
            .refund_change => null,
            .add_log => null,
            .touch => |e| e.account,
            .access_list_address => |e| e.address,
            .access_list_slot => |e| e.address,
            .transient_storage => |e| e.account,
        };
    }
};

/// Journal - tracks state modifications for rollback
pub const Journal = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(JournalEntry),
    dirties: std.AutoHashMap(Address, usize),  // Track dirty count per address

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(JournalEntry).init(allocator),
            .dirties = std.AutoHashMap(Address, usize).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
        self.dirties.deinit();
    }

    /// Reset journal to empty state
    pub fn reset(self: *Self) void {
        self.entries.clearRetainingCapacity();
        self.dirties.clearRetainingCapacity();
    }

    /// Append a new journal entry
    pub fn append(self: *Self, entry: JournalEntry) !void {
        try self.entries.append(entry);

        // Track dirty address
        if (entry.getDirtiedAddress()) |addr| {
            const result = try self.dirties.getOrPut(addr);
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 1;
            }
        }
    }

    /// Mark an address as dirty explicitly
    /// (RIPEMD precompile consensus exception)
    pub fn dirty(self: *Self, address: Address) !void {
        const result = try self.dirties.getOrPut(address);
        if (result.found_existing) {
            result.value_ptr.* += 1;
        } else {
            result.value_ptr.* = 1;
        }
    }

    /// Get current journal length (for snapshots)
    pub fn length(self: *const Self) usize {
        return self.entries.items.len;
    }

    /// Revert to a snapshot point
    /// NOTE: Actual revert logic is in IntraBlockState.revertToSnapshot()
    /// This just handles dirty tracking cleanup
    pub fn revertDirties(self: *Self, snapshot: usize) void {
        // Walk backwards from current to snapshot
        var i = self.entries.items.len;
        while (i > snapshot) {
            i -= 1;
            const entry = &self.entries.items[i];

            // Decrement dirty count
            if (entry.getDirtiedAddress()) |addr| {
                if (self.dirties.getPtr(addr)) |count_ptr| {
                    count_ptr.* -= 1;
                    if (count_ptr.* == 0) {
                        _ = self.dirties.remove(addr);
                    }
                }
            }
        }
    }

    /// Check if an address is dirty
    pub fn isDirty(self: *const Self, address: Address) bool {
        return self.dirties.contains(address);
    }

    /// Get dirty count for an address
    pub fn getDirtyCount(self: *const Self, address: Address) usize {
        return self.dirties.get(address) orelse 0;
    }

    /// Get all dirty addresses
    pub fn getDirtyAddresses(self: *const Self, allocator: std.mem.Allocator) ![]Address {
        var addresses = std.ArrayList(Address).init(allocator);
        defer addresses.deinit();

        var iter = self.dirties.keyIterator();
        while (iter.next()) |addr_ptr| {
            try addresses.append(addr_ptr.*);
        }

        return try addresses.toOwnedSlice();
    }
};

// Tests

test "journal basic operations" {
    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();

    try std.testing.expectEqual(@as(usize, 0), journal.length());

    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    try journal.append(.{
        .nonce_change = .{
            .account = addr,
            .prev = 5,
            .was_committed = false,
        },
    });

    try std.testing.expectEqual(@as(usize, 1), journal.length());
    try std.testing.expect(journal.isDirty(addr));
    try std.testing.expectEqual(@as(usize, 1), journal.getDirtyCount(addr));
}

test "journal dirty tracking" {
    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();

    const addr1 = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const addr2 = primitives.Address.fromBytes([_]u8{2} ++ [_]u8{0} ** 19);

    // Add multiple changes to addr1
    try journal.append(.{ .balance_change = .{ .account = addr1, .prev = [_]u8{0} ** 32, .was_committed = false } });
    try journal.append(.{ .nonce_change = .{ .account = addr1, .prev = 0, .was_committed = false } });
    try journal.append(.{ .balance_change = .{ .account = addr2, .prev = [_]u8{0} ** 32, .was_committed = false } });

    try std.testing.expectEqual(@as(usize, 2), journal.getDirtyCount(addr1));
    try std.testing.expectEqual(@as(usize, 1), journal.getDirtyCount(addr2));
}

test "journal revert dirties" {
    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();

    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);

    try journal.append(.{ .nonce_change = .{ .account = addr, .prev = 0, .was_committed = false } });
    const snapshot = journal.length();

    try journal.append(.{ .balance_change = .{ .account = addr, .prev = [_]u8{0} ** 32, .was_committed = false } });
    try journal.append(.{ .storage_change = .{ .account = addr, .key = [_]u8{0} ** 32, .prev_value = [_]u8{0} ** 32, .was_committed = false } });

    try std.testing.expectEqual(@as(usize, 3), journal.getDirtyCount(addr));

    // Revert to snapshot
    journal.revertDirties(snapshot);

    try std.testing.expectEqual(@as(usize, 1), journal.getDirtyCount(addr));
}

test "journal multiple addresses" {
    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();

    const addr1 = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const addr2 = primitives.Address.fromBytes([_]u8{2} ++ [_]u8{0} ** 19);
    const addr3 = primitives.Address.fromBytes([_]u8{3} ++ [_]u8{0} ** 19);

    try journal.append(.{ .balance_change = .{ .account = addr1, .prev = [_]u8{0} ** 32, .was_committed = false } });
    try journal.append(.{ .balance_change = .{ .account = addr2, .prev = [_]u8{0} ** 32, .was_committed = false } });
    try journal.append(.{ .balance_change = .{ .account = addr3, .prev = [_]u8{0} ** 32, .was_committed = false } });

    const dirty_addrs = try journal.getDirtyAddresses(std.testing.allocator);
    defer std.testing.allocator.free(dirty_addrs);

    try std.testing.expectEqual(@as(usize, 3), dirty_addrs.len);
}

test "journal explicit dirty" {
    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();

    const addr = primitives.Address.fromBytes([_]u8{3} ++ [_]u8{0} ** 19);  // RIPEMD precompile

    try std.testing.expect(!journal.isDirty(addr));

    // Explicit dirty (for RIPEMD consensus exception)
    try journal.dirty(addr);

    try std.testing.expect(journal.isDirty(addr));
    try std.testing.expectEqual(@as(usize, 1), journal.getDirtyCount(addr));
}

test "journal reset" {
    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();

    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);

    try journal.append(.{ .nonce_change = .{ .account = addr, .prev = 0, .was_committed = false } });
    try journal.append(.{ .balance_change = .{ .account = addr, .prev = [_]u8{0} ** 32, .was_committed = false } });

    try std.testing.expectEqual(@as(usize, 2), journal.length());
    try std.testing.expect(journal.isDirty(addr));

    journal.reset();

    try std.testing.expectEqual(@as(usize, 0), journal.length());
    try std.testing.expect(!journal.isDirty(addr));
}

test "journal all entry types" {
    var journal = Journal.init(std.testing.allocator);
    defer journal.deinit();

    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);
    const key = [_]u8{1} ++ [_]u8{0} ** 31;
    const value = [_]u8{42} ++ [_]u8{0} ** 31;

    // Test all entry types
    try journal.append(.{ .create_object = .{ .account = addr } });
    try journal.append(.{ .selfdestruct = .{ .account = addr, .prev_selfdestructed = false, .prev_balance = value, .was_committed = false } });
    try journal.append(.{ .balance_change = .{ .account = addr, .prev = value, .was_committed = false } });
    try journal.append(.{ .balance_increase = .{ .account = addr, .increase = value } });
    try journal.append(.{ .nonce_change = .{ .account = addr, .prev = 5, .was_committed = false } });
    try journal.append(.{ .storage_change = .{ .account = addr, .key = key, .prev_value = value, .was_committed = false } });
    try journal.append(.{ .code_change = .{ .account = addr, .prev_hash = key, .was_committed = false } });
    try journal.append(.{ .refund_change = .{ .prev = 100 } });
    try journal.append(.{ .add_log = .{ .tx_index = 0 } });
    try journal.append(.{ .touch = .{ .account = addr } });
    try journal.append(.{ .access_list_address = .{ .address = addr } });
    try journal.append(.{ .access_list_slot = .{ .address = addr, .slot = key } });
    try journal.append(.{ .transient_storage = .{ .account = addr, .key = key, .prev_value = value } });

    try std.testing.expectEqual(@as(usize, 13), journal.length());
}

test "journal entry dirtied addresses" {
    const addr = primitives.Address.fromBytes([_]u8{1} ++ [_]u8{0} ** 19);

    // Entries that dirty an address
    const creates_dirty = JournalEntry{ .create_object = .{ .account = addr } };
    try std.testing.expect(creates_dirty.getDirtiedAddress() != null);

    const balance_dirty = JournalEntry{ .balance_change = .{ .account = addr, .prev = [_]u8{0} ** 32, .was_committed = false } };
    try std.testing.expect(balance_dirty.getDirtiedAddress() != null);

    // Entries that don't dirty an address
    const refund_no_dirty = JournalEntry{ .refund_change = .{ .prev = 100 } };
    try std.testing.expect(refund_no_dirty.getDirtiedAddress() == null);

    const reset_no_dirty = JournalEntry{ .reset_object = .{ .account = addr } };
    try std.testing.expect(reset_no_dirty.getDirtiedAddress() == null);
}

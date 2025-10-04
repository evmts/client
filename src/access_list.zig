//! Access List implementation for EIP-2929 and EIP-2930
//!
//! EIP-2929: Gas cost increases for state access opcodes
//! - Cold account access: 2600 gas
//! - Warm account access: 100 gas
//! - Cold SLOAD: 2100 gas
//! - Warm SLOAD: 100 gas
//!
//! EIP-2930: Optional access list in transaction
//! - Allows pre-declaring accessed addresses/slots
//! - Pre-declared addresses/slots are warm from transaction start
//!
//! Based on:
//! - erigon/core/state/access_list.go
//! - guillotine/src/storage/access_list.zig

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;

/// Gas costs for access list operations (EIP-2929)
pub const GAS_COLD_ACCOUNT_ACCESS: u64 = 2600;
pub const GAS_WARM_ACCOUNT_ACCESS: u64 = 100;
pub const GAS_COLD_SLOAD: u64 = 2100;
pub const GAS_WARM_SLOAD: u64 = 100;

/// Access list tracks warm/cold access state for addresses and storage slots
pub const AccessList = struct {
    /// Map of addresses to their storage slot sets
    /// If value is null, address is warm but no slots are tracked
    /// If value is non-null, it contains the set of warm storage slots
    addresses: std.AutoHashMap(Address, ?*SlotSet),
    allocator: std.mem.Allocator,

    const SlotSet = std.AutoHashMap([32]u8, void);

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .addresses = std.AutoHashMap(Address, ?*SlotSet).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all slot sets
        var it = self.addresses.valueIterator();
        while (it.next()) |slot_set_ptr| {
            if (slot_set_ptr.*) |slot_set| {
                slot_set.deinit();
                self.allocator.destroy(slot_set);
            }
        }
        self.addresses.deinit();
    }

    /// Check if address is in the access list
    pub fn containsAddress(self: *const Self, address: Address) bool {
        return self.addresses.contains(address);
    }

    /// Check if address and slot are in the access list
    /// Returns (addressPresent, slotPresent)
    pub fn contains(self: *const Self, address: Address, slot: [32]u8) struct { address_present: bool, slot_present: bool } {
        const slot_set = self.addresses.get(address) orelse return .{ .address_present = false, .slot_present = false };

        if (slot_set) |set| {
            return .{ .address_present = true, .slot_present = set.contains(slot) };
        } else {
            // Address is present but no slots tracked
            return .{ .address_present = true, .slot_present = false };
        }
    }

    /// Add an address to the access list
    /// Returns true if this caused a change (address was not previously in the list)
    pub fn addAddress(self: *Self, address: Address) !bool {
        const result = try self.addresses.getOrPut(address);
        if (!result.found_existing) {
            result.value_ptr.* = null; // No slots yet
            return true;
        }
        return false;
    }

    /// Add a storage slot to the access list
    /// Returns (addressAdded, slotAdded)
    /// For any 'true' value returned, a corresponding journal entry must be made
    pub fn addSlot(self: *Self, address: Address, slot: [32]u8) !struct { address_added: bool, slot_added: bool } {
        const addr_result = try self.addresses.getOrPut(address);

        if (!addr_result.found_existing) {
            // Address not present - create new slot set
            const slot_set = try self.allocator.create(SlotSet);
            slot_set.* = SlotSet.init(self.allocator);
            try slot_set.put(slot, {});
            addr_result.value_ptr.* = slot_set;
            return .{ .address_added = true, .slot_added = true };
        }

        // Address already present
        if (addr_result.value_ptr.*) |slot_set| {
            // Slot set exists
            const slot_result = try slot_set.getOrPut(slot);
            return .{ .address_added = false, .slot_added = !slot_result.found_existing };
        } else {
            // Address present but no slots yet - create slot set
            const slot_set = try self.allocator.create(SlotSet);
            slot_set.* = SlotSet.init(self.allocator);
            try slot_set.put(slot, {});
            addr_result.value_ptr.* = slot_set;
            return .{ .address_added = false, .slot_added = true };
        }
    }

    /// Delete a slot from the access list (for journal rollback)
    /// This operation needs to be performed in the same order as the addition happened
    pub fn deleteSlot(self: *Self, address: Address, slot: [32]u8) void {
        const slot_set_ptr = self.addresses.getPtr(address) orelse {
            std.debug.panic("reverting slot change, address not present in list", .{});
        };

        if (slot_set_ptr.*) |slot_set| {
            _ = slot_set.remove(slot);

            // If that was the last slot, free the slot set
            if (slot_set.count() == 0) {
                slot_set.deinit();
                self.allocator.destroy(slot_set);
                slot_set_ptr.* = null;
            }
        } else {
            std.debug.panic("reverting slot change, slot set is null", .{});
        }
    }

    /// Delete an address from the access list (for journal rollback)
    /// This operation needs to be performed in the same order as the addition happened
    pub fn deleteAddress(self: *Self, address: Address) void {
        const slot_set = self.addresses.get(address) orelse {
            std.debug.panic("reverting address change, address not present in list", .{});
        };

        if (slot_set) |set| {
            if (set.count() > 0) {
                std.debug.panic("reverting address change, address has slots", .{});
            }
            set.deinit();
            self.allocator.destroy(set);
        }

        _ = self.addresses.remove(address);
    }

    /// Copy the access list
    pub fn copy(self: *const Self) !Self {
        var new = Self.init(self.allocator);
        errdefer new.deinit();

        var it = self.addresses.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |slot_set| {
                // Copy the slot set
                const new_slot_set = try self.allocator.create(SlotSet);
                new_slot_set.* = SlotSet.init(self.allocator);

                var slot_it = slot_set.keyIterator();
                while (slot_it.next()) |slot| {
                    try new_slot_set.put(slot.*, {});
                }

                try new.addresses.put(entry.key_ptr.*, new_slot_set);
            } else {
                try new.addresses.put(entry.key_ptr.*, null);
            }
        }

        return new;
    }

    /// Clear the access list (for new transaction)
    pub fn clear(self: *Self) void {
        // Free all slot sets
        var it = self.addresses.valueIterator();
        while (it.next()) |slot_set_ptr| {
            if (slot_set_ptr.*) |slot_set| {
                slot_set.deinit();
                self.allocator.destroy(slot_set);
            }
        }

        self.addresses.clearRetainingCapacity();
    }
};

/// Transaction access list entry (EIP-2930)
pub const AccessListEntry = struct {
    address: Address,
    storage_keys: []const [32]u8,
};

test "access list - address operations" {
    const testing = std.testing;
    var al = AccessList.init(testing.allocator);
    defer al.deinit();

    var addr: Address = undefined;
    @memset(&addr.bytes, 0x01);

    // Address not present initially
    try testing.expect(!al.containsAddress(addr));

    // Add address
    const added = try al.addAddress(addr);
    try testing.expect(added);
    try testing.expect(al.containsAddress(addr));

    // Adding again should not cause change
    const added_again = try al.addAddress(addr);
    try testing.expect(!added_again);
}

test "access list - slot operations" {
    const testing = std.testing;
    var al = AccessList.init(testing.allocator);
    defer al.deinit();

    var addr: Address = undefined;
    @memset(&addr.bytes, 0x01);

    var slot1: [32]u8 = undefined;
    @memset(&slot1, 0x10);

    var slot2: [32]u8 = undefined;
    @memset(&slot2, 0x20);

    // Add first slot (should add both address and slot)
    {
        const result = try al.addSlot(addr, slot1);
        try testing.expect(result.address_added);
        try testing.expect(result.slot_added);
    }

    // Check contains
    {
        const result = al.contains(addr, slot1);
        try testing.expect(result.address_present);
        try testing.expect(result.slot_present);
    }

    // Add second slot (address already present)
    {
        const result = try al.addSlot(addr, slot2);
        try testing.expect(!result.address_added);
        try testing.expect(result.slot_added);
    }

    // Add slot1 again (should not cause change)
    {
        const result = try al.addSlot(addr, slot1);
        try testing.expect(!result.address_added);
        try testing.expect(!result.slot_added);
    }
}

test "access list - delete operations" {
    const testing = std.testing;
    var al = AccessList.init(testing.allocator);
    defer al.deinit();

    var addr: Address = undefined;
    @memset(&addr.bytes, 0x01);

    var slot: [32]u8 = undefined;
    @memset(&slot, 0x10);

    // Add and then delete slot
    _ = try al.addSlot(addr, slot);
    try testing.expect(al.contains(addr, slot).slot_present);

    al.deleteSlot(addr, slot);
    try testing.expect(!al.contains(addr, slot).slot_present);
    try testing.expect(al.containsAddress(addr)); // Address still present

    // Delete address
    al.deleteAddress(addr);
    try testing.expect(!al.containsAddress(addr));
}

test "access list - copy" {
    const testing = std.testing;
    var al = AccessList.init(testing.allocator);
    defer al.deinit();

    var addr1: Address = undefined;
    @memset(&addr1.bytes, 0x01);

    var addr2: Address = undefined;
    @memset(&addr2.bytes, 0x02);

    var slot: [32]u8 = undefined;
    @memset(&slot, 0x10);

    _ = try al.addAddress(addr1);
    _ = try al.addSlot(addr2, slot);

    // Copy
    var copy_al = try al.copy();
    defer copy_al.deinit();

    // Verify copy has same contents
    try testing.expect(copy_al.containsAddress(addr1));
    try testing.expect(copy_al.contains(addr2, slot).slot_present);

    // Modify original
    _ = try al.addAddress(addr2);

    // Copy should not be affected
    try testing.expect(!al.contains(addr1, slot).slot_present);
}

test "access list - clear" {
    const testing = std.testing;
    var al = AccessList.init(testing.allocator);
    defer al.deinit();

    var addr: Address = undefined;
    @memset(&addr.bytes, 0x01);

    var slot: [32]u8 = undefined;
    @memset(&slot, 0x10);

    _ = try al.addSlot(addr, slot);
    try testing.expect(al.containsAddress(addr));

    al.clear();
    try testing.expect(!al.containsAddress(addr));
    try testing.expect(!al.contains(addr, slot).slot_present);
}

test "access list - EIP-2929 gas costs" {
    const testing = std.testing;

    // Verify gas constants match specification
    try testing.expectEqual(@as(u64, 2600), GAS_COLD_ACCOUNT_ACCESS);
    try testing.expectEqual(@as(u64, 100), GAS_WARM_ACCOUNT_ACCESS);
    try testing.expectEqual(@as(u64, 2100), GAS_COLD_SLOAD);
    try testing.expectEqual(@as(u64, 100), GAS_WARM_SLOAD);
}

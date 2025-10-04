//! EVM Memory
//! Based on Erigon's core/vm/memory.go
//! Implements the EVM's expandable byte-addressable memory

const std = @import("std");

/// Maximum memory size (2^32 bytes to prevent excessive allocation)
pub const MAX_MEMORY_SIZE = 0x100000000; // 4GB

/// EVM Memory - expandable byte array
pub const Memory = struct {
    store: std.ArrayList(u8),
    last_gas_cost: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Memory {
        return Memory{
            .store = .{
                .items = &.{},
                .capacity = 0,
            },
            .last_gas_cost = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Memory) void {
        self.store.deinit(self.allocator);
    }

    pub fn reset(self: *Memory) void {
        self.store.clearRetainingCapacity();
        self.last_gas_cost = 0;
    }

    /// Get length of memory in bytes
    pub fn len(self: *const Memory) usize {
        return self.store.items.len;
    }

    /// Resize memory to at least `size` bytes
    /// Memory is always expanded by whole 32-byte words
    pub fn resize(self: *Memory, size: u64) !void {
        if (size > MAX_MEMORY_SIZE) {
            return error.MemoryTooLarge;
        }

        const current_len = self.store.items.len;
        if (size <= current_len) {
            return; // Already large enough
        }

        const grow_by = @as(usize, @intCast(size)) - current_len;

        // Append zeros
        try self.store.appendNTimes(self.allocator, 0, grow_by);
    }

    /// Set memory[offset:offset+size] = value
    pub fn set(self: *Memory, offset: u64, size: u64, value: []const u8) !void {
        if (size == 0) return;

        const end = offset + size;
        if (end > self.store.items.len) {
            return error.MemoryAccessOutOfBounds;
        }

        const size_usize: usize = @intCast(size);
        const offset_usize: usize = @intCast(offset);
        @memcpy(self.store.items[offset_usize..][0..size_usize], value[0..@min(value.len, size_usize)]);
    }

    /// Set 32 bytes at offset to value (big-endian u256)
    pub fn set32(self: *Memory, offset: u64, value: u256) !void {
        const end = offset + 32;
        if (end > self.store.items.len) {
            return error.MemoryAccessOutOfBounds;
        }

        var bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &bytes, value, .big);
        @memcpy(self.store.items[@intCast(offset)..][0..32], &bytes);
    }

    /// Get copy of memory[offset:offset+size]
    pub fn getCopy(self: *const Memory, offset: u64, size: u64, allocator: std.mem.Allocator) ![]u8 {
        if (size == 0) return &.{};

        const end = offset + size;
        if (end > self.store.items.len) {
            return error.MemoryAccessOutOfBounds;
        }

        const size_usize: usize = @intCast(size);
        const offset_usize: usize = @intCast(offset);
        const result = try allocator.alloc(u8, size_usize);
        @memcpy(result, self.store.items[offset_usize..][0..size_usize]);
        return result;
    }

    /// Get pointer to memory[offset:offset+size] (no copy)
    pub fn getPtr(self: *Memory, offset: u64, size: u64) ![]u8 {
        if (size == 0) return &.{};

        const end = offset + size;
        if (end > self.store.items.len) {
            return error.MemoryAccessOutOfBounds;
        }

        return self.store.items[@intCast(offset)..][0..@intCast(size)];
    }

    /// Get 32 bytes from offset as u256 (big-endian)
    pub fn get32(self: *const Memory, offset: u64) !u256 {
        const end = offset + 32;
        if (end > self.store.items.len) {
            return error.MemoryAccessOutOfBounds;
        }

        var bytes: [32]u8 = undefined;
        @memcpy(&bytes, self.store.items[@intCast(offset)..][0..32]);
        return std.mem.readInt(u256, &bytes, .big);
    }

    /// Copy memory[src:src+length] to memory[dst:dst+length]
    /// Source and destination may overlap
    pub fn copyMem(self: *Memory, dst: u64, src: u64, length: u64) !void {
        if (length == 0) return;

        const src_end = src + length;
        const dst_end = dst + length;

        if (src_end > self.store.items.len or dst_end > self.store.items.len) {
            return error.MemoryAccessOutOfBounds;
        }

        const length_usize: usize = @intCast(length);
        const src_usize: usize = @intCast(src);
        const dst_usize: usize = @intCast(dst);

        // Use memmove semantics (handles overlap)
        const src_slice = self.store.items[src_usize..][0..length_usize];
        const dst_slice = self.store.items[dst_usize..][0..length_usize];

        // std.mem.copyForwards handles overlapping regions
        if (dst <= src) {
            std.mem.copyForwards(u8, dst_slice, src_slice);
        } else {
            std.mem.copyBackwards(u8, dst_slice, src_slice);
        }
    }

    /// Get all memory data
    pub fn data(self: *const Memory) []const u8 {
        return self.store.items;
    }

    /// Calculate memory expansion cost
    /// Returns new memory size and gas cost for expansion
    pub fn expansionCost(current_size: u64, new_size: u64) struct { size: u64, cost: u64 } {
        if (new_size <= current_size) {
            return .{ .size = current_size, .cost = 0 };
        }

        // Round up to next multiple of 32
        const rounded_size = ((new_size + 31) / 32) * 32;

        // Memory cost formula: words * 3 + words^2 / 512
        // Where words = size / 32
        const new_words = rounded_size / 32;
        const old_words = current_size / 32;

        const new_cost = new_words * 3 + (new_words * new_words) / 512;
        const old_cost = old_words * 3 + (old_words * old_words) / 512;

        return .{
            .size = rounded_size,
            .cost = new_cost - old_cost,
        };
    }
};

test "memory basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mem = Memory.init(allocator);
    defer mem.deinit();

    // Test resize
    try mem.resize(64);
    try testing.expectEqual(@as(usize, 64), mem.len());

    // Test set and get
    const test_data = [_]u8{ 1, 2, 3, 4, 5 };
    try mem.set(10, 5, &test_data);

    const retrieved = try mem.getPtr(10, 5);
    try testing.expectEqualSlices(u8, &test_data, retrieved);
}

test "memory set32 and get32" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mem = Memory.init(allocator);
    defer mem.deinit();

    try mem.resize(64);

    const test_value: u256 = 0x123456789ABCDEF0;
    try mem.set32(0, test_value);

    const retrieved = try mem.get32(0);
    try testing.expectEqual(test_value, retrieved);
}

test "memory copy" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mem = Memory.init(allocator);
    defer mem.deinit();

    try mem.resize(64);

    // Set some data
    const test_data = [_]u8{ 10, 20, 30, 40, 50 };
    try mem.set(0, 5, &test_data);

    // Copy it
    try mem.copyMem(10, 0, 5);

    // Verify
    const original = try mem.getPtr(0, 5);
    const copied = try mem.getPtr(10, 5);
    try testing.expectEqualSlices(u8, original, copied);
}

test "memory expansion cost" {
    const testing = std.testing;

    // Test no expansion
    const no_expand = Memory.expansionCost(64, 32);
    try testing.expectEqual(@as(u64, 64), no_expand.size);
    try testing.expectEqual(@as(u64, 0), no_expand.cost);

    // Test expansion from 0 to 32
    const expand_0_32 = Memory.expansionCost(0, 32);
    try testing.expectEqual(@as(u64, 32), expand_0_32.size);
    try testing.expectEqual(@as(u64, 3), expand_0_32.cost); // 1 word * 3

    // Test expansion from 32 to 64
    const expand_32_64 = Memory.expansionCost(32, 64);
    try testing.expectEqual(@as(u64, 64), expand_32_64.size);
    // New cost: 2*3 + 4/512 = 6
    // Old cost: 1*3 + 1/512 = 3
    // Delta: 3
    try testing.expectEqual(@as(u64, 3), expand_32_64.cost);
}

test "memory overlapping copy" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mem = Memory.init(allocator);
    defer mem.deinit();

    try mem.resize(64);

    // Set test pattern
    for (0..10) |i| {
        try mem.set(@intCast(i), 1, &[_]u8{@intCast(i)});
    }

    // Overlapping copy (forward)
    try mem.copyMem(5, 0, 5); // Copy [0..5] to [5..10]

    const result = try mem.getPtr(5, 5);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 4 }, result);
}

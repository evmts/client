//! EVM Stack
//! Based on Erigon's core/vm/stack.go
//! Implements the EVM's 256-bit value stack (max 1024 items)

const std = @import("std");

/// Maximum stack depth as per Ethereum Yellow Paper
pub const MAX_STACK_SIZE = 1024;

/// EVM Stack - stores u256 values
pub const Stack = struct {
    data: std.ArrayList(u256),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Stack {
        var data: std.ArrayList(u256) = .{
            .items = &.{},
            .capacity = 0,
        };
        try data.ensureTotalCapacity(allocator, 16);
        return Stack{
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Stack) void {
        self.data.deinit(self.allocator);
    }

    pub fn reset(self: *Stack) void {
        self.data.clearRetainingCapacity();
    }

    pub fn len(self: *const Stack) usize {
        return self.data.items.len;
    }

    pub fn push(self: *Stack, value: u256) !void {
        if (self.data.items.len >= MAX_STACK_SIZE) {
            return error.StackOverflow;
        }
        try self.data.append(self.allocator, value);
    }

    pub fn pop(self: *Stack) !u256 {
        if (self.data.items.len == 0) {
            return error.StackUnderflow;
        }
        return self.data.pop() orelse return error.StackUnderflow;
    }

    /// Peek at top of stack without removing
    pub fn peek(self: *const Stack) !*u256 {
        if (self.data.items.len == 0) {
            return error.StackUnderflow;
        }
        return &self.data.items[self.data.items.len - 1];
    }

    /// Get n-th item from top (0 = top)
    pub fn back(self: *Stack, n: usize) !*u256 {
        if (n >= self.data.items.len) {
            return error.StackUnderflow;
        }
        return &self.data.items[self.data.items.len - n - 1];
    }

    /// Duplicate n-th item from top onto stack
    pub fn dup(self: *Stack, n: usize) !void {
        if (n == 0 or n > 16) {
            return error.InvalidStackOperation;
        }
        if (n > self.data.items.len) {
            return error.StackUnderflow;
        }
        if (self.data.items.len >= MAX_STACK_SIZE) {
            return error.StackOverflow;
        }

        const value = self.data.items[self.data.items.len - n];
        try self.data.append(self.allocator, value);
    }

    /// Swap top with n-th item (1-indexed: swap1 swaps top two)
    pub fn swap(self: *Stack, n: usize) !void {
        if (n == 0 or n > 16) {
            return error.InvalidStackOperation;
        }
        if (n >= self.data.items.len) {
            return error.StackUnderflow;
        }

        const top_idx = self.data.items.len - 1;
        const swap_idx = self.data.items.len - n - 1;
        std.mem.swap(u256, &self.data.items[top_idx], &self.data.items[swap_idx]);
    }

    // Convenience methods for specific swap operations (matching Erigon)
    pub fn swap1(self: *Stack) !void {
        try self.swap(1);
    }
    pub fn swap2(self: *Stack) !void {
        try self.swap(2);
    }
    pub fn swap3(self: *Stack) !void {
        try self.swap(3);
    }
    pub fn swap4(self: *Stack) !void {
        try self.swap(4);
    }
    pub fn swap5(self: *Stack) !void {
        try self.swap(5);
    }
    pub fn swap6(self: *Stack) !void {
        try self.swap(6);
    }
    pub fn swap7(self: *Stack) !void {
        try self.swap(7);
    }
    pub fn swap8(self: *Stack) !void {
        try self.swap(8);
    }
    pub fn swap9(self: *Stack) !void {
        try self.swap(9);
    }
    pub fn swap10(self: *Stack) !void {
        try self.swap(10);
    }
    pub fn swap11(self: *Stack) !void {
        try self.swap(11);
    }
    pub fn swap12(self: *Stack) !void {
        try self.swap(12);
    }
    pub fn swap13(self: *Stack) !void {
        try self.swap(13);
    }
    pub fn swap14(self: *Stack) !void {
        try self.swap(14);
    }
    pub fn swap15(self: *Stack) !void {
        try self.swap(15);
    }
    pub fn swap16(self: *Stack) !void {
        try self.swap(16);
    }

    /// Check if stack has at least n items
    pub fn require(self: *const Stack, n: usize) !void {
        if (self.data.items.len < n) {
            return error.StackUnderflow;
        }
    }

    /// Check if stack has room for n more items
    pub fn requireCapacity(self: *const Stack, n: usize) !void {
        if (self.data.items.len + n > MAX_STACK_SIZE) {
            return error.StackOverflow;
        }
    }
};

test "stack basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    // Test push and pop
    try stack.push(42);
    try stack.push(100);
    try testing.expectEqual(@as(usize, 2), stack.len());

    const val = try stack.pop();
    try testing.expectEqual(@as(u256, 100), val);
    try testing.expectEqual(@as(usize, 1), stack.len());

    // Test peek
    const top = try stack.peek();
    try testing.expectEqual(@as(u256, 42), top.*);
    try testing.expectEqual(@as(usize, 1), stack.len()); // Should not change length
}

test "stack dup and swap" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    try stack.push(10);
    try stack.push(20);
    try stack.push(30);

    // Test dup
    try stack.dup(1); // Duplicate top (30)
    try testing.expectEqual(@as(usize, 4), stack.len());
    const top = try stack.pop();
    try testing.expectEqual(@as(u256, 30), top);

    // Test swap
    try stack.swap1(); // Swap top two: [10, 20, 30] (was [10, 30, 20])
    const val1 = try stack.pop();
    try testing.expectEqual(@as(u256, 20), val1);
    const val2 = try stack.pop();
    try testing.expectEqual(@as(u256, 30), val2);
}

test "stack overflow and underflow" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    // Test underflow
    try testing.expectError(error.StackUnderflow, stack.pop());

    // Test overflow (would take too long to actually fill, so just test limit check)
    for (0..MAX_STACK_SIZE) |i| {
        try stack.push(@intCast(i));
    }
    try testing.expectError(error.StackOverflow, stack.push(9999));
}

test "stack back operation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    try stack.push(10);
    try stack.push(20);
    try stack.push(30);
    try stack.push(40);

    // back(0) should be top (40)
    const val0 = try stack.back(0);
    try testing.expectEqual(@as(u256, 40), val0.*);

    // back(2) should be third from top (20)
    const val2 = try stack.back(2);
    try testing.expectEqual(@as(u256, 20), val2.*);
}

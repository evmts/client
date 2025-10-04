//! Byte utility functions
//! Port of erigon-lib/common/bytes.go

const std = @import("std");

/// Convert byte count to human readable string (KB, MB, GB, etc.)
pub fn byteCount(b: u64) ![]const u8 {
    const allocator = std.heap.page_allocator;
    const unit: u64 = 1024;

    if (b < unit) {
        return try std.fmt.allocPrint(allocator, "{d}B", .{b});
    }

    const result = mbToGb(b);
    const units = "KMGTPE";
    return try std.fmt.allocPrint(allocator, "{d:.1}{c}B", .{ result.value, units[result.exp] });
}

pub const MbToGbResult = struct {
    value: f64,
    exp: usize,
};

pub fn mbToGb(b: u64) MbToGbResult {
    const unit: u64 = 1024;
    if (b < unit) {
        return .{ .value = @as(f64, @floatFromInt(b)), .exp = 0 };
    }

    var div: u64 = unit;
    var exp: usize = 0;
    var n = b / unit;

    while (n >= unit) {
        div *= unit;
        exp += 1;
        n /= unit;
    }

    return .{
        .value = @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(div)),
        .exp = exp,
    };
}

/// Append multiple byte slices together
pub fn append(allocator: std.mem.Allocator, data: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (data) |d| {
        total_len += d.len;
    }

    var result = try allocator.alloc(u8, total_len);
    var offset: usize = 0;

    for (data) |d| {
        @memcpy(result[offset..][0..d.len], d);
        offset += d.len;
    }

    return result;
}

/// Ensure buffer has enough size, reallocating if necessary
pub fn ensureEnoughSize(allocator: std.mem.Allocator, in: []u8, size: usize) ![]u8 {
    if (in.len >= size) {
        return in[0..size];
    }

    var new_buf = try allocator.alloc(u8, size);
    @memcpy(new_buf[0..in.len], in);
    return new_buf;
}

/// Convert bit length to byte length (rounded up)
pub fn bitLenToByteLen(bit_len: usize) usize {
    return (bit_len + 7) / 8;
}

/// Shorten byte slice to max length
pub fn shorten(k: []const u8, l: usize) []const u8 {
    if (k.len > l) {
        return k[0..l];
    }
    return k;
}

/// Convert bytes to u64 (big endian, up to 8 bytes)
pub fn bytesToUint64(buf: []const u8) u64 {
    var x: u64 = 0;
    for (buf, 0..) |b, i| {
        x = (x << 8) + @as(u64, b);
        if (i == 7) break;
    }
    return x;
}

/// Right-pad bytes with zeros up to length l
pub fn rightPadBytes(allocator: std.mem.Allocator, slice: []const u8, l: usize) ![]u8 {
    if (l <= slice.len) {
        return try allocator.dupe(u8, slice);
    }

    var padded = try allocator.alloc(u8, l);
    @memset(padded, 0);
    @memcpy(padded[0..slice.len], slice);
    return padded;
}

/// Left-pad bytes with zeros up to length l
pub fn leftPadBytes(allocator: std.mem.Allocator, slice: []const u8, l: usize) ![]u8 {
    if (l <= slice.len) {
        return try allocator.dupe(u8, slice);
    }

    var padded = try allocator.alloc(u8, l);
    @memset(padded, 0);
    @memcpy(padded[l - slice.len ..], slice);
    return padded;
}

/// Trim leading zeros from byte slice
pub fn trimLeftZeroes(s: []const u8) []const u8 {
    var idx: usize = 0;
    while (idx < s.len and s[idx] == 0) {
        idx += 1;
    }
    return s[idx..];
}

/// Trim trailing zeros from byte slice
pub fn trimRightZeroes(s: []const u8) []const u8 {
    var idx = s.len;
    while (idx > 0 and s[idx - 1] == 0) {
        idx -= 1;
    }
    return s[0..idx];
}

/// Copy bytes (wrapper for consistency)
pub fn copy(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    return try allocator.dupe(u8, data);
}

// Tests
test "mbToGb" {
    const testing = std.testing;

    const result = mbToGb(1024);
    try testing.expectEqual(@as(usize, 0), result.exp);
    try testing.expectApproxEqRel(1024.0, result.value, 0.01);

    const result2 = mbToGb(1024 * 1024);
    try testing.expectEqual(@as(usize, 1), result2.exp);
    try testing.expectApproxEqRel(1024.0, result2.value, 0.01);
}

test "append" {
    const testing = std.testing;

    const data = [_][]const u8{ "hello", " ", "world" };
    const result = try append(testing.allocator, &data);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("hello world", result);
}

test "bitLenToByteLen" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 0), bitLenToByteLen(0));
    try testing.expectEqual(@as(usize, 1), bitLenToByteLen(1));
    try testing.expectEqual(@as(usize, 1), bitLenToByteLen(7));
    try testing.expectEqual(@as(usize, 1), bitLenToByteLen(8));
    try testing.expectEqual(@as(usize, 2), bitLenToByteLen(9));
}

test "bytesToUint64" {
    const testing = std.testing;

    const bytes1 = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try testing.expectEqual(@as(u64, 0x01020304), bytesToUint64(&bytes1));

    const bytes2 = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), bytesToUint64(&bytes2));
}

test "leftPadBytes" {
    const testing = std.testing;

    const input = [_]u8{ 0xAB, 0xCD };
    const result = try leftPadBytes(testing.allocator, &input, 4);
    defer testing.allocator.free(result);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0xAB, 0xCD }, result);
}

test "rightPadBytes" {
    const testing = std.testing;

    const input = [_]u8{ 0xAB, 0xCD };
    const result = try rightPadBytes(testing.allocator, &input, 4);
    defer testing.allocator.free(result);

    try testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xCD, 0x00, 0x00 }, result);
}

test "trimLeftZeroes" {
    const testing = std.testing;

    const input1 = [_]u8{ 0x00, 0x00, 0xAB, 0xCD };
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xCD }, trimLeftZeroes(&input1));

    const input2 = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try testing.expectEqualSlices(u8, &[_]u8{}, trimLeftZeroes(&input2));

    const input3 = [_]u8{ 0xAB, 0xCD };
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xCD }, trimLeftZeroes(&input3));
}

test "trimRightZeroes" {
    const testing = std.testing;

    const input1 = [_]u8{ 0xAB, 0xCD, 0x00, 0x00 };
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xCD }, trimRightZeroes(&input1));

    const input2 = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try testing.expectEqualSlices(u8, &[_]u8{}, trimRightZeroes(&input2));
}

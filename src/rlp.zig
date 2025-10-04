//! RLP (Recursive Length Prefix) encoding/decoding
//! Based on Ethereum's RLP specification: https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/

const std = @import("std");

pub const RlpError = error{
    InvalidRlpData,
    UnexpectedEndOfData,
    InvalidLength,
    ListExpected,
    StringExpected,
    IntegerOverflow,
    NegativeInteger,
    OutOfMemory,
    CanonicalIntError,
    CanonicalSizeError,
    ElemTooLarge,
    ValueTooLarge,
    MoreThanOneValue,
};

// RLP encoding constants
pub const EMPTY_STRING_CODE: u8 = 0x80;
pub const EMPTY_LIST_CODE: u8 = 0xC0;

/// RLP item types
pub const ItemType = enum {
    string,
    list,
};

/// Encode a byte slice to RLP
pub fn encodeBytes(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    try encodeBytesTo(&list, data);
    return list.toOwnedSlice();
}

/// Encode bytes directly to an ArrayList
pub fn encodeBytesTo(out: *std.ArrayList(u8), data: []const u8) !void {
    if (data.len == 0) {
        try out.append(EMPTY_STRING_CODE);
        return;
    }

    if (data.len == 1 and data[0] < EMPTY_STRING_CODE) {
        // Single byte < 0x80 encodes as itself
        try out.append(data[0]);
        return;
    }

    if (data.len <= 55) {
        // Short string: 0x80 + len, then data
        try out.append(EMPTY_STRING_CODE + @as(u8, @intCast(data.len)));
        try out.appendSlice(data);
        return;
    }

    // Long string: 0xb7 + len_of_len, then len, then data
    const len_bytes = encodeLengthBytes(data.len);
    try out.append(0xb7 + @as(u8, @intCast(len_bytes.len)));
    try out.appendSlice(len_bytes[0..len_bytes.len]);
    try out.appendSlice(data);
}

/// Encode an integer to RLP
pub fn encodeInt(allocator: std.mem.Allocator, value: u64) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    try encodeIntTo(&list, value);
    return list.toOwnedSlice();
}

pub fn encodeIntTo(out: *std.ArrayList(u8), value: u64) !void {
    if (value == 0) {
        try out.append(EMPTY_STRING_CODE);
        return;
    }

    // Encode as big-endian, removing leading zeros
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);

    // Find first non-zero byte
    var start: usize = 0;
    while (start < 8 and bytes[start] == 0) : (start += 1) {}

    try encodeBytesTo(out, bytes[start..]);
}

/// Encode a U256 to RLP
pub fn encodeU256(allocator: std.mem.Allocator, value: u256) ![]u8 {
    if (value == 0) {
        return try allocator.dupe(u8, &[_]u8{EMPTY_STRING_CODE});
    }

    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, value, .big);

    // Find first non-zero byte
    var start: usize = 0;
    while (start < 32 and bytes[start] == 0) : (start += 1) {}

    return encodeBytes(allocator, bytes[start..]);
}

/// Encode a list of items
pub fn encodeList(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    // First, encode all items and calculate total length
    var total_len: usize = 0;
    for (items) |item| {
        total_len += item.len;
    }

    if (total_len <= 55) {
        // Short list: 0xc0 + len, then concatenated items
        try list.append(EMPTY_LIST_CODE + @as(u8, @intCast(total_len)));
        for (items) |item| {
            try list.appendSlice(item);
        }
    } else {
        // Long list: 0xf7 + len_of_len, then len, then concatenated items
        const len_bytes = encodeLengthBytes(total_len);
        try list.append(0xf7 + @as(u8, @intCast(len_bytes.len)));
        try list.appendSlice(len_bytes[0..len_bytes.len]);
        for (items) |item| {
            try list.appendSlice(item);
        }
    }

    return list.toOwnedSlice();
}

/// Helper: encode length as big-endian bytes
fn encodeLengthBytes(length: usize) [8]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, length, .big);
    return bytes;
}

/// Decode RLP data
pub const Decoder = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Decoder {
        return .{
            .data = data,
            .pos = 0,
        };
    }

    /// Peek at the next item type without consuming
    pub fn peekType(self: *const Decoder) !ItemType {
        if (self.pos >= self.data.len) return error.UnexpectedEndOfData;

        const prefix = self.data[self.pos];
        if (prefix < EMPTY_STRING_CODE) {
            return .string;
        } else if (prefix >= EMPTY_LIST_CODE) {
            return .list;
        } else {
            return .string;
        }
    }

    /// Decode next bytes item
    pub fn decodeBytes(self: *Decoder, allocator: std.mem.Allocator) ![]u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEndOfData;

        const prefix = self.data[self.pos];

        // Single byte < 0x80
        if (prefix < EMPTY_STRING_CODE) {
            defer self.pos += 1;
            return try allocator.dupe(u8, self.data[self.pos .. self.pos + 1]);
        }

        // Empty string
        if (prefix == EMPTY_STRING_CODE) {
            self.pos += 1;
            return try allocator.alloc(u8, 0);
        }

        // Short string (0-55 bytes)
        if (prefix <= 0xb7) {
            const len = prefix - EMPTY_STRING_CODE;
            if (self.pos + 1 + len > self.data.len) return error.UnexpectedEndOfData;

            const result = try allocator.dupe(u8, self.data[self.pos + 1 .. self.pos + 1 + len]);
            self.pos += 1 + len;
            return result;
        }

        // Long string (> 55 bytes)
        if (prefix <= 0xbf) {
            const len_of_len = prefix - 0xb7;
            if (self.pos + 1 + len_of_len > self.data.len) return error.UnexpectedEndOfData;

            const len = try decodeLengthBytes(self.data[self.pos + 1 .. self.pos + 1 + len_of_len]);
            if (self.pos + 1 + len_of_len + len > self.data.len) return error.UnexpectedEndOfData;

            const result = try allocator.dupe(u8, self.data[self.pos + 1 + len_of_len .. self.pos + 1 + len_of_len + len]);
            self.pos += 1 + len_of_len + len;
            return result;
        }

        return error.ListExpected;
    }

    /// Decode next integer
    pub fn decodeInt(self: *Decoder) !u64 {
        const bytes = try self.decodeBytesView();
        if (bytes.len == 0) return 0;
        if (bytes.len > 8) return error.IntegerOverflow;

        var result: u64 = 0;
        for (bytes) |byte| {
            result = (result << 8) | byte;
        }
        return result;
    }

    /// Decode bytes without allocating (view into original data)
    pub fn decodeBytesView(self: *Decoder) ![]const u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEndOfData;

        const prefix = self.data[self.pos];

        // Single byte < 0x80
        if (prefix < EMPTY_STRING_CODE) {
            defer self.pos += 1;
            return self.data[self.pos .. self.pos + 1];
        }

        // Empty string
        if (prefix == EMPTY_STRING_CODE) {
            self.pos += 1;
            return self.data[0..0];
        }

        // Short string
        if (prefix <= 0xb7) {
            const len = prefix - EMPTY_STRING_CODE;
            if (self.pos + 1 + len > self.data.len) return error.UnexpectedEndOfData;

            const result = self.data[self.pos + 1 .. self.pos + 1 + len];
            self.pos += 1 + len;
            return result;
        }

        // Long string
        if (prefix <= 0xbf) {
            const len_of_len = prefix - 0xb7;
            if (self.pos + 1 + len_of_len > self.data.len) return error.UnexpectedEndOfData;

            const len = try decodeLengthBytes(self.data[self.pos + 1 .. self.pos + 1 + len_of_len]);
            if (self.pos + 1 + len_of_len + len > self.data.len) return error.UnexpectedEndOfData;

            const result = self.data[self.pos + 1 + len_of_len .. self.pos + 1 + len_of_len + len];
            self.pos += 1 + len_of_len + len;
            return result;
        }

        return error.ListExpected;
    }

    /// Enter a list and return a decoder for its contents
    pub fn enterList(self: *Decoder) !Decoder {
        if (self.pos >= self.data.len) return error.UnexpectedEndOfData;

        const prefix = self.data[self.pos];

        // Empty list
        if (prefix == EMPTY_LIST_CODE) {
            self.pos += 1;
            return Decoder.init(self.data[0..0]);
        }

        // Short list
        if (prefix > EMPTY_LIST_CODE and prefix <= 0xf7) {
            const len = prefix - EMPTY_LIST_CODE;
            if (self.pos + 1 + len > self.data.len) return error.UnexpectedEndOfData;

            const list_data = self.data[self.pos + 1 .. self.pos + 1 + len];
            self.pos += 1 + len;
            return Decoder.init(list_data);
        }

        // Long list
        if (prefix > 0xf7) {
            const len_of_len = prefix - 0xf7;
            if (self.pos + 1 + len_of_len > self.data.len) return error.UnexpectedEndOfData;

            const len = try decodeLengthBytes(self.data[self.pos + 1 .. self.pos + 1 + len_of_len]);
            if (self.pos + 1 + len_of_len + len > self.data.len) return error.UnexpectedEndOfData;

            const list_data = self.data[self.pos + 1 + len_of_len .. self.pos + 1 + len_of_len + len];
            self.pos += 1 + len_of_len + len;
            return Decoder.init(list_data);
        }

        return error.StringExpected;
    }

    pub fn isEmpty(self: *const Decoder) bool {
        return self.pos >= self.data.len;
    }

    /// Validate canonical encoding (no leading zeros in integers)
    pub fn validateCanonicalInt(bytes: []const u8) !void {
        if (bytes.len > 1 and bytes[0] == 0) {
            return error.CanonicalIntError;
        }
    }

    /// Check if more data exists after current position
    pub fn hasMoreData(self: *const Decoder) bool {
        return self.pos < self.data.len;
    }

    /// Get remaining bytes
    pub fn remaining(self: *const Decoder) []const u8 {
        if (self.pos >= self.data.len) return &[_]u8{};
        return self.data[self.pos..];
    }
};

fn decodeLengthBytes(bytes: []const u8) !usize {
    if (bytes.len == 0 or bytes.len > 8) return error.InvalidLength;

    var result: usize = 0;
    for (bytes) |byte| {
        result = (result << 8) | byte;
    }
    return result;
}

/// RLP Encoder with buffer pooling (similar to Erigon's encBuffer)
pub const Encoder = struct {
    buffer: std.ArrayList(u8),
    list_stack: std.ArrayList(usize), // Track list start positions

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{
            .buffer = std.ArrayList(u8).init(allocator),
            .list_stack = std.ArrayList(usize).init(allocator),
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.buffer.deinit();
        self.list_stack.deinit();
    }

    pub fn reset(self: *Encoder) void {
        self.buffer.clearRetainingCapacity();
        self.list_stack.clearRetainingCapacity();
    }

    /// Start encoding a list
    pub fn startList(self: *Encoder) !void {
        try self.list_stack.append(self.buffer.items.len);
    }

    /// Finish encoding current list
    pub fn endList(self: *Encoder) !void {
        if (self.list_stack.items.len == 0) return error.InvalidRlpData;

        const list_start = self.list_stack.pop();
        const payload_len = self.buffer.items.len - list_start;

        // Encode list header
        var header: [9]u8 = undefined;
        const header_len = encodeListHeader(&header, payload_len);

        // Insert header at list start
        try self.buffer.insertSlice(list_start, header[0..header_len]);
    }

    /// Write bytes to encoder
    pub fn writeBytes(self: *Encoder, data: []const u8) !void {
        try encodeBytesTo(&self.buffer, data);
    }

    /// Write integer to encoder
    pub fn writeInt(self: *Encoder, value: u64) !void {
        try encodeIntTo(&self.buffer, value);
    }

    /// Get encoded result
    pub fn toOwnedSlice(self: *Encoder) ![]u8 {
        return self.buffer.toOwnedSlice();
    }

    pub fn toSlice(self: *const Encoder) []const u8 {
        return self.buffer.items;
    }

    fn encodeListHeader(buf: []u8, payload_len: usize) usize {
        if (payload_len <= 55) {
            buf[0] = EMPTY_LIST_CODE + @as(u8, @intCast(payload_len));
            return 1;
        }

        // Encode length of length
        const len_bytes = encodeLengthBytes(payload_len);
        var len_of_len: usize = 0;
        for (len_bytes) |b| {
            if (b != 0 or len_of_len > 0) {
                len_of_len += 1;
            }
        }

        buf[0] = 0xf7 + @as(u8, @intCast(len_of_len));
        @memcpy(buf[1..1+len_of_len], len_bytes[8-len_of_len..8]);
        return 1 + len_of_len;
    }
};

// Tests
test "encode single byte" {
    const encoded = try encodeBytes(std.testing.allocator, &[_]u8{0x00});
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, encoded);
}

test "encode short string" {
    const encoded = try encodeBytes(std.testing.allocator, "dog");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x83, 'd', 'o', 'g' }, encoded);
}

test "encode empty string" {
    const encoded = try encodeBytes(std.testing.allocator, "");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x80}, encoded);
}

test "encode integer" {
    const encoded = try encodeInt(std.testing.allocator, 0);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x80}, encoded);

    const encoded2 = try encodeInt(std.testing.allocator, 15);
    defer std.testing.allocator.free(encoded2);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x0f}, encoded2);

    const encoded3 = try encodeInt(std.testing.allocator, 1024);
    defer std.testing.allocator.free(encoded3);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x04, 0x00 }, encoded3);
}

test "encode list" {
    const item1 = try encodeBytes(std.testing.allocator, "cat");
    defer std.testing.allocator.free(item1);

    const item2 = try encodeBytes(std.testing.allocator, "dog");
    defer std.testing.allocator.free(item2);

    const items = [_][]const u8{ item1, item2 };
    const encoded = try encodeList(std.testing.allocator, &items);
    defer std.testing.allocator.free(encoded);

    // List of ["cat", "dog"] = 0xc8 (length 8) + 0x83 "cat" + 0x83 "dog"
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xc8, 0x83, 'c', 'a', 't', 0x83, 'd', 'o', 'g' }, encoded);
}

test "decode single byte" {
    var decoder = Decoder.init(&[_]u8{0x0f});
    const bytes = try decoder.decodeBytesView();
    try std.testing.expectEqualSlices(u8, &[_]u8{0x0f}, bytes);
}

test "decode short string" {
    var decoder = Decoder.init(&[_]u8{ 0x83, 'd', 'o', 'g' });
    const bytes = try decoder.decodeBytesView();
    try std.testing.expectEqualSlices(u8, "dog", bytes);
}

test "decode list" {
    var decoder = Decoder.init(&[_]u8{ 0xc8, 0x83, 'c', 'a', 't', 0x83, 'd', 'o', 'g' });
    var list_decoder = try decoder.enterList();

    const item1 = try list_decoder.decodeBytesView();
    try std.testing.expectEqualSlices(u8, "cat", item1);

    const item2 = try list_decoder.decodeBytesView();
    try std.testing.expectEqualSlices(u8, "dog", item2);

    try std.testing.expect(list_decoder.isEmpty());
}

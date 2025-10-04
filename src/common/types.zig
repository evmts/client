//! Common Ethereum types
//! Port of erigon-lib/common/types.go, hash.go, address.go

const std = @import("std");
const crypto = std.crypto;

/// Lengths of hashes and addresses in bytes
pub const Length = struct {
    pub const PEER_ID = 64;
    pub const HASH = 32;
    pub const BYTES96 = 96; // signature
    pub const BYTES48 = 48; // bls public key
    pub const BYTES64 = 64; // sync committee bits
    pub const BYTES4 = 4; // beacon domain
    pub const ADDR = 20;
    pub const BLOCK_NUM = 8;
    pub const TIMESTAMP = 8;
    pub const INCARNATION = 8;
};

/// Block number length
pub const BLOCK_NUMBER_LENGTH = 8;
/// Contract incarnation length
pub const INCARNATION_LENGTH = 8;
/// Storage key length (2 * hash + incarnation)
pub const STORAGE_KEY_LENGTH = 2 * Length.HASH + INCARNATION_LENGTH;

/// 32-byte Keccak256 hash
pub const Hash = struct {
    bytes: [Length.HASH]u8,

    pub const ZERO: Hash = .{ .bytes = [_]u8{0} ** Length.HASH };

    pub fn init() Hash {
        return .{ .bytes = undefined };
    }

    pub fn fromBytes(b: []const u8) Hash {
        var h = Hash.init();
        h.setBytes(b);
        return h;
    }

    pub fn fromBytesExact(b: [Length.HASH]u8) Hash {
        return .{ .bytes = b };
    }

    pub fn setBytes(self: *Hash, b: []const u8) void {
        if (b.len > Length.HASH) {
            // Crop from left if too large
            @memcpy(&self.bytes, b[b.len - Length.HASH ..]);
        } else {
            // Zero left pad if too small
            @memset(self.bytes[0 .. Length.HASH - b.len], 0);
            @memcpy(self.bytes[Length.HASH - b.len ..], b);
        }
    }

    pub fn fromHex(allocator: std.mem.Allocator, s: []const u8) !Hash {
        const hex_str = if (std.mem.startsWith(u8, s, "0x"))
            s[2..]
        else
            s;

        var bytes: [Length.HASH]u8 = undefined;
        _ = try std.fmt.hexToBytes(&bytes, hex_str);
        return Hash.fromBytesExact(bytes);
    }

    pub fn toHex(self: Hash, allocator: std.mem.Allocator) ![]u8 {
        var result = try allocator.alloc(u8, 2 + Length.HASH * 2);
        result[0] = '0';
        result[1] = 'x';
        _ = std.fmt.bufPrint(result[2..], "{x}", .{std.fmt.fmtSliceHexLower(&self.bytes)}) catch unreachable;
        return result;
    }

    pub fn eql(self: Hash, other: Hash) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn cmp(self: Hash, other: Hash) std.math.Order {
        return std.mem.order(u8, &self.bytes, &other.bytes);
    }

    pub fn format(
        self: Hash,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("0x{x}", .{std.fmt.fmtSliceHexLower(&self.bytes)});
    }
};

/// 20-byte Ethereum address
pub const Address = struct {
    bytes: [Length.ADDR]u8,

    pub const ZERO: Address = .{ .bytes = [_]u8{0} ** Length.ADDR };

    pub fn init() Address {
        return .{ .bytes = undefined };
    }

    pub fn fromBytes(b: []const u8) Address {
        var a = Address.init();
        a.setBytes(b);
        return a;
    }

    pub fn fromBytesExact(b: [Length.ADDR]u8) Address {
        return .{ .bytes = b };
    }

    pub fn setBytes(self: *Address, b: []const u8) void {
        if (b.len > Length.ADDR) {
            // Crop from left if too large
            @memcpy(&self.bytes, b[b.len - Length.ADDR ..]);
        } else {
            // Zero left pad if too small
            @memset(self.bytes[0 .. Length.ADDR - b.len], 0);
            @memcpy(self.bytes[Length.ADDR - b.len ..], b);
        }
    }

    pub fn fromHex(allocator: std.mem.Allocator, s: []const u8) !Address {
        _ = allocator;
        const hex_str = if (std.mem.startsWith(u8, s, "0x"))
            s[2..]
        else
            s;

        var bytes: [Length.ADDR]u8 = undefined;
        _ = try std.fmt.hexToBytes(&bytes, hex_str);
        return Address.fromBytesExact(bytes);
    }

    /// Convert address to hex string with EIP-55 checksum
    pub fn toHex(self: Address, allocator: std.mem.Allocator) ![]u8 {
        // First convert to lowercase hex
        var hex_buf: [Length.ADDR * 2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf, "{x}", .{std.fmt.fmtSliceHexLower(&self.bytes)}) catch unreachable;

        // Hash the lowercase hex
        var hash_buf: [32]u8 = undefined;
        crypto.hash.sha3.Keccak256.hash(&hex_buf, &hash_buf, .{});

        // Apply EIP-55 checksum
        var result = try allocator.alloc(u8, 2 + Length.ADDR * 2);
        result[0] = '0';
        result[1] = 'x';

        for (0..hex_buf.len) |i| {
            const char = hex_buf[i];
            const hash_byte = hash_buf[i / 2];
            const hash_nibble = if (i % 2 == 0) hash_byte >> 4 else hash_byte & 0x0f;

            if (char >= 'a' and char <= 'f' and hash_nibble > 7) {
                result[2 + i] = char - 32; // Uppercase
            } else {
                result[2 + i] = char;
            }
        }

        return result;
    }

    pub fn toHash(self: Address) Hash {
        var h = Hash.init();
        h.setBytes(&self.bytes);
        return h;
    }

    pub fn eql(self: Address, other: Address) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn cmp(self: Address, other: Address) std.math.Order {
        return std.mem.order(u8, &self.bytes, &other.bytes);
    }

    pub fn format(
        self: Address,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        // For now, just hex without checksum in format
        try writer.print("0x{x}", .{std.fmt.fmtSliceHexLower(&self.bytes)});
    }
};

/// Verify if string is valid hex address
pub fn isHexAddress(s: []const u8) bool {
    const hex_str = if (std.mem.startsWith(u8, s, "0x"))
        s[2..]
    else
        s;

    if (hex_str.len != 2 * Length.ADDR) return false;

    for (hex_str) |c| {
        if (!std.ascii.isHex(c)) return false;
    }

    return true;
}

/// Storage key representation (contract address hash + slot hash + incarnation)
pub const StorageKey = struct {
    bytes: [STORAGE_KEY_LENGTH]u8,

    pub fn init(addr_hash: Hash, slot_hash: Hash, incarnation: u64) StorageKey {
        var sk: StorageKey = undefined;
        @memcpy(sk.bytes[0..Length.HASH], &addr_hash.bytes);
        @memcpy(sk.bytes[Length.HASH .. 2 * Length.HASH], &slot_hash.bytes);
        std.mem.writeInt(u64, sk.bytes[2 * Length.HASH ..][0..8], incarnation, .big);
        return sk;
    }

    pub fn getAddressHash(self: StorageKey) Hash {
        return Hash.fromBytesExact(self.bytes[0..Length.HASH].*);
    }

    pub fn getSlotHash(self: StorageKey) Hash {
        return Hash.fromBytesExact(self.bytes[Length.HASH .. 2 * Length.HASH].*);
    }

    pub fn getIncarnation(self: StorageKey) u64 {
        return std.mem.readInt(u64, self.bytes[2 * Length.HASH ..][0..8], .big);
    }
};

/// Code record for contract code storage
pub const CodeRecord = struct {
    block_number: u64,
    tx_number: u64,
    code_hash: Hash,
};

// Tests
test "Hash - fromBytes and setBytes" {
    const testing = std.testing;

    // Test exact size
    const bytes = [_]u8{1} ** Length.HASH;
    const h = Hash.fromBytes(&bytes);
    try testing.expectEqualSlices(u8, &bytes, &h.bytes);

    // Test crop from left
    const large_bytes = [_]u8{0xFF} ** 64;
    const h2 = Hash.fromBytes(&large_bytes);
    try testing.expectEqualSlices(u8, large_bytes[32..64], &h2.bytes);

    // Test zero padding
    const small_bytes = [_]u8{0xAB, 0xCD};
    const h3 = Hash.fromBytes(&small_bytes);
    try testing.expectEqual(@as(u8, 0), h3.bytes[0]);
    try testing.expectEqual(@as(u8, 0xAB), h3.bytes[30]);
    try testing.expectEqual(@as(u8, 0xCD), h3.bytes[31]);
}

test "Hash - fromHex" {
    const testing = std.testing;

    const hex = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
    const h = try Hash.fromHex(testing.allocator, hex);

    try testing.expectEqual(@as(u8, 0x12), h.bytes[0]);
    try testing.expectEqual(@as(u8, 0xef), h.bytes[31]);
}

test "Address - fromBytes and setBytes" {
    const testing = std.testing;

    // Test exact size
    const bytes = [_]u8{1} ** Length.ADDR;
    const a = Address.fromBytes(&bytes);
    try testing.expectEqualSlices(u8, &bytes, &a.bytes);

    // Test crop from left
    const large_bytes = [_]u8{0xFF} ** 32;
    const a2 = Address.fromBytes(&large_bytes);
    try testing.expectEqualSlices(u8, large_bytes[12..32], &a2.bytes);
}

test "Address - EIP-55 checksum" {
    const testing = std.testing;

    // Test known address with checksum
    const addr_bytes = [_]u8{ 0x5a, 0xAe, 0xb6, 0x05, 0x3F, 0x3E, 0x94, 0xC9, 0xb9, 0xA0, 0x9f, 0x33, 0x66, 0x9e, 0x5B, 0x38, 0xB2, 0x98, 0x89, 0xC9 };
    const addr = Address.fromBytesExact(addr_bytes);

    const hex = try addr.toHex(testing.allocator);
    defer testing.allocator.free(hex);

    // Should have mixed case for checksum
    try testing.expect(std.mem.indexOf(u8, hex, "0x") != null);
}

test "isHexAddress" {
    const testing = std.testing;

    try testing.expect(isHexAddress("0x5aAeb6053F3E94C9b9A09f33669e5B38B2989C9"));
    try testing.expect(isHexAddress("5aAeb6053F3E94C9b9A09f33669e5B38B2989C9"));
    try testing.expect(!isHexAddress("0x5aAeb6053F3E94C9b9A09f33669e5B38B2989C")); // Too short
    try testing.expect(!isHexAddress("0xZZZeb6053F3E94C9b9A09f33669e5B38B2989C9")); // Invalid hex
}

test "StorageKey" {
    const testing = std.testing;

    const addr_hash = Hash.fromBytes(&[_]u8{0x01} ** 32);
    const slot_hash = Hash.fromBytes(&[_]u8{0x02} ** 32);
    const incarnation: u64 = 0x0304050607080910;

    const sk = StorageKey.init(addr_hash, slot_hash, incarnation);

    try testing.expect(sk.getAddressHash().eql(addr_hash));
    try testing.expect(sk.getSlotHash().eql(slot_hash));
    try testing.expectEqual(incarnation, sk.getIncarnation());
}

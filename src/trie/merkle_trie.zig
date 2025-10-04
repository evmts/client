const std = @import("std");
const Allocator = std.mem.Allocator;
const trie = @import("trie.zig");
const hash_builder = @import("hash_builder.zig");

const TrieNode = trie.TrieNode;
const HashValue = trie.HashValue;
const HashBuilder = hash_builder.HashBuilder;
const TrieError = trie.TrieError;

/// The main Merkle Patricia Trie implementation exposed to users
pub const MerkleTrie = struct {
    allocator: Allocator,
    builder: HashBuilder,

    pub fn init(allocator: Allocator) MerkleTrie {
        return MerkleTrie{
            .allocator = allocator,
            .builder = HashBuilder.init(allocator),
        };
    }

    pub fn deinit(self: *MerkleTrie) void {
        self.builder.deinit();
    }

    /// Get a value from the trie
    pub fn get(self: *MerkleTrie, key: []const u8) !?[]const u8 {
        return try self.builder.get(key);
    }

    /// Put a key-value pair into the trie
    pub fn put(self: *MerkleTrie, key: []const u8, value: []const u8) !void {
        return try self.builder.insert(key, value);
    }

    /// Delete a key-value pair from the trie
    pub fn delete(self: *MerkleTrie, key: []const u8) !void {
        return try self.builder.delete(key);
    }

    /// Get the root hash of the trie
    pub fn root_hash(self: *const MerkleTrie) ?[32]u8 {
        return self.builder.root_hash;
    }

    // TODO: Implement proof generation and verification
    // Requires RLP decoder which is not yet ported

    /// Reset the trie to an empty state
    pub fn clear(self: *MerkleTrie) void {
        self.builder.reset();
    }

};

// Helper function - Duplicated from hash_builder.zig for modularity
fn bytes_to_hex_string(allocator: Allocator, bytes: []const u8) ![]u8 {
    const hex_chars = "0123456789abcdef";
    const hex = try allocator.alloc(u8, bytes.len * 2);
    errdefer allocator.free(hex);

    for (bytes, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    return hex;
}

// Tests

test "MerkleTrie - basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie_instance = MerkleTrie.init(allocator);
    defer trie_instance.deinit();

    // Trie should start empty
    try testing.expect(trie_instance.root_hash() == null);

    // Put a key-value pair
    try trie_instance.put(&[_]u8{ 1, 2, 3 }, "value1");

    // Root hash should now exist
    try testing.expect(trie_instance.root_hash() != null);

    // Get the value
    const value = try trie_instance.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value != null);
    try testing.expectEqualStrings("value1", value.?);

    // Delete the key
    try trie_instance.delete(&[_]u8{ 1, 2, 3 });

    // Value should be gone
    const deleted = try trie_instance.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(deleted == null);

    // Trie should be empty again
    try testing.expect(trie_instance.root_hash() == null);
}

test "MerkleTrie - multiple operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie_instance = MerkleTrie.init(allocator);
    defer trie_instance.deinit();

    // Insert multiple keys
    try trie_instance.put(&[_]u8{ 1, 2, 3 }, "value1");
    try trie_instance.put(&[_]u8{ 1, 2, 4 }, "value2");
    try trie_instance.put(&[_]u8{ 1, 3, 5 }, "value3");
    try trie_instance.put(&[_]u8{ 2, 3, 4 }, "value4");

    // Get all values
    const value1 = try trie_instance.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value1 != null);
    try testing.expectEqualStrings("value1", value1.?);

    const value2 = try trie_instance.get(&[_]u8{ 1, 2, 4 });
    try testing.expect(value2 != null);
    try testing.expectEqualStrings("value2", value2.?);

    const value3 = try trie_instance.get(&[_]u8{ 1, 3, 5 });
    try testing.expect(value3 != null);
    try testing.expectEqualStrings("value3", value3.?);

    const value4 = try trie_instance.get(&[_]u8{ 2, 3, 4 });
    try testing.expect(value4 != null);
    try testing.expectEqualStrings("value4", value4.?);

    // Update a value
    try trie_instance.put(&[_]u8{ 1, 2, 3 }, "updated_value");
    const updated = try trie_instance.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(updated != null);
    try testing.expectEqualStrings("updated_value", updated.?);

    // Delete values
    try trie_instance.delete(&[_]u8{ 1, 2, 3 });
    try trie_instance.delete(&[_]u8{ 1, 3, 5 });

    // Verify deletions
    const deleted1 = try trie_instance.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(deleted1 == null);

    const deleted2 = try trie_instance.get(&[_]u8{ 1, 3, 5 });
    try testing.expect(deleted2 == null);

    // But other values still exist
    const remaining1 = try trie_instance.get(&[_]u8{ 1, 2, 4 });
    try testing.expect(remaining1 != null);
    try testing.expectEqualStrings("value2", remaining1.?);

    const remaining2 = try trie_instance.get(&[_]u8{ 2, 3, 4 });
    try testing.expect(remaining2 != null);
    try testing.expectEqualStrings("value4", remaining2.?);

    // Clear the trie
    trie_instance.clear();
    try testing.expect(trie_instance.root_hash() == null);

    // All values should be gone
    const cleared1 = try trie_instance.get(&[_]u8{ 1, 2, 4 });
    try testing.expect(cleared1 == null);

    const cleared2 = try trie_instance.get(&[_]u8{ 2, 3, 4 });
    try testing.expect(cleared2 == null);
}

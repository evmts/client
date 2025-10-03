//! State commitment via Merkle Patricia Trie
//! Based on erigon/commitment package
//!
//! Erigon3 uses "flat state" but still needs tries for:
//! - State root calculation
//! - Witness generation
//! - Proof creation

const std = @import("std");
const primitives = @import("primitives");

/// Commitment mode
pub const Mode = enum {
    /// Full Merkle Patricia Trie (archive nodes)
    full_trie,
    /// Optimized commitment without storing full trie (full nodes)
    commitment_only,
    /// No commitment (testing)
    disabled,
};

/// Node types in Merkle Patricia Trie
pub const NodeType = enum {
    empty,
    branch,
    extension,
    leaf,
    hash,
};

/// Trie node
pub const TrieNode = union(NodeType) {
    empty: void,
    branch: BranchNode,
    extension: ExtensionNode,
    leaf: LeafNode,
    hash: [32]u8,

    pub const BranchNode = struct {
        children: [16]?*TrieNode,
        value: ?[]const u8,
    };

    pub const ExtensionNode = struct {
        path: []const u8,
        child: *TrieNode,
    };

    pub const LeafNode = struct {
        path: []const u8,
        value: []const u8,
    };
};

/// Commitment builder for state root calculation
pub const CommitmentBuilder = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    /// Cached nodes for incremental updates
    cache: std.StringHashMap(*TrieNode),

    pub fn init(allocator: std.mem.Allocator, mode: Mode) CommitmentBuilder {
        return .{
            .allocator = allocator,
            .mode = mode,
            .cache = std.StringHashMap(*TrieNode).init(allocator),
        };
    }

    pub fn deinit(self: *CommitmentBuilder) void {
        var iter = self.cache.valueIterator();
        while (iter.next()) |node_ptr| {
            self.freeNode(node_ptr.*);
        }
        self.cache.deinit();
    }

    fn freeNode(self: *CommitmentBuilder, node: *TrieNode) void {
        switch (node.*) {
            .branch => |branch| {
                for (branch.children) |child_opt| {
                    if (child_opt) |child| {
                        self.freeNode(child);
                    }
                }
                if (branch.value) |v| {
                    self.allocator.free(v);
                }
            },
            .extension => |ext| {
                self.allocator.free(ext.path);
                self.freeNode(ext.child);
            },
            .leaf => |leaf| {
                self.allocator.free(leaf.path);
                self.allocator.free(leaf.value);
            },
            else => {},
        }
        self.allocator.destroy(node);
    }

    /// Update account in commitment
    pub fn updateAccount(
        self: *CommitmentBuilder,
        address: [20]u8,
        nonce: u64,
        balance: [32]u8,
        code_hash: [32]u8,
        storage_root: [32]u8,
    ) !void {
        if (self.mode == .disabled) return;

        // Encode account data
        const account_data = try self.encodeAccount(
            nonce,
            balance,
            code_hash,
            storage_root,
        );
        defer self.allocator.free(account_data);

        // Hash address for key
        const key_hash = std.crypto.hash.sha3.Keccak256.hash(&address, .{});

        // Update trie (simplified - full implementation would update merkle path)
        try self.cache.put(std.fmt.bytesToHex(&key_hash, .lower), @constCast(&TrieNode{
            .leaf = .{
                .path = try self.allocator.dupe(u8, &key_hash),
                .value = try self.allocator.dupe(u8, account_data),
            },
        }));
    }

    fn encodeAccount(
        self: *CommitmentBuilder,
        nonce: u64,
        balance: [32]u8,
        code_hash: [32]u8,
        storage_root: [32]u8,
    ) ![]u8 {
        // RLP encode: [nonce, balance, storage_root, code_hash]
        // Simplified version
        var result = std.ArrayList(u8).empty;
        defer result.deinit(self.allocator);

        const nonce_bytes = std.mem.toBytes(nonce);
        try result.appendSlice(self.allocator, &nonce_bytes);
        try result.appendSlice(self.allocator, &balance);
        try result.appendSlice(self.allocator, &storage_root);
        try result.appendSlice(self.allocator, &code_hash);

        return result.toOwnedSlice(self.allocator);
    }

    /// Calculate state root
    pub fn calculateRoot(self: *CommitmentBuilder) ![32]u8 {
        if (self.mode == .disabled) {
            return [_]u8{0} ** 32;
        }

        // In production: Build full trie from cache, hash all nodes
        // Simplified: Hash all leaf values
        var hasher = std.crypto.hash.sha3.Keccak256.init(.{});

        var iter = self.cache.valueIterator();
        while (iter.next()) |node_ptr| {
            const node_hash = try self.hashNode(node_ptr.*);
            hasher.update(&node_hash);
        }

        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    fn hashNode(self: *CommitmentBuilder, node: *TrieNode) ![32]u8 {
        _ = self;
        switch (node.*) {
            .leaf => |leaf| {
                return std.crypto.hash.sha3.Keccak256.hash(leaf.value, .{});
            },
            .hash => |h| {
                return h;
            },
            else => {
                return [_]u8{0} ** 32;
            },
        }
    }
};

/// Hex prefix encoding for trie keys
pub fn hexPrefixEncode(nibbles: []const u8, is_leaf: bool) ![]u8 {
    const allocator = std.heap.page_allocator;
    const odd_len = nibbles.len % 2 == 1;

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    // First byte encodes oddness and leaf status
    if (odd_len) {
        const prefix: u8 = if (is_leaf) 0x30 else 0x10;
        try result.append(allocator, prefix + nibbles[0]);

        var i: usize = 1;
        while (i < nibbles.len) : (i += 2) {
            try result.append(allocator, nibbles[i] * 16 + nibbles[i + 1]);
        }
    } else {
        const prefix: u8 = if (is_leaf) 0x20 else 0x00;
        try result.append(allocator, prefix);

        var i: usize = 0;
        while (i < nibbles.len) : (i += 2) {
            try result.append(allocator, nibbles[i] * 16 + nibbles[i + 1]);
        }
    }

    return result.toOwnedSlice(allocator);
}

test "commitment builder" {
    var builder = CommitmentBuilder.init(std.testing.allocator, .commitment_only);
    defer builder.deinit();

    const addr = [_]u8{1} ** 20;
    try builder.updateAccount(
        addr,
        1, // nonce
        [_]u8{0} ** 32, // balance
        [_]u8{0} ** 32, // code hash
        [_]u8{0} ** 32, // storage root
    );

    const root = try builder.calculateRoot();
    try std.testing.expect(root.len == 32);
}

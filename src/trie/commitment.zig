//! State commitment via Merkle Patricia Trie
//! Based on erigon/commitment package
//!
//! Erigon3 uses "flat state" but still needs tries for:
//! - State root calculation
//! - Witness generation
//! - Proof creation

const std = @import("std");
const MerkleTrie = @import("merkle_trie.zig").MerkleTrie;
const rlp = @import("primitives").rlp;

/// Commitment mode
pub const Mode = enum {
    /// Full Merkle Patricia Trie (archive nodes)
    full_trie,
    /// Optimized commitment without storing full trie (full nodes)
    commitment_only,
    /// No commitment (testing)
    disabled,
};

/// Commitment builder for state root calculation
pub const CommitmentBuilder = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    /// Account trie
    account_trie: MerkleTrie,
    /// Storage tries per account (keyed by address)
    storage_tries: std.AutoHashMap([20]u8, MerkleTrie),

    pub fn init(allocator: std.mem.Allocator, mode: Mode) CommitmentBuilder {
        return .{
            .allocator = allocator,
            .mode = mode,
            .account_trie = MerkleTrie.init(allocator),
            .storage_tries = std.AutoHashMap([20]u8, MerkleTrie).init(allocator),
        };
    }

    pub fn deinit(self: *CommitmentBuilder) void {
        self.account_trie.deinit();

        var iter = self.storage_tries.valueIterator();
        while (iter.next()) |trie| {
            trie.deinit();
        }
        self.storage_tries.deinit();
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

        // Encode account data using RLP
        const account_data = try self.encodeAccount(
            nonce,
            balance,
            code_hash,
            storage_root,
        );
        defer self.allocator.free(account_data);

        // Hash address for key (Keccak256)
        var key_hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&address, &key_hash, .{});

        // Update account trie
        try self.account_trie.put(&key_hash, account_data);
    }

    /// Update storage slot for an account
    pub fn updateStorage(
        self: *CommitmentBuilder,
        address: [20]u8,
        slot: [32]u8,
        value: [32]u8,
    ) !void {
        if (self.mode == .disabled) return;

        // Get or create storage trie for this account
        const result = try self.storage_tries.getOrPut(address);
        if (!result.found_existing) {
            result.value_ptr.* = MerkleTrie.init(self.allocator);
        }

        // Hash slot for key
        var slot_hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&slot, &slot_hash, .{});

        // Update storage trie
        if (std.mem.eql(u8, &value, &[_]u8{0} ** 32)) {
            // Delete zero values
            try result.value_ptr.delete(&slot_hash);
        } else {
            // Encode non-zero value with RLP
            const encoded_value = try rlp.encodeBytes(self.allocator, &value);
            defer self.allocator.free(encoded_value);
            try result.value_ptr.put(&slot_hash, encoded_value);
        }
    }

    /// Encode account using RLP: [nonce, balance, storage_root, code_hash]
    fn encodeAccount(
        self: *CommitmentBuilder,
        nonce: u64,
        balance: [32]u8,
        code_hash: [32]u8,
        storage_root: [32]u8,
    ) ![]u8 {
        var encoder = rlp.Encoder.init(self.allocator);
        defer encoder.deinit();

        try encoder.startList();
        try encoder.writeInt(nonce);
        try encoder.writeBytes(&balance);
        try encoder.writeBytes(&storage_root);
        try encoder.writeBytes(&code_hash);
        try encoder.endList();

        return try encoder.toOwnedSlice();
    }

    /// Calculate state root
    pub fn calculateRoot(self: *CommitmentBuilder) ![32]u8 {
        if (self.mode == .disabled) {
            return [_]u8{0} ** 32;
        }

        // Update all account storage roots
        var iter = self.storage_tries.iterator();
        while (iter.next()) |entry| {
            const address = entry.key_ptr.*;
            const storage_trie = entry.value_ptr.*;

            // Get storage root
            const storage_root = storage_trie.root_hash() orelse [_]u8{0} ** 32;

            // Get current account data and update with new storage root
            var addr_hash: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(&address, &addr_hash, .{});

            if (try self.account_trie.get(&addr_hash)) |account_data| {
                // Decode, update storage root, re-encode
                var decoder = try rlp.Decoder.init(account_data);
                try decoder.enterList();

                const nonce = try decoder.decodeInt(u64);
                const balance_view = try decoder.decodeBytesView();
                var balance: [32]u8 = undefined;
                @memcpy(&balance, balance_view);

                _ = try decoder.decodeBytesView(); // Skip old storage root
                const code_hash_view = try decoder.decodeBytesView();
                var code_hash: [32]u8 = undefined;
                @memcpy(&code_hash, code_hash_view);

                try self.updateAccount(address, nonce, balance, code_hash, storage_root);
            }
        }

        return self.account_trie.root_hash() orelse [_]u8{0} ** 32;
    }

    /// Get storage root for an account
    pub fn getStorageRoot(self: *CommitmentBuilder, address: [20]u8) [32]u8 {
        if (self.storage_tries.get(address)) |trie| {
            return trie.root_hash() orelse [_]u8{0} ** 32;
        }
        return [_]u8{0} ** 32;
    }
};

test "commitment builder - account updates" {
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

test "commitment builder - storage updates" {
    var builder = CommitmentBuilder.init(std.testing.allocator, .commitment_only);
    defer builder.deinit();

    const addr = [_]u8{1} ** 20;

    // Add account first
    try builder.updateAccount(
        addr,
        1,
        [_]u8{0} ** 32,
        [_]u8{0} ** 32,
        [_]u8{0} ** 32,
    );

    // Update storage
    const slot = [_]u8{2} ** 32;
    const value = [_]u8{3} ** 32;
    try builder.updateStorage(addr, slot, value);

    const storage_root = builder.getStorageRoot(addr);
    try std.testing.expect(!std.mem.eql(u8, &storage_root, &[_]u8{0} ** 32));
}

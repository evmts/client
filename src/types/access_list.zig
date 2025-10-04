//! Access List Transaction (Type 1 - EIP-2930)
//! Port of erigon/execution/types/access_list_tx.go

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const Hash = primitives.Hash;
const U256 = primitives.U256;
const rlp = @import("../rlp.zig");
const common = @import("common.zig");
const CommonTx = common.CommonTx;
const AccessList = common.AccessList;
const AccessTuple = common.AccessTuple;
const TxError = common.TxError;
const LegacyTx = @import("legacy.zig").LegacyTx;

/// Access List transaction (EIP-2930)
/// Introduced in Berlin hard fork
pub const AccessListTx = struct {
    /// Embedded legacy transaction fields
    legacy: LegacyTx,
    /// Chain ID for replay protection
    chain_id: U256,
    /// Access list for cheaper storage access
    access_list: AccessList,

    pub fn init(allocator: std.mem.Allocator) AccessListTx {
        return .{
            .legacy = LegacyTx.init(),
            .chain_id = U256.zero(),
            .access_list = AccessList.init(allocator),
        };
    }

    pub fn txType(self: AccessListTx) u8 {
        _ = self;
        return 1;
    }

    pub fn getNonce(self: AccessListTx) u64 {
        return self.legacy.common.nonce;
    }

    pub fn getGasLimit(self: AccessListTx) u64 {
        return self.legacy.common.gas_limit;
    }

    pub fn getGasPrice(self: AccessListTx) U256 {
        return self.legacy.gas_price;
    }

    pub fn getTipCap(self: AccessListTx) U256 {
        return self.legacy.gas_price;
    }

    pub fn getFeeCap(self: AccessListTx) U256 {
        return self.legacy.gas_price;
    }

    pub fn getEffectiveGasTip(self: AccessListTx, base_fee: ?U256) U256 {
        return self.legacy.getEffectiveGasTip(base_fee);
    }

    pub fn getTo(self: AccessListTx) ?Address {
        return self.legacy.common.to;
    }

    pub fn getValue(self: AccessListTx) U256 {
        return self.legacy.common.value;
    }

    pub fn getData(self: AccessListTx) []const u8 {
        return self.legacy.common.data;
    }

    pub fn getAccessList(self: AccessListTx) AccessList {
        return self.access_list;
    }

    pub fn getAuthorizations(self: AccessListTx) []const common.Authorization {
        _ = self;
        return &[_]common.Authorization{};
    }

    pub fn getBlobHashes(self: AccessListTx) []const Hash {
        _ = self;
        return &[_]Hash{};
    }

    pub fn getBlobGas(self: AccessListTx) u64 {
        _ = self;
        return 0;
    }

    pub fn isContractCreation(self: AccessListTx) bool {
        return self.legacy.common.isContractCreation();
    }

    /// Access list transactions are always protected
    pub fn isProtected(self: AccessListTx) bool {
        _ = self;
        return true;
    }

    pub fn getChainId(self: AccessListTx) ?U256 {
        return self.chain_id;
    }

    pub fn rawSignatureValues(self: AccessListTx) struct { v: U256, r: U256, s: U256 } {
        return .{
            .v = self.legacy.common.v,
            .r = self.legacy.common.r,
            .s = self.legacy.common.s,
        };
    }

    /// Clone the transaction
    pub fn clone(self: AccessListTx, allocator: std.mem.Allocator) !AccessListTx {
        const legacy_clone = try self.legacy.clone(allocator);
        errdefer legacy_clone.deinit(allocator);

        const access_list_clone = try self.access_list.clone(allocator);
        errdefer access_list_clone.deinit(allocator);

        return .{
            .legacy = legacy_clone,
            .chain_id = self.chain_id,
            .access_list = access_list_clone,
        };
    }

    pub fn deinit(self: *AccessListTx, allocator: std.mem.Allocator) void {
        self.legacy.deinit(allocator);
        self.access_list.deinit(allocator);
    }

    /// Calculate RLP encoding size
    pub fn encodingSize(self: AccessListTx) usize {
        const payload = self.payloadSize();
        // Type byte + list prefix + payload
        return 1 + rlp.listPrefixLen(payload.total) + payload.total;
    }

    const PayloadSize = struct {
        total: usize,
        nonce_len: usize,
        gas_len: usize,
        access_list_len: usize,
    };

    fn payloadSize(self: AccessListTx) PayloadSize {
        var size: usize = 0;
        var nonce_len: usize = 0;
        var gas_len: usize = 0;
        var access_list_len: usize = 0;

        // ChainID
        size += 1;
        size += rlp.u256LenExcludingHead(self.chain_id);

        // Nonce
        size += 1;
        nonce_len = rlp.intLenExcludingHead(self.legacy.common.nonce);
        size += nonce_len;

        // GasPrice
        size += 1;
        size += rlp.u256LenExcludingHead(self.legacy.gas_price);

        // GasLimit
        size += 1;
        gas_len = rlp.intLenExcludingHead(self.legacy.common.gas_limit);
        size += gas_len;

        // To
        size += 1;
        if (self.legacy.common.to != null) {
            size += 20;
        }

        // Value
        size += 1;
        size += rlp.u256LenExcludingHead(self.legacy.common.value);

        // Data
        size += rlp.stringLen(self.legacy.common.data);

        // AccessList
        access_list_len = self.accessListSize();
        size += rlp.listPrefixLen(access_list_len) + access_list_len;

        // V, R, S
        size += 1;
        size += rlp.u256LenExcludingHead(self.legacy.common.v);
        size += 1;
        size += rlp.u256LenExcludingHead(self.legacy.common.r);
        size += 1;
        size += rlp.u256LenExcludingHead(self.legacy.common.s);

        return .{
            .total = size,
            .nonce_len = nonce_len,
            .gas_len = gas_len,
            .access_list_len = access_list_len,
        };
    }

    fn accessListSize(self: AccessListTx) usize {
        var size: usize = 0;
        for (self.access_list.tuples) |tuple| {
            var tuple_len: usize = 21; // Address (1 + 20)

            // Storage keys: each key is 33 bytes (1 + 32)
            const storage_len = 33 * tuple.storage_keys.len;
            tuple_len += rlp.listPrefixLen(storage_len) + storage_len;

            size += rlp.listPrefixLen(tuple_len) + tuple_len;
        }
        return size;
    }

    /// Encode to canonical format (type byte + RLP payload)
    pub fn encode(self: AccessListTx, allocator: std.mem.Allocator) ![]u8 {
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();

        // ChainID
        try encoder.writeU256(self.chain_id);

        // Nonce
        try encoder.writeInt(self.legacy.common.nonce);

        // GasPrice
        try encoder.writeU256(self.legacy.gas_price);

        // GasLimit
        try encoder.writeInt(self.legacy.common.gas_limit);

        // To
        if (self.legacy.common.to) |to| {
            try encoder.writeBytes(&to.bytes);
        } else {
            try encoder.writeBytes(&[_]u8{});
        }

        // Value
        try encoder.writeU256(self.legacy.common.value);

        // Data
        try encoder.writeBytes(self.legacy.common.data);

        // AccessList
        try encoder.startList();
        for (self.access_list.tuples) |tuple| {
            try encoder.startList();
            try encoder.writeBytes(&tuple.address.bytes);

            try encoder.startList();
            for (tuple.storage_keys) |key| {
                try encoder.writeBytes(&key.bytes);
            }
            try encoder.endList();

            try encoder.endList();
        }
        try encoder.endList();

        // V, R, S
        try encoder.writeU256(self.legacy.common.v);
        try encoder.writeU256(self.legacy.common.r);
        try encoder.writeU256(self.legacy.common.s);

        try encoder.endList();

        const payload = try encoder.toOwnedSlice();
        errdefer allocator.free(payload);

        // Prepend type byte
        var result = try allocator.alloc(u8, 1 + payload.len);
        result[0] = 1; // Type byte
        @memcpy(result[1..], payload);

        allocator.free(payload);
        return result;
    }

    /// Calculate transaction hash (for inclusion in blocks)
    pub fn hash(self: *AccessListTx, allocator: std.mem.Allocator) !Hash {
        if (self.legacy.common.cached_hash) |h| {
            return h;
        }

        const encoded = try self.encode(allocator);
        defer allocator.free(encoded);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(encoded, &hash_bytes, .{});

        const h = Hash.fromBytesExact(hash_bytes);
        self.legacy.common.cached_hash = h;
        return h;
    }

    /// Calculate signing hash (what gets signed)
    pub fn signingHash(self: AccessListTx, allocator: std.mem.Allocator) !Hash {
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();

        // ChainID
        try encoder.writeU256(self.chain_id);

        // Nonce
        try encoder.writeInt(self.legacy.common.nonce);

        // GasPrice
        try encoder.writeU256(self.legacy.gas_price);

        // GasLimit
        try encoder.writeInt(self.legacy.common.gas_limit);

        // To
        if (self.legacy.common.to) |to| {
            try encoder.writeBytes(&to.bytes);
        } else {
            try encoder.writeBytes(&[_]u8{});
        }

        // Value
        try encoder.writeU256(self.legacy.common.value);

        // Data
        try encoder.writeBytes(self.legacy.common.data);

        // AccessList
        try encoder.startList();
        for (self.access_list.tuples) |tuple| {
            try encoder.startList();
            try encoder.writeBytes(&tuple.address.bytes);

            try encoder.startList();
            for (tuple.storage_keys) |key| {
                try encoder.writeBytes(&key.bytes);
            }
            try encoder.endList();

            try encoder.endList();
        }
        try encoder.endList();

        try encoder.endList();

        const payload = try encoder.toOwnedSlice();
        defer allocator.free(payload);

        // Prepend type byte for signing hash
        var to_hash = try allocator.alloc(u8, 1 + payload.len);
        defer allocator.free(to_hash);

        to_hash[0] = 1;
        @memcpy(to_hash[1..], payload);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(to_hash, &hash_bytes, .{});

        return Hash.fromBytesExact(hash_bytes);
    }
};

// Helper function for list prefix length
fn listPrefixLen(payload_len: usize) usize {
    return rlp.listPrefixLen(payload_len);
}

// Tests
test "AccessListTx - init and basic fields" {
    const testing = std.testing;

    var tx = AccessListTx.init(testing.allocator);
    defer tx.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 1), tx.txType());
    try testing.expectEqual(@as(u64, 0), tx.getNonce());
    try testing.expect(tx.isProtected());
    try testing.expect(tx.isContractCreation());
}

test "AccessListTx - access list storage keys count" {
    const testing = std.testing;

    var tuples = try testing.allocator.alloc(AccessTuple, 2);
    defer testing.allocator.free(tuples);

    const keys1 = try testing.allocator.alloc(Hash, 2);
    keys1[0] = Hash.zero();
    keys1[1] = Hash.zero();

    const keys2 = try testing.allocator.alloc(Hash, 1);
    keys2[0] = Hash.zero();

    tuples[0] = .{
        .address = Address.zero(),
        .storage_keys = keys1,
    };
    tuples[1] = .{
        .address = Address.zero(),
        .storage_keys = keys2,
    };

    var tx = AccessListTx.init(testing.allocator);
    tx.access_list = .{ .tuples = tuples };

    try testing.expectEqual(@as(usize, 3), tx.access_list.storageKeys());

    // Clean up
    for (tuples) |*tuple| {
        testing.allocator.free(tuple.storage_keys);
    }
}

test "AccessListTx - chain ID" {
    const testing = std.testing;

    var tx = AccessListTx.init(testing.allocator);
    defer tx.deinit(testing.allocator);

    tx.chain_id = U256.fromInt(1);

    const chain_id = tx.getChainId().?;
    try testing.expect(chain_id.eql(U256.fromInt(1)));
}

test "AccessListTx - clone" {
    const testing = std.testing;

    var tx = AccessListTx.init(testing.allocator);
    tx.legacy.common.nonce = 5;
    tx.chain_id = U256.fromInt(1);

    const data = try testing.allocator.dupe(u8, "test data");
    tx.legacy.common.data = data;

    const cloned = try tx.clone(testing.allocator);
    defer {
        var mut_cloned = cloned;
        mut_cloned.deinit(testing.allocator);
    }

    try testing.expectEqual(tx.getNonce(), cloned.getNonce());
    try testing.expect(tx.chain_id.eql(cloned.chain_id));
    try testing.expectEqualStrings(tx.legacy.common.data, cloned.legacy.common.data);

    // Ensure deep copy
    try testing.expect(tx.legacy.common.data.ptr != cloned.legacy.common.data.ptr);

    // Clean up original
    testing.allocator.free(data);
}

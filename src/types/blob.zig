//! Blob Transaction (Type 3 - EIP-4844)
//! Port of erigon/execution/types/blob_tx.go

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const Hash = primitives.Hash;
const U256 = primitives.U256;
const rlp = @import("primitives").rlp;
const common = @import("common.zig");
const CommonTx = common.CommonTx;
const AccessList = common.AccessList;
const AccessTuple = common.AccessTuple;
const TxError = common.TxError;
const DynamicFeeTx = @import("dynamic_fee.zig").DynamicFeeTx;

/// Gas per blob (EIP-4844 constant)
pub const GAS_PER_BLOB: u64 = 131072; // 128 KB

/// Blob transaction (EIP-4844)
/// Introduced in Cancun hard fork
/// Note: 'To' field cannot be nil (must have recipient)
pub const BlobTx = struct {
    /// Embedded dynamic fee transaction
    dynamic_fee: DynamicFeeTx,
    /// Maximum fee per blob gas
    max_fee_per_blob_gas: U256,
    /// Versioned blob hashes
    blob_versioned_hashes: []Hash,

    pub fn init(allocator: std.mem.Allocator) BlobTx {
        return .{
            .dynamic_fee = DynamicFeeTx.init(allocator),
            .max_fee_per_blob_gas = U256.zero(),
            .blob_versioned_hashes = &[_]Hash{},
        };
    }

    pub fn txType(self: BlobTx) u8 {
        _ = self;
        return 3;
    }

    pub fn getNonce(self: BlobTx) u64 {
        return self.dynamic_fee.common.nonce;
    }

    pub fn getGasLimit(self: BlobTx) u64 {
        return self.dynamic_fee.common.gas_limit;
    }

    pub fn getGasPrice(self: BlobTx) U256 {
        return self.dynamic_fee.fee_cap;
    }

    pub fn getTipCap(self: BlobTx) U256 {
        return self.dynamic_fee.tip_cap;
    }

    pub fn getFeeCap(self: BlobTx) U256 {
        return self.dynamic_fee.fee_cap;
    }

    pub fn getEffectiveGasTip(self: BlobTx, base_fee: ?U256) U256 {
        return self.dynamic_fee.getEffectiveGasTip(base_fee);
    }

    pub fn getTo(self: BlobTx) ?Address {
        return self.dynamic_fee.common.to;
    }

    pub fn getValue(self: BlobTx) U256 {
        return self.dynamic_fee.common.value;
    }

    pub fn getData(self: BlobTx) []const u8 {
        return self.dynamic_fee.common.data;
    }

    pub fn getAccessList(self: BlobTx) AccessList {
        return self.dynamic_fee.access_list;
    }

    pub fn getAuthorizations(self: BlobTx) []const common.Authorization {
        _ = self;
        return &[_]common.Authorization{};
    }

    pub fn getBlobHashes(self: BlobTx) []const Hash {
        return self.blob_versioned_hashes;
    }

    /// Calculate total blob gas
    pub fn getBlobGas(self: BlobTx) u64 {
        return GAS_PER_BLOB * @as(u64, @intCast(self.blob_versioned_hashes.len));
    }

    pub fn isContractCreation(self: BlobTx) bool {
        // Blob transactions MUST have a 'to' field (cannot be contract creation)
        return false;
    }

    /// Blob transactions are always protected
    pub fn isProtected(self: BlobTx) bool {
        _ = self;
        return true;
    }

    pub fn getChainId(self: BlobTx) ?U256 {
        return self.dynamic_fee.chain_id;
    }

    pub fn rawSignatureValues(self: BlobTx) struct { v: U256, r: U256, s: U256 } {
        return .{
            .v = self.dynamic_fee.common.v,
            .r = self.dynamic_fee.common.r,
            .s = self.dynamic_fee.common.s,
        };
    }

    /// Clone the transaction
    pub fn clone(self: BlobTx, allocator: std.mem.Allocator) !BlobTx {
        const dynamic_fee_clone = try self.dynamic_fee.clone(allocator);
        errdefer dynamic_fee_clone.deinit(allocator);

        const blob_hashes_clone = try allocator.dupe(Hash, self.blob_versioned_hashes);
        errdefer allocator.free(blob_hashes_clone);

        return .{
            .dynamic_fee = dynamic_fee_clone,
            .max_fee_per_blob_gas = self.max_fee_per_blob_gas,
            .blob_versioned_hashes = blob_hashes_clone,
        };
    }

    pub fn deinit(self: *BlobTx, allocator: std.mem.Allocator) void {
        self.dynamic_fee.deinit(allocator);
        if (self.blob_versioned_hashes.len > 0) {
            allocator.free(self.blob_versioned_hashes);
        }
    }

    /// Calculate RLP encoding size
    pub fn encodingSize(self: BlobTx) usize {
        const payload = self.payloadSize();
        // Type byte + list prefix + payload
        return 1 + rlp.listPrefixLen(payload.total) + payload.total;
    }

    const PayloadSize = struct {
        total: usize,
        nonce_len: usize,
        gas_len: usize,
        access_list_len: usize,
        blob_hashes_len: usize,
    };

    fn payloadSize(self: BlobTx) PayloadSize {
        // Start with DynamicFeeTx payload
        const dyn_payload = self.dynamic_fee.payloadSize();
        var size = dyn_payload.total;

        // MaxFeePerBlobGas
        size += 1;
        size += rlp.u256LenExcludingHead(self.max_fee_per_blob_gas);

        // BlobVersionedHashes
        const blob_hashes_len = self.blobVersionedHashesSize();
        size += rlp.listPrefixLen(blob_hashes_len) + blob_hashes_len;

        return .{
            .total = size,
            .nonce_len = dyn_payload.nonce_len,
            .gas_len = dyn_payload.gas_len,
            .access_list_len = dyn_payload.access_list_len,
            .blob_hashes_len = blob_hashes_len,
        };
    }

    fn blobVersionedHashesSize(self: BlobTx) usize {
        // Each hash is 33 bytes (1 byte prefix + 32 bytes)
        return 33 * self.blob_versioned_hashes.len;
    }

    fn accessListSize(self: BlobTx) usize {
        var size: usize = 0;
        for (self.dynamic_fee.access_list.tuples) |tuple| {
            var tuple_len: usize = 21; // Address (1 + 20)

            // Storage keys: each key is 33 bytes (1 + 32)
            const storage_len = 33 * tuple.storage_keys.len;
            tuple_len += rlp.listPrefixLen(storage_len) + storage_len;

            size += rlp.listPrefixLen(tuple_len) + tuple_len;
        }
        return size;
    }

    /// Encode to canonical format (type byte + RLP payload)
    /// Note: Returns error if 'to' field is nil
    pub fn encode(self: BlobTx, allocator: std.mem.Allocator) ![]u8 {
        // Blob transactions MUST have a 'to' field
        if (self.dynamic_fee.common.to == null) {
            return error.NilToField;
        }

        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();

        // ChainID
        try encoder.writeU256(self.dynamic_fee.chain_id);

        // Nonce
        try encoder.writeInt(self.dynamic_fee.common.nonce);

        // MaxPriorityFeePerGas (TipCap)
        try encoder.writeU256(self.dynamic_fee.tip_cap);

        // MaxFeePerGas (FeeCap)
        try encoder.writeU256(self.dynamic_fee.fee_cap);

        // GasLimit
        try encoder.writeInt(self.dynamic_fee.common.gas_limit);

        // To (must be non-null)
        const to = self.dynamic_fee.common.to.?;
        try encoder.writeBytes(&to.bytes);

        // Value
        try encoder.writeU256(self.dynamic_fee.common.value);

        // Data
        try encoder.writeBytes(self.dynamic_fee.common.data);

        // AccessList
        try encoder.startList();
        for (self.dynamic_fee.access_list.tuples) |tuple| {
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

        // MaxFeePerBlobGas
        try encoder.writeU256(self.max_fee_per_blob_gas);

        // BlobVersionedHashes
        try encoder.startList();
        for (self.blob_versioned_hashes) |hash| {
            try encoder.writeBytes(&hash.bytes);
        }
        try encoder.endList();

        // V, R, S
        try encoder.writeU256(self.dynamic_fee.common.v);
        try encoder.writeU256(self.dynamic_fee.common.r);
        try encoder.writeU256(self.dynamic_fee.common.s);

        try encoder.endList();

        const payload = try encoder.toOwnedSlice();
        errdefer allocator.free(payload);

        // Prepend type byte
        var result = try allocator.alloc(u8, 1 + payload.len);
        result[0] = 3; // Type byte
        @memcpy(result[1..], payload);

        allocator.free(payload);
        return result;
    }

    /// Calculate transaction hash (for inclusion in blocks)
    pub fn hash(self: *BlobTx, allocator: std.mem.Allocator) !Hash {
        if (self.dynamic_fee.common.cached_hash) |h| {
            return h;
        }

        const encoded = try self.encode(allocator);
        defer allocator.free(encoded);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(encoded, &hash_bytes, .{});

        const h = Hash.fromBytesExact(hash_bytes);
        self.dynamic_fee.common.cached_hash = h;
        return h;
    }

    /// Calculate signing hash (what gets signed)
    pub fn signingHash(self: BlobTx, allocator: std.mem.Allocator) !Hash {
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();

        // ChainID
        try encoder.writeU256(self.dynamic_fee.chain_id);

        // Nonce
        try encoder.writeInt(self.dynamic_fee.common.nonce);

        // MaxPriorityFeePerGas (TipCap)
        try encoder.writeU256(self.dynamic_fee.tip_cap);

        // MaxFeePerGas (FeeCap)
        try encoder.writeU256(self.dynamic_fee.fee_cap);

        // GasLimit
        try encoder.writeInt(self.dynamic_fee.common.gas_limit);

        // To (signing hash also requires non-null to)
        if (self.dynamic_fee.common.to) |to| {
            try encoder.writeBytes(&to.bytes);
        } else {
            return error.NilToField;
        }

        // Value
        try encoder.writeU256(self.dynamic_fee.common.value);

        // Data
        try encoder.writeBytes(self.dynamic_fee.common.data);

        // AccessList
        try encoder.startList();
        for (self.dynamic_fee.access_list.tuples) |tuple| {
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

        // MaxFeePerBlobGas
        try encoder.writeU256(self.max_fee_per_blob_gas);

        // BlobVersionedHashes
        try encoder.startList();
        for (self.blob_versioned_hashes) |hash| {
            try encoder.writeBytes(&hash.bytes);
        }
        try encoder.endList();

        try encoder.endList();

        const payload = try encoder.toOwnedSlice();
        defer allocator.free(payload);

        // Prepend type byte for signing hash
        var to_hash = try allocator.alloc(u8, 1 + payload.len);
        defer allocator.free(to_hash);

        to_hash[0] = 3;
        @memcpy(to_hash[1..], payload);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(to_hash, &hash_bytes, .{});

        return Hash.fromBytesExact(hash_bytes);
    }
};

// Tests
test "BlobTx - init and basic fields" {
    const testing = std.testing;

    var tx = BlobTx.init(testing.allocator);
    defer tx.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 3), tx.txType());
    try testing.expectEqual(@as(u64, 0), tx.getNonce());
    try testing.expect(tx.isProtected());
    try testing.expect(!tx.isContractCreation()); // Blob txs cannot be contract creation
}

test "BlobTx - blob gas calculation" {
    const testing = std.testing;

    var tx = BlobTx.init(testing.allocator);
    defer tx.deinit(testing.allocator);

    // No blobs initially
    try testing.expectEqual(@as(u64, 0), tx.getBlobGas());

    // Add 3 blob hashes
    const hashes = try testing.allocator.alloc(Hash, 3);
    hashes[0] = Hash.zero();
    hashes[1] = Hash.zero();
    hashes[2] = Hash.zero();
    tx.blob_versioned_hashes = hashes;

    // Should be 3 * GAS_PER_BLOB
    try testing.expectEqual(@as(u64, 3 * GAS_PER_BLOB), tx.getBlobGas());
}

test "BlobTx - must have recipient" {
    const testing = std.testing;

    var tx = BlobTx.init(testing.allocator);
    defer tx.deinit(testing.allocator);

    // Without 'to' field, encoding should fail
    const result = tx.encode(testing.allocator);
    try testing.expectError(error.NilToField, result);

    // With 'to' field, encoding should succeed
    tx.dynamic_fee.common.to = Address.zero();
    const encoded = try tx.encode(testing.allocator);
    defer testing.allocator.free(encoded);

    try testing.expect(encoded.len > 0);
    try testing.expectEqual(@as(u8, 3), encoded[0]); // Type byte
}

test "BlobTx - clone" {
    const testing = std.testing;

    var tx = BlobTx.init(testing.allocator);
    tx.dynamic_fee.common.nonce = 5;
    tx.dynamic_fee.chain_id = U256.fromInt(1);
    tx.max_fee_per_blob_gas = U256.fromInt(1000);

    const data = try testing.allocator.dupe(u8, "test data");
    tx.dynamic_fee.common.data = data;

    const hashes = try testing.allocator.alloc(Hash, 2);
    hashes[0] = Hash.zero();
    hashes[1] = Hash.zero();
    tx.blob_versioned_hashes = hashes;

    const cloned = try tx.clone(testing.allocator);
    defer {
        var mut_cloned = cloned;
        mut_cloned.deinit(testing.allocator);
    }

    try testing.expectEqual(tx.getNonce(), cloned.getNonce());
    try testing.expect(tx.dynamic_fee.chain_id.eql(cloned.dynamic_fee.chain_id));
    try testing.expect(tx.max_fee_per_blob_gas.eql(cloned.max_fee_per_blob_gas));
    try testing.expectEqual(tx.blob_versioned_hashes.len, cloned.blob_versioned_hashes.len);
    try testing.expectEqualStrings(tx.dynamic_fee.common.data, cloned.dynamic_fee.common.data);

    // Ensure deep copy
    try testing.expect(tx.dynamic_fee.common.data.ptr != cloned.dynamic_fee.common.data.ptr);
    try testing.expect(tx.blob_versioned_hashes.ptr != cloned.blob_versioned_hashes.ptr);

    // Clean up original
    testing.allocator.free(data);
}

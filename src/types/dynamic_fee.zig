//! Dynamic Fee Transaction (Type 2 - EIP-1559)
//! Port of erigon/execution/types/dynamic_fee_tx.go

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

/// Dynamic Fee transaction (EIP-1559)
/// Introduced in London hard fork
pub const DynamicFeeTx = struct {
    /// Embedded common transaction fields
    common: CommonTx,
    /// Chain ID for replay protection
    chain_id: U256,
    /// Max priority fee per gas (tip)
    tip_cap: U256,
    /// Max fee per gas (fee cap)
    fee_cap: U256,
    /// Access list for cheaper storage access
    access_list: AccessList,

    pub fn init(allocator: std.mem.Allocator) DynamicFeeTx {
        return .{
            .common = CommonTx.init(),
            .chain_id = U256.zero(),
            .tip_cap = U256.zero(),
            .fee_cap = U256.zero(),
            .access_list = AccessList.init(allocator),
        };
    }

    pub fn txType(self: DynamicFeeTx) u8 {
        _ = self;
        return 2;
    }

    pub fn getNonce(self: DynamicFeeTx) u64 {
        return self.common.nonce;
    }

    pub fn getGasLimit(self: DynamicFeeTx) u64 {
        return self.common.gas_limit;
    }

    pub fn getGasPrice(self: DynamicFeeTx) U256 {
        return self.fee_cap;
    }

    pub fn getTipCap(self: DynamicFeeTx) U256 {
        return self.tip_cap;
    }

    pub fn getFeeCap(self: DynamicFeeTx) U256 {
        return self.fee_cap;
    }

    /// Get effective gas tip based on base fee
    /// Returns min(tipCap, feeCap - baseFee)
    /// Returns 0 if feeCap < baseFee
    pub fn getEffectiveGasTip(self: DynamicFeeTx, base_fee: ?U256) U256 {
        if (base_fee == null) {
            return self.tip_cap;
        }

        const base = base_fee.?;

        // If feeCap < baseFee, return 0
        if (self.fee_cap.lt(base)) {
            return U256.zero();
        }

        // effectiveFee = feeCap - baseFee
        const effective_fee = self.fee_cap.sub(base);

        // Return min(tipCap, effectiveFee)
        if (self.tip_cap.lt(effective_fee)) {
            return self.tip_cap;
        } else {
            return effective_fee;
        }
    }

    pub fn getTo(self: DynamicFeeTx) ?Address {
        return self.common.to;
    }

    pub fn getValue(self: DynamicFeeTx) U256 {
        return self.common.value;
    }

    pub fn getData(self: DynamicFeeTx) []const u8 {
        return self.common.data;
    }

    pub fn getAccessList(self: DynamicFeeTx) AccessList {
        return self.access_list;
    }

    pub fn getAuthorizations(self: DynamicFeeTx) []const common.Authorization {
        _ = self;
        return &[_]common.Authorization{};
    }

    pub fn getBlobHashes(self: DynamicFeeTx) []const Hash {
        _ = self;
        return &[_]Hash{};
    }

    pub fn getBlobGas(self: DynamicFeeTx) u64 {
        _ = self;
        return 0;
    }

    pub fn isContractCreation(self: DynamicFeeTx) bool {
        return self.common.isContractCreation();
    }

    /// Dynamic fee transactions are always protected
    pub fn isProtected(self: DynamicFeeTx) bool {
        _ = self;
        return true;
    }

    pub fn getChainId(self: DynamicFeeTx) ?U256 {
        return self.chain_id;
    }

    pub fn rawSignatureValues(self: DynamicFeeTx) struct { v: U256, r: U256, s: U256 } {
        return .{
            .v = self.common.v,
            .r = self.common.r,
            .s = self.common.s,
        };
    }

    /// Clone the transaction
    pub fn clone(self: DynamicFeeTx, allocator: std.mem.Allocator) !DynamicFeeTx {
        const common_clone = try self.common.clone(allocator);
        errdefer common_clone.deinit(allocator);

        const access_list_clone = try self.access_list.clone(allocator);
        errdefer access_list_clone.deinit(allocator);

        return .{
            .common = common_clone,
            .chain_id = self.chain_id,
            .tip_cap = self.tip_cap,
            .fee_cap = self.fee_cap,
            .access_list = access_list_clone,
        };
    }

    pub fn deinit(self: *DynamicFeeTx, allocator: std.mem.Allocator) void {
        self.common.deinit(allocator);
        self.access_list.deinit(allocator);
    }

    /// Calculate RLP encoding size
    pub fn encodingSize(self: DynamicFeeTx) usize {
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

    fn payloadSize(self: DynamicFeeTx) PayloadSize {
        var size: usize = 0;
        var nonce_len: usize = 0;
        var gas_len: usize = 0;
        var access_list_len: usize = 0;

        // ChainID
        size += 1;
        size += rlp.u256LenExcludingHead(self.chain_id);

        // Nonce
        size += 1;
        nonce_len = rlp.intLenExcludingHead(self.common.nonce);
        size += nonce_len;

        // MaxPriorityFeePerGas (TipCap)
        size += 1;
        size += rlp.u256LenExcludingHead(self.tip_cap);

        // MaxFeePerGas (FeeCap)
        size += 1;
        size += rlp.u256LenExcludingHead(self.fee_cap);

        // GasLimit
        size += 1;
        gas_len = rlp.intLenExcludingHead(self.common.gas_limit);
        size += gas_len;

        // To
        size += 1;
        if (self.common.to != null) {
            size += 20;
        }

        // Value
        size += 1;
        size += rlp.u256LenExcludingHead(self.common.value);

        // Data
        size += rlp.stringLen(self.common.data);

        // AccessList
        access_list_len = self.accessListSize();
        size += rlp.listPrefixLen(access_list_len) + access_list_len;

        // V, R, S
        size += 1;
        size += rlp.u256LenExcludingHead(self.common.v);
        size += 1;
        size += rlp.u256LenExcludingHead(self.common.r);
        size += 1;
        size += rlp.u256LenExcludingHead(self.common.s);

        return .{
            .total = size,
            .nonce_len = nonce_len,
            .gas_len = gas_len,
            .access_list_len = access_list_len,
        };
    }

    fn accessListSize(self: DynamicFeeTx) usize {
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
    pub fn encode(self: DynamicFeeTx, allocator: std.mem.Allocator) ![]u8 {
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();

        // ChainID
        try encoder.writeU256(self.chain_id);

        // Nonce
        try encoder.writeInt(self.common.nonce);

        // MaxPriorityFeePerGas (TipCap)
        try encoder.writeU256(self.tip_cap);

        // MaxFeePerGas (FeeCap)
        try encoder.writeU256(self.fee_cap);

        // GasLimit
        try encoder.writeInt(self.common.gas_limit);

        // To
        if (self.common.to) |to| {
            try encoder.writeBytes(&to.bytes);
        } else {
            try encoder.writeBytes(&[_]u8{});
        }

        // Value
        try encoder.writeU256(self.common.value);

        // Data
        try encoder.writeBytes(self.common.data);

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
        try encoder.writeU256(self.common.v);
        try encoder.writeU256(self.common.r);
        try encoder.writeU256(self.common.s);

        try encoder.endList();

        const payload = try encoder.toOwnedSlice();
        errdefer allocator.free(payload);

        // Prepend type byte
        var result = try allocator.alloc(u8, 1 + payload.len);
        result[0] = 2; // Type byte
        @memcpy(result[1..], payload);

        allocator.free(payload);
        return result;
    }

    /// Calculate transaction hash (for inclusion in blocks)
    pub fn hash(self: *DynamicFeeTx, allocator: std.mem.Allocator) !Hash {
        if (self.common.cached_hash) |h| {
            return h;
        }

        const encoded = try self.encode(allocator);
        defer allocator.free(encoded);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(encoded, &hash_bytes, .{});

        const h = Hash.fromBytesExact(hash_bytes);
        self.common.cached_hash = h;
        return h;
    }

    /// Calculate signing hash (what gets signed)
    pub fn signingHash(self: DynamicFeeTx, allocator: std.mem.Allocator) !Hash {
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();

        // ChainID
        try encoder.writeU256(self.chain_id);

        // Nonce
        try encoder.writeInt(self.common.nonce);

        // MaxPriorityFeePerGas (TipCap)
        try encoder.writeU256(self.tip_cap);

        // MaxFeePerGas (FeeCap)
        try encoder.writeU256(self.fee_cap);

        // GasLimit
        try encoder.writeInt(self.common.gas_limit);

        // To
        if (self.common.to) |to| {
            try encoder.writeBytes(&to.bytes);
        } else {
            try encoder.writeBytes(&[_]u8{});
        }

        // Value
        try encoder.writeU256(self.common.value);

        // Data
        try encoder.writeBytes(self.common.data);

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

        to_hash[0] = 2;
        @memcpy(to_hash[1..], payload);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(to_hash, &hash_bytes, .{});

        return Hash.fromBytesExact(hash_bytes);
    }
};

// Tests
test "DynamicFeeTx - init and basic fields" {
    const testing = std.testing;

    var tx = DynamicFeeTx.init(testing.allocator);
    defer tx.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 2), tx.txType());
    try testing.expectEqual(@as(u64, 0), tx.getNonce());
    try testing.expect(tx.isProtected());
    try testing.expect(tx.isContractCreation());
}

test "DynamicFeeTx - effective gas tip calculation" {
    const testing = std.testing;

    var tx = DynamicFeeTx.init(testing.allocator);
    defer tx.deinit(testing.allocator);

    tx.tip_cap = U256.fromInt(10);
    tx.fee_cap = U256.fromInt(100);

    // No base fee - returns tip cap
    const tip1 = tx.getEffectiveGasTip(null);
    try testing.expect(tip1.eql(U256.fromInt(10)));

    // Base fee 50, effective = 100-50 = 50, min(10, 50) = 10
    const tip2 = tx.getEffectiveGasTip(U256.fromInt(50));
    try testing.expect(tip2.eql(U256.fromInt(10)));

    // Base fee 95, effective = 100-95 = 5, min(10, 5) = 5
    const tip3 = tx.getEffectiveGasTip(U256.fromInt(95));
    try testing.expect(tip3.eql(U256.fromInt(5)));

    // Base fee 101, feeCap < baseFee, return 0
    const tip4 = tx.getEffectiveGasTip(U256.fromInt(101));
    try testing.expect(tip4.eql(U256.zero()));
}

test "DynamicFeeTx - chain ID" {
    const testing = std.testing;

    var tx = DynamicFeeTx.init(testing.allocator);
    defer tx.deinit(testing.allocator);

    tx.chain_id = U256.fromInt(1);

    const chain_id = tx.getChainId().?;
    try testing.expect(chain_id.eql(U256.fromInt(1)));
}

test "DynamicFeeTx - clone" {
    const testing = std.testing;

    var tx = DynamicFeeTx.init(testing.allocator);
    tx.common.nonce = 5;
    tx.chain_id = U256.fromInt(1);
    tx.tip_cap = U256.fromInt(10);
    tx.fee_cap = U256.fromInt(100);

    const data = try testing.allocator.dupe(u8, "test data");
    tx.common.data = data;

    const cloned = try tx.clone(testing.allocator);
    defer {
        var mut_cloned = cloned;
        mut_cloned.deinit(testing.allocator);
    }

    try testing.expectEqual(tx.getNonce(), cloned.getNonce());
    try testing.expect(tx.chain_id.eql(cloned.chain_id));
    try testing.expect(tx.tip_cap.eql(cloned.tip_cap));
    try testing.expect(tx.fee_cap.eql(cloned.fee_cap));
    try testing.expectEqualStrings(tx.common.data, cloned.common.data);

    // Ensure deep copy
    try testing.expect(tx.common.data.ptr != cloned.common.data.ptr);

    // Clean up original
    testing.allocator.free(data);
}

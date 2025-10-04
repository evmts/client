//! SetCode Transaction (Type 4 - EIP-7702)
//! Port of erigon/execution/types/set_code_tx.go

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
const Authorization = common.Authorization;
const TxError = common.TxError;
const DynamicFeeTx = @import("dynamic_fee.zig").DynamicFeeTx;

/// Delegate designation code size (EIP-7702 constant)
pub const DELEGATE_DESIGNATION_CODE_SIZE: usize = 23;

/// SetCode transaction (EIP-7702)
/// Introduced in Prague hard fork
/// Allows EOAs to temporarily set code for transaction execution
pub const SetCodeTx = struct {
    /// Embedded dynamic fee transaction
    dynamic_fee: DynamicFeeTx,
    /// Authorizations for setting code
    authorizations: []Authorization,

    pub fn init(allocator: std.mem.Allocator) SetCodeTx {
        return .{
            .dynamic_fee = DynamicFeeTx.init(allocator),
            .authorizations = &[_]Authorization{},
        };
    }

    pub fn txType(self: SetCodeTx) u8 {
        _ = self;
        return 4;
    }

    pub fn getNonce(self: SetCodeTx) u64 {
        return self.dynamic_fee.common.nonce;
    }

    pub fn getGasLimit(self: SetCodeTx) u64 {
        return self.dynamic_fee.common.gas_limit;
    }

    pub fn getGasPrice(self: SetCodeTx) U256 {
        return self.dynamic_fee.fee_cap;
    }

    pub fn getTipCap(self: SetCodeTx) U256 {
        return self.dynamic_fee.tip_cap;
    }

    pub fn getFeeCap(self: SetCodeTx) U256 {
        return self.dynamic_fee.fee_cap;
    }

    pub fn getEffectiveGasTip(self: SetCodeTx, base_fee: ?U256) U256 {
        return self.dynamic_fee.getEffectiveGasTip(base_fee);
    }

    pub fn getTo(self: SetCodeTx) ?Address {
        return self.dynamic_fee.common.to;
    }

    pub fn getValue(self: SetCodeTx) U256 {
        return self.dynamic_fee.common.value;
    }

    pub fn getData(self: SetCodeTx) []const u8 {
        return self.dynamic_fee.common.data;
    }

    pub fn getAccessList(self: SetCodeTx) AccessList {
        return self.dynamic_fee.access_list;
    }

    pub fn getAuthorizations(self: SetCodeTx) []const Authorization {
        return self.authorizations;
    }

    pub fn getBlobHashes(self: SetCodeTx) []const Hash {
        _ = self;
        return &[_]Hash{};
    }

    pub fn getBlobGas(self: SetCodeTx) u64 {
        _ = self;
        return 0;
    }

    pub fn isContractCreation(self: SetCodeTx) bool {
        return self.dynamic_fee.common.isContractCreation();
    }

    /// SetCode transactions are always protected
    pub fn isProtected(self: SetCodeTx) bool {
        _ = self;
        return true;
    }

    pub fn getChainId(self: SetCodeTx) ?U256 {
        return self.dynamic_fee.chain_id;
    }

    pub fn rawSignatureValues(self: SetCodeTx) struct { v: U256, r: U256, s: U256 } {
        return .{
            .v = self.dynamic_fee.common.v,
            .r = self.dynamic_fee.common.r,
            .s = self.dynamic_fee.common.s,
        };
    }

    /// Clone the transaction
    pub fn clone(self: SetCodeTx, allocator: std.mem.Allocator) !SetCodeTx {
        const dynamic_fee_clone = try self.dynamic_fee.clone(allocator);
        errdefer dynamic_fee_clone.deinit(allocator);

        const authorizations_clone = try allocator.dupe(Authorization, self.authorizations);
        errdefer allocator.free(authorizations_clone);

        return .{
            .dynamic_fee = dynamic_fee_clone,
            .authorizations = authorizations_clone,
        };
    }

    pub fn deinit(self: *SetCodeTx, allocator: std.mem.Allocator) void {
        self.dynamic_fee.deinit(allocator);
        if (self.authorizations.len > 0) {
            allocator.free(self.authorizations);
        }
    }

    /// Calculate RLP encoding size
    pub fn encodingSize(self: SetCodeTx) usize {
        const payload = self.payloadSize();
        // Type byte + list prefix + payload
        return 1 + rlp.listPrefixLen(payload.total) + payload.total;
    }

    const PayloadSize = struct {
        total: usize,
        nonce_len: usize,
        gas_len: usize,
        access_list_len: usize,
        authorizations_len: usize,
    };

    fn payloadSize(self: SetCodeTx) PayloadSize {
        // Start with DynamicFeeTx payload
        const dyn_payload = self.dynamic_fee.payloadSize();
        var size = dyn_payload.total;

        // Authorizations
        const authorizations_len = self.authorizationsSize();
        size += rlp.listPrefixLen(authorizations_len) + authorizations_len;

        return .{
            .total = size,
            .nonce_len = dyn_payload.nonce_len,
            .gas_len = dyn_payload.gas_len,
            .access_list_len = dyn_payload.access_list_len,
            .authorizations_len = authorizations_len,
        };
    }

    fn authorizationSize(auth: Authorization) usize {
        var size: usize = 0;

        // ChainID
        size += 1;
        size += rlp.u256LenExcludingHead(auth.chain_id);

        // Address
        size += 1 + 20;

        // Nonce
        size += 1;
        size += rlp.intLenExcludingHead(auth.nonce);

        // YParity
        size += 1;
        size += rlp.intLenExcludingHead(auth.y_parity);

        // R
        size += 1;
        size += rlp.u256LenExcludingHead(auth.r);

        // S
        size += 1;
        size += rlp.u256LenExcludingHead(auth.s);

        return size;
    }

    fn authorizationsSize(self: SetCodeTx) usize {
        var size: usize = 0;
        for (self.authorizations) |auth| {
            const auth_len = authorizationSize(auth);
            size += rlp.listPrefixLen(auth_len) + auth_len;
        }
        return size;
    }

    fn accessListSize(self: SetCodeTx) usize {
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
    pub fn encode(self: SetCodeTx, allocator: std.mem.Allocator) ![]u8 {
        // SetCode transactions MUST have a 'to' field
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

        // To
        if (self.dynamic_fee.common.to) |to| {
            try encoder.writeBytes(&to.bytes);
        } else {
            try encoder.writeBytes(&[_]u8{});
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

        // Authorizations
        try encoder.startList();
        for (self.authorizations) |auth| {
            try encoder.startList();

            // ChainID
            try encoder.writeU256(auth.chain_id);

            // Address
            try encoder.writeBytes(&auth.address.bytes);

            // Nonce
            try encoder.writeInt(auth.nonce);

            // YParity
            try encoder.writeInt(@as(u64, auth.y_parity));

            // R
            try encoder.writeU256(auth.r);

            // S
            try encoder.writeU256(auth.s);

            try encoder.endList();
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
        result[0] = 4; // Type byte
        @memcpy(result[1..], payload);

        allocator.free(payload);
        return result;
    }

    /// Calculate transaction hash (for inclusion in blocks)
    pub fn hash(self: *SetCodeTx, allocator: std.mem.Allocator) !Hash {
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
    pub fn signingHash(self: SetCodeTx, allocator: std.mem.Allocator) !Hash {
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

        // To
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

        // Authorizations
        try encoder.startList();
        for (self.authorizations) |auth| {
            try encoder.startList();

            // ChainID
            try encoder.writeU256(auth.chain_id);

            // Address
            try encoder.writeBytes(&auth.address.bytes);

            // Nonce
            try encoder.writeInt(auth.nonce);

            // YParity
            try encoder.writeInt(@as(u64, auth.y_parity));

            // R
            try encoder.writeU256(auth.r);

            // S
            try encoder.writeU256(auth.s);

            try encoder.endList();
        }
        try encoder.endList();

        try encoder.endList();

        const payload = try encoder.toOwnedSlice();
        defer allocator.free(payload);

        // Prepend type byte for signing hash
        var to_hash = try allocator.alloc(u8, 1 + payload.len);
        defer allocator.free(to_hash);

        to_hash[0] = 4;
        @memcpy(to_hash[1..], payload);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(to_hash, &hash_bytes, .{});

        return Hash.fromBytesExact(hash_bytes);
    }
};

// Tests
test "SetCodeTx - init and basic fields" {
    const testing = std.testing;

    var tx = SetCodeTx.init(testing.allocator);
    defer tx.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 4), tx.txType());
    try testing.expectEqual(@as(u64, 0), tx.getNonce());
    try testing.expect(tx.isProtected());
}

test "SetCodeTx - authorizations" {
    const testing = std.testing;

    var tx = SetCodeTx.init(testing.allocator);
    defer tx.deinit(testing.allocator);

    // No authorizations initially
    try testing.expectEqual(@as(usize, 0), tx.getAuthorizations().len);

    // Add authorizations
    const auths = try testing.allocator.alloc(Authorization, 2);
    auths[0] = .{
        .chain_id = U256.fromInt(1),
        .address = Address.zero(),
        .nonce = 0,
        .y_parity = 0,
        .r = U256.zero(),
        .s = U256.zero(),
    };
    auths[1] = .{
        .chain_id = U256.fromInt(1),
        .address = Address.zero(),
        .nonce = 1,
        .y_parity = 1,
        .r = U256.zero(),
        .s = U256.zero(),
    };
    tx.authorizations = auths;

    try testing.expectEqual(@as(usize, 2), tx.getAuthorizations().len);
}

test "SetCodeTx - must have recipient" {
    const testing = std.testing;

    var tx = SetCodeTx.init(testing.allocator);
    defer tx.deinit(testing.allocator);

    // Without 'to' field, encoding should fail
    const result = tx.encode(testing.allocator);
    try testing.expectError(error.NilToField, result);

    // With 'to' field, encoding should succeed
    tx.dynamic_fee.common.to = Address.zero();
    const encoded = try tx.encode(testing.allocator);
    defer testing.allocator.free(encoded);

    try testing.expect(encoded.len > 0);
    try testing.expectEqual(@as(u8, 4), encoded[0]); // Type byte
}

test "SetCodeTx - clone" {
    const testing = std.testing;

    var tx = SetCodeTx.init(testing.allocator);
    tx.dynamic_fee.common.nonce = 5;
    tx.dynamic_fee.chain_id = U256.fromInt(1);

    const data = try testing.allocator.dupe(u8, "test data");
    tx.dynamic_fee.common.data = data;

    const auths = try testing.allocator.alloc(Authorization, 1);
    auths[0] = .{
        .chain_id = U256.fromInt(1),
        .address = Address.zero(),
        .nonce = 0,
        .y_parity = 0,
        .r = U256.zero(),
        .s = U256.zero(),
    };
    tx.authorizations = auths;

    const cloned = try tx.clone(testing.allocator);
    defer {
        var mut_cloned = cloned;
        mut_cloned.deinit(testing.allocator);
    }

    try testing.expectEqual(tx.getNonce(), cloned.getNonce());
    try testing.expect(tx.dynamic_fee.chain_id.eql(cloned.dynamic_fee.chain_id));
    try testing.expectEqual(tx.authorizations.len, cloned.authorizations.len);
    try testing.expectEqualStrings(tx.dynamic_fee.common.data, cloned.dynamic_fee.common.data);

    // Ensure deep copy
    try testing.expect(tx.dynamic_fee.common.data.ptr != cloned.dynamic_fee.common.data.ptr);
    try testing.expect(tx.authorizations.ptr != cloned.authorizations.ptr);

    // Clean up original
    testing.allocator.free(data);
}

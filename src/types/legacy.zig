//! Legacy Transaction (Type 0)
//! Port of erigon/execution/types/legacy_tx.go

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const Hash = primitives.Hash;
const U256 = primitives.U256;
const rlp = @import("primitives").rlp;
const common = @import("common.zig");
const CommonTx = common.CommonTx;
const TxError = common.TxError;

/// Legacy transaction (pre-EIP-155 and EIP-155)
pub const LegacyTx = struct {
    common: CommonTx,
    gas_price: U256,

    pub fn init() LegacyTx {
        return .{
            .common = CommonTx.init(),
            .gas_price = U256.zero(),
        };
    }

    pub fn txType(self: LegacyTx) u8 {
        _ = self;
        return 0;
    }

    pub fn getNonce(self: LegacyTx) u64 {
        return self.common.nonce;
    }

    pub fn getGasLimit(self: LegacyTx) u64 {
        return self.common.gas_limit;
    }

    pub fn getGasPrice(self: LegacyTx) U256 {
        return self.gas_price;
    }

    pub fn getTipCap(self: LegacyTx) U256 {
        return self.gas_price;
    }

    pub fn getFeeCap(self: LegacyTx) U256 {
        return self.gas_price;
    }

    pub fn getEffectiveGasTip(self: LegacyTx, base_fee: ?U256) U256 {
        if (base_fee == null) {
            return self.getTipCap();
        }

        const gas_fee_cap = self.getFeeCap();
        const bf = base_fee.?;

        // Return 0 if effectiveFee cant be < 0
        if (gas_fee_cap.lt(bf)) {
            return U256.zero();
        }

        const effective_fee = gas_fee_cap.sub(bf);
        const tip_cap = self.getTipCap();

        if (tip_cap.lt(effective_fee)) {
            return tip_cap;
        } else {
            return effective_fee;
        }
    }

    pub fn getTo(self: LegacyTx) ?Address {
        return self.common.to;
    }

    pub fn getValue(self: LegacyTx) U256 {
        return self.common.value;
    }

    pub fn getData(self: LegacyTx) []const u8 {
        return self.common.data;
    }

    pub fn getAccessList(self: LegacyTx) common.AccessList {
        _ = self;
        return common.AccessList.init(undefined);
    }

    pub fn getAuthorizations(self: LegacyTx) []const common.Authorization {
        _ = self;
        return &[_]common.Authorization{};
    }

    pub fn getBlobHashes(self: LegacyTx) []const Hash {
        _ = self;
        return &[_]Hash{};
    }

    pub fn getBlobGas(self: LegacyTx) u64 {
        _ = self;
        return 0;
    }

    pub fn isContractCreation(self: LegacyTx) bool {
        return self.common.isContractCreation();
    }

    /// Check if transaction is EIP-155 protected
    pub fn isProtected(self: LegacyTx) bool {
        return isProtectedV(self.common.v);
    }

    /// Get chain ID from V value (EIP-155)
    pub fn getChainId(self: LegacyTx) ?U256 {
        return deriveChainId(self.common.v);
    }

    pub fn rawSignatureValues(self: LegacyTx) struct { v: U256, r: U256, s: U256 } {
        return .{
            .v = self.common.v,
            .r = self.common.r,
            .s = self.common.s,
        };
    }

    /// Clone the transaction
    pub fn clone(self: LegacyTx, allocator: std.mem.Allocator) !LegacyTx {
        const data_copy = try allocator.dupe(u8, self.common.data);
        return .{
            .common = .{
                .nonce = self.common.nonce,
                .gas_limit = self.common.gas_limit,
                .to = self.common.to,
                .value = self.common.value,
                .data = data_copy,
                .v = self.common.v,
                .r = self.common.r,
                .s = self.common.s,
                .cached_sender = self.common.cached_sender,
                .cached_hash = self.common.cached_hash,
            },
            .gas_price = self.gas_price,
        };
    }

    pub fn deinit(self: *LegacyTx, allocator: std.mem.Allocator) void {
        allocator.free(self.common.data);
    }

    /// Calculate RLP encoding size
    pub fn encodingSize(self: LegacyTx) usize {
        const payload = self.payloadSize();
        return payload.total;
    }

    const PayloadSize = struct {
        total: usize,
        nonce_len: usize,
        gas_len: usize,
    };

    fn payloadSize(self: LegacyTx) PayloadSize {
        var size: usize = 0;
        var nonce_len: usize = 0;
        var gas_len: usize = 0;

        // Nonce
        size += 1;
        nonce_len = rlp.intLenExcludingHead(self.common.nonce);
        size += nonce_len;

        // GasPrice
        size += 1;
        size += rlp.u256LenExcludingHead(self.gas_price);

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
        };
    }

    /// Encode transaction to RLP
    pub fn encodeRlp(self: LegacyTx, allocator: std.mem.Allocator) ![]u8 {
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();
        try encoder.writeInt(self.common.nonce);
        try encoder.writeU256(self.gas_price);
        try encoder.writeInt(self.common.gas_limit);

        if (self.common.to) |to| {
            try encoder.writeBytes(&to.bytes);
        } else {
            try encoder.writeBytes(&[_]u8{});
        }

        try encoder.writeU256(self.common.value);
        try encoder.writeBytes(self.common.data);
        try encoder.writeU256(self.common.v);
        try encoder.writeU256(self.common.r);
        try encoder.writeU256(self.common.s);
        try encoder.endList();

        return try encoder.toOwnedSlice();
    }

    /// Calculate transaction hash
    pub fn hash(self: *LegacyTx, allocator: std.mem.Allocator) !Hash {
        if (self.common.cached_hash) |h| {
            return h;
        }

        const encoded = try self.encodeRlp(allocator);
        defer allocator.free(encoded);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(encoded, &hash_bytes, .{});

        const h = Hash.fromBytesExact(hash_bytes);
        self.common.cached_hash = h;
        return h;
    }

    /// Calculate signing hash for signature
    pub fn signingHash(self: LegacyTx, allocator: std.mem.Allocator, chain_id: ?U256) !Hash {
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();
        try encoder.writeInt(self.common.nonce);
        try encoder.writeU256(self.gas_price);
        try encoder.writeInt(self.common.gas_limit);

        if (self.common.to) |to| {
            try encoder.writeBytes(&to.bytes);
        } else {
            try encoder.writeBytes(&[_]u8{});
        }

        try encoder.writeU256(self.common.value);
        try encoder.writeBytes(self.common.data);

        // EIP-155: include chain ID in signing hash
        if (chain_id) |cid| {
            try encoder.writeU256(cid);
            try encoder.writeInt(@as(u64, 0));
            try encoder.writeInt(@as(u64, 0));
        }

        try encoder.endList();

        const encoded = try encoder.toOwnedSlice();
        defer allocator.free(encoded);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(encoded, &hash_bytes, .{});

        return Hash.fromBytesExact(hash_bytes);
    }
};

/// Check if V value indicates EIP-155 protection
fn isProtectedV(v: U256) bool {
    // V < 35 means not EIP-155 protected
    return v.cmp(U256.fromInt(35)) >= 0;
}

/// Derive chain ID from V value (EIP-155)
fn deriveChainId(v: U256) ?U256 {
    if (!isProtectedV(v)) {
        return null;
    }

    // chainID = (V - 35) / 2
    var chain_id = v.sub(U256.fromInt(35));
    return chain_id.div(U256.fromInt(2));
}

// Tests
test "LegacyTx - init and basic fields" {
    const testing = std.testing;

    var tx = LegacyTx.init();
    try testing.expectEqual(@as(u8, 0), tx.txType());
    try testing.expectEqual(@as(u64, 0), tx.getNonce());
    try testing.expectEqual(@as(u64, 0), tx.getGasLimit());
    try testing.expect(tx.isContractCreation());
}

test "LegacyTx - EIP-155 protection" {
    const testing = std.testing;

    var tx = LegacyTx.init();

    // V = 27/28 = not protected
    tx.common.v = U256.fromInt(27);
    try testing.expect(!tx.isProtected());
    try testing.expectEqual(@as(?U256, null), tx.getChainId());

    // V = 37 = protected with chain ID 1
    tx.common.v = U256.fromInt(37);
    try testing.expect(tx.isProtected());
    const chain_id = tx.getChainId().?;
    try testing.expect(chain_id.eql(U256.fromInt(1)));
}

test "LegacyTx - effective gas tip" {
    const testing = std.testing;

    var tx = LegacyTx.init();
    tx.gas_price = U256.fromInt(100);

    // No base fee
    const tip1 = tx.getEffectiveGasTip(null);
    try testing.expect(tip1.eql(U256.fromInt(100)));

    // Base fee lower than gas price
    const tip2 = tx.getEffectiveGasTip(U256.fromInt(50));
    try testing.expect(tip2.eql(U256.fromInt(50)));

    // Base fee higher than gas price
    const tip3 = tx.getEffectiveGasTip(U256.fromInt(150));
    try testing.expect(tip3.eql(U256.zero()));
}

test "LegacyTx - clone" {
    const testing = std.testing;

    var tx = LegacyTx.init();
    tx.common.nonce = 5;
    tx.gas_price = U256.fromInt(1000);

    const data = try testing.allocator.dupe(u8, "test data");
    tx.common.data = data;

    const cloned = try tx.clone(testing.allocator);
    defer {
        var mut_cloned = cloned;
        mut_cloned.deinit(testing.allocator);
    }

    try testing.expectEqual(tx.common.nonce, cloned.common.nonce);
    try testing.expect(tx.gas_price.eql(cloned.gas_price));
    try testing.expectEqualStrings(tx.common.data, cloned.common.data);

    // Ensure it's a deep copy
    try testing.expect(tx.common.data.ptr != cloned.common.data.ptr);

    // Clean up original
    testing.allocator.free(data);
}

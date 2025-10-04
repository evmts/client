//! Common transaction types and structures
//! Port of erigon/execution/types/legacy_tx.go (CommonTx)

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const Hash = primitives.Hash;
const U256 = primitives.U256;

/// Transaction type constants (EIP-2718)
pub const TxType = enum(u8) {
    legacy = 0,
    access_list = 1, // EIP-2930
    dynamic_fee = 2, // EIP-1559
    blob = 3, // EIP-4844
    set_code = 4, // EIP-7702
    account_abstraction = 5, // Future

    pub fn fromByte(b: u8) !TxType {
        return std.meta.intToEnum(TxType, b) catch error.InvalidTxType;
    }
};

/// Access tuple for EIP-2930 access lists
pub const AccessTuple = struct {
    address: Address,
    storage_keys: []Hash,

    pub fn deinit(self: *AccessTuple, allocator: std.mem.Allocator) void {
        allocator.free(self.storage_keys);
    }

    pub fn clone(self: AccessTuple, allocator: std.mem.Allocator) !AccessTuple {
        const keys = try allocator.alloc(Hash, self.storage_keys.len);
        @memcpy(keys, self.storage_keys);
        return .{
            .address = self.address,
            .storage_keys = keys,
        };
    }
};

/// Access list for EIP-2930+ transactions
pub const AccessList = struct {
    tuples: []AccessTuple,

    pub fn init(allocator: std.mem.Allocator) AccessList {
        return .{ .tuples = &[_]AccessTuple{} };
    }

    pub fn deinit(self: *AccessList, allocator: std.mem.Allocator) void {
        for (self.tuples) |*tuple| {
            tuple.deinit(allocator);
        }
        allocator.free(self.tuples);
    }

    pub fn storageKeys(self: AccessList) usize {
        var sum: usize = 0;
        for (self.tuples) |tuple| {
            sum += tuple.storage_keys.len;
        }
        return sum;
    }

    pub fn clone(self: AccessList, allocator: std.mem.Allocator) !AccessList {
        const tuples = try allocator.alloc(AccessTuple, self.tuples.len);
        errdefer allocator.free(tuples);

        for (self.tuples, 0..) |tuple, i| {
            tuples[i] = try tuple.clone(allocator);
        }

        return .{ .tuples = tuples };
    }
};

/// Authorization for EIP-7702 set code transactions
pub const Authorization = struct {
    chain_id: U256,
    address: Address,
    nonce: u64,
    v: U256,
    r: U256,
    s: U256,

    pub fn clone(self: Authorization) Authorization {
        return self; // All fields are value types
    }
};

/// Common transaction fields shared by all transaction types
/// Port of Erigon's CommonTx
pub const CommonTx = struct {
    nonce: u64,
    gas_limit: u64,
    to: ?Address, // null = contract creation
    value: U256,
    data: []const u8,
    v: U256, // signature V
    r: U256, // signature R
    s: U256, // signature S

    /// Cached sender address (populated after signature verification)
    cached_sender: ?Address,
    /// Cached transaction hash
    cached_hash: ?Hash,

    pub fn init() CommonTx {
        return .{
            .nonce = 0,
            .gas_limit = 0,
            .to = null,
            .value = U256.zero(),
            .data = &[_]u8{},
            .v = U256.zero(),
            .r = U256.zero(),
            .s = U256.zero(),
            .cached_sender = null,
            .cached_hash = null,
        };
    }

    pub fn isContractCreation(self: CommonTx) bool {
        return self.to == null;
    }

    pub fn getSender(self: CommonTx) ?Address {
        return self.cached_sender;
    }

    pub fn setSender(self: *CommonTx, sender: Address) void {
        self.cached_sender = sender;
    }

    pub fn getHash(self: CommonTx) ?Hash {
        return self.cached_hash;
    }

    pub fn setHash(self: *CommonTx, hash: Hash) void {
        self.cached_hash = hash;
    }
};

/// Transaction errors
pub const TxError = error{
    InvalidTxType,
    InvalidSignature,
    UnexpectedProtection,
    TxTypeNotSupported,
    InvalidRlpData,
    OutOfMemory,
};

// Tests
test "TxType - from byte" {
    const testing = std.testing;

    try testing.expectEqual(TxType.legacy, try TxType.fromByte(0));
    try testing.expectEqual(TxType.access_list, try TxType.fromByte(1));
    try testing.expectEqual(TxType.dynamic_fee, try TxType.fromByte(2));
    try testing.expectEqual(TxType.blob, try TxType.fromByte(3));
    try testing.expectEqual(TxType.set_code, try TxType.fromByte(4));
    try testing.expectEqual(TxType.account_abstraction, try TxType.fromByte(5));

    try testing.expectError(error.InvalidTxType, TxType.fromByte(6));
}

test "AccessList - storage keys count" {
    const testing = std.testing;

    var tuples = [_]AccessTuple{
        .{
            .address = Address.zero(),
            .storage_keys = &[_]Hash{ Hash.zero(), Hash.zero() },
        },
        .{
            .address = Address.zero(),
            .storage_keys = &[_]Hash{Hash.zero()},
        },
    };

    const access_list = AccessList{ .tuples = &tuples };
    try testing.expectEqual(@as(usize, 3), access_list.storageKeys());
}

test "CommonTx - contract creation detection" {
    const testing = std.testing;

    var tx = CommonTx.init();
    try testing.expect(tx.isContractCreation());

    tx.to = Address.zero();
    try testing.expect(!tx.isContractCreation());
}

test "CommonTx - sender caching" {
    const testing = std.testing;

    var tx = CommonTx.init();
    try testing.expectEqual(@as(?Address, null), tx.getSender());

    const sender = Address.zero();
    tx.setSender(sender);
    try testing.expectEqual(sender, tx.getSender().?);
}

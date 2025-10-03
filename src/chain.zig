//! Blockchain data structures
//! Defines blocks, headers, transactions, and receipts

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;

// U256 is just Zig's built-in 256-bit unsigned integer
pub const U256 = struct {
    value: u256,

    pub fn zero() U256 {
        return .{ .value = 0 };
    }

    pub fn fromInt(v: u64) U256 {
        return .{ .value = v };
    }

    pub fn toBytes(self: U256) [32]u8 {
        var bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &bytes, self.value, .big);
        return bytes;
    }

    pub fn fromBytes(bytes: [32]u8) U256 {
        return .{ .value = std.mem.readInt(u256, &bytes, .big) };
    }

    pub fn add(self: U256, other: U256) U256 {
        return .{ .value = self.value +% other.value };
    }

    pub fn sub(self: U256, other: U256) U256 {
        return .{ .value = self.value -% other.value };
    }

    pub fn mul(self: U256, other: U256) U256 {
        return .{ .value = self.value *% other.value };
    }

    pub fn eql(self: U256, other: U256) bool {
        return self.value == other.value;
    }

    pub fn lt(self: U256, other: U256) bool {
        return self.value < other.value;
    }
};

/// Block header containing metadata about a block
pub const Header = struct {
    parent_hash: [32]u8,
    uncle_hash: [32]u8,
    coinbase: Address,
    state_root: [32]u8,
    transactions_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    difficulty: U256,
    number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    mix_hash: [32]u8,
    nonce: u64,
    base_fee_per_gas: ?u64, // EIP-1559
    withdrawals_root: ?[32]u8, // EIP-4895

    pub fn hash(self: *const Header, allocator: std.mem.Allocator) ![32]u8 {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(allocator);

        try self.encodeRlp(allocator, &list);
        return std.crypto.hash.sha3.Keccak256.hash(list.items, .{});
    }

    fn encodeRlp(self: *const Header, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        _ = allocator;
        // Simplified: In production, use proper RLP encoding
        // For now, just concatenate critical fields
        try out.appendSlice(&self.parent_hash);
        try out.appendSlice(&self.state_root);
        const num_bytes = std.mem.toBytes(self.number);
        try out.appendSlice(&num_bytes);
    }

    pub fn verify(self: *const Header) bool {
        // Basic validation
        if (self.gas_used > self.gas_limit) return false;
        if (self.number == 0 and !std.mem.eql(u8, &self.parent_hash, &([_]u8{0} ** 32))) return false;
        return true;
    }
};

/// Transaction types
pub const TransactionType = enum(u8) {
    legacy = 0,
    eip2930 = 1,
    eip1559 = 2,
    eip4844 = 3,
};

/// Ethereum transaction
pub const Transaction = struct {
    tx_type: TransactionType,
    nonce: u64,
    gas_price: ?U256, // Legacy
    max_fee_per_gas: ?U256, // EIP-1559
    max_priority_fee_per_gas: ?U256, // EIP-1559
    gas_limit: u64,
    to: ?Address,
    value: U256,
    data: []const u8,
    v: u64,
    r: U256,
    s: U256,
    chain_id: ?u64,

    pub fn hash(self: *const Transaction, allocator: std.mem.Allocator) ![32]u8 {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(allocator);

        try self.encodeRlp(allocator, &list);
        return std.crypto.hash.sha3.Keccak256.hash(list.items, .{});
    }

    fn encodeRlp(self: *const Transaction, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        _ = allocator;
        // Simplified RLP encoding
        const nonce_bytes = std.mem.toBytes(self.nonce);
        try out.appendSlice(&nonce_bytes);
        try out.appendSlice(self.data);
    }

    pub fn recoverSender(self: *const Transaction, allocator: std.mem.Allocator) !Address {
        _ = allocator;
        // Simplified: In production, use ECDSA recovery
        // For minimal implementation, derive from signature data
        var addr_bytes: [20]u8 = undefined;
        const r_bytes = self.r.toBytes();
        @memcpy(addr_bytes[0..20], r_bytes[0..20]);
        return Address.fromBytes(&addr_bytes);
    }
};

/// Transaction receipt
pub const Receipt = struct {
    tx_type: TransactionType,
    success: bool,
    cumulative_gas_used: u64,
    logs_bloom: [256]u8,
    logs: []Log,

    pub fn deinit(self: *Receipt, allocator: std.mem.Allocator) void {
        allocator.free(self.logs);
    }
};

/// Event log
pub const Log = struct {
    address: Address,
    topics: []const [32]u8,
    data: []const u8,
};

/// Complete block with transactions
pub const Block = struct {
    header: Header,
    transactions: []Transaction,
    uncles: []Header,

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        allocator.free(self.transactions);
        allocator.free(self.uncles);
        allocator.destroy(self);
    }

    pub fn hash(self: *const Block, allocator: std.mem.Allocator) ![32]u8 {
        return self.header.hash(allocator);
    }

    pub fn number(self: *const Block) u64 {
        return self.header.number;
    }

    pub fn verify(self: *const Block) bool {
        if (!self.header.verify()) return false;
        if (self.transactions.len > 1000000) return false; // Sanity check
        return true;
    }
};

test "header hash computation" {
    const allocator = std.testing.allocator;

    var header = Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = U256.zero(),
        .number = 0,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 0,
        .extra_data = &[_]u8{},
        .mix_hash = [_]u8{0} ** 32,
        .nonce = 0,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
    };

    const h = try header.hash(allocator);
    try std.testing.expect(h.len == 32);
}

test "header validation" {
    var header = Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = U256.zero(),
        .number = 0,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 0,
        .extra_data = &[_]u8{},
        .mix_hash = [_]u8{0} ** 32,
        .nonce = 0,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
    };

    try std.testing.expect(header.verify());

    // Test invalid gas usage
    header.gas_used = header.gas_limit + 1;
    try std.testing.expect(!header.verify());
}

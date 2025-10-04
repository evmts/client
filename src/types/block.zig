//! Block types for Ethereum
//! Port of erigon/execution/types/block.go

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const Hash = primitives.Hash;
const U256 = primitives.U256;
const rlp = @import("primitives").rlp;
const Transaction = @import("transaction.zig").Transaction;

/// Bloom filter byte length (256 bytes = 2048 bits)
pub const BLOOM_BYTE_LENGTH: usize = 256;
pub const BLOOM_BIT_LENGTH: usize = 8 * BLOOM_BYTE_LENGTH;

/// Extra vanity length for block signer
pub const EXTRA_VANITY_LENGTH: usize = 32;
/// Extra seal length for block signer signature
pub const EXTRA_SEAL_LENGTH: usize = 65;

/// Bloom filter for efficient log filtering
/// 256-byte (2048-bit) bloom filter
pub const Bloom = struct {
    bytes: [BLOOM_BYTE_LENGTH]u8,

    pub fn zero() Bloom {
        return .{ .bytes = [_]u8{0} ** BLOOM_BYTE_LENGTH };
    }

    pub fn fromBytes(b: []const u8) Bloom {
        var bloom = Bloom.zero();
        const len = @min(b.len, BLOOM_BYTE_LENGTH);
        @memcpy(bloom.bytes[BLOOM_BYTE_LENGTH - len ..], b[0..len]);
        return bloom;
    }

    pub fn eql(self: Bloom, other: Bloom) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Add a value to the bloom filter
    pub fn add(self: *Bloom, data: []const u8) void {
        var hash_buf: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(data, &hash_buf, .{});

        // Add 3 bits to bloom from hash
        const idx1 = BLOOM_BYTE_LENGTH - ((std.mem.readInt(u16, hash_buf[0..2], .big) & 0x7ff) >> 3) - 1;
        const idx2 = BLOOM_BYTE_LENGTH - ((std.mem.readInt(u16, hash_buf[2..4], .big) & 0x7ff) >> 3) - 1;
        const idx3 = BLOOM_BYTE_LENGTH - ((std.mem.readInt(u16, hash_buf[4..6], .big) & 0x7ff) >> 3) - 1;

        const v1: u8 = @as(u8, 1) << @as(u3, @intCast(hash_buf[0] & 0x7));
        const v2: u8 = @as(u8, 1) << @as(u3, @intCast(hash_buf[2] & 0x7));
        const v3: u8 = @as(u8, 1) << @as(u3, @intCast(hash_buf[4] & 0x7));

        self.bytes[idx1] |= v1;
        self.bytes[idx2] |= v2;
        self.bytes[idx3] |= v3;
    }

    /// Test if bloom filter might contain a value
    pub fn contains(self: Bloom, data: []const u8) bool {
        var hash_buf: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(data, &hash_buf, .{});

        const idx1 = BLOOM_BYTE_LENGTH - ((std.mem.readInt(u16, hash_buf[0..2], .big) & 0x7ff) >> 3) - 1;
        const idx2 = BLOOM_BYTE_LENGTH - ((std.mem.readInt(u16, hash_buf[2..4], .big) & 0x7ff) >> 3) - 1;
        const idx3 = BLOOM_BYTE_LENGTH - ((std.mem.readInt(u16, hash_buf[4..6], .big) & 0x7ff) >> 3) - 1;

        const v1: u8 = @as(u8, 1) << @as(u3, @intCast(hash_buf[0] & 0x7));
        const v2: u8 = @as(u8, 1) << @as(u3, @intCast(hash_buf[2] & 0x7));
        const v3: u8 = @as(u8, 1) << @as(u3, @intCast(hash_buf[4] & 0x7));

        return (self.bytes[idx1] & v1) == v1 and
            (self.bytes[idx2] & v2) == v2 and
            (self.bytes[idx3] & v3) == v3;
    }
};

/// Block nonce (8-byte value for PoW)
pub const BlockNonce = struct {
    bytes: [8]u8,

    pub fn fromU64(n: u64) BlockNonce {
        var nonce: BlockNonce = undefined;
        std.mem.writeInt(u64, &nonce.bytes, n, .big);
        return nonce;
    }

    pub fn toU64(self: BlockNonce) u64 {
        return std.mem.readInt(u64, &self.bytes, .big);
    }

    pub fn zero() BlockNonce {
        return .{ .bytes = [_]u8{0} ** 8 };
    }
};

/// Block header
/// Contains all consensus-critical block metadata
pub const Header = struct {
    // Core fields (all forks)
    parent_hash: Hash,
    uncle_hash: Hash,
    coinbase: Address,
    root: Hash, // State root
    tx_hash: Hash, // Transactions root
    receipt_hash: Hash, // Receipts root
    bloom: Bloom,
    difficulty: U256,
    number: U256,
    gas_limit: u64,
    gas_used: u64,
    time: u64,
    extra: []const u8,

    // PoW fields (pre-merge)
    mix_digest: Hash, // Also used as prevRandao post-EIP-4399
    nonce: BlockNonce,

    // Alternative consensus (AuRa)
    aura_step: ?u64,
    aura_seal: ?[]const u8,

    // EIP-1559 (London)
    base_fee: ?U256,

    // EIP-4895 (Shanghai - withdrawals)
    withdrawals_hash: ?Hash,

    // EIP-4844 (Cancun - blobs)
    blob_gas_used: ?u64,
    excess_blob_gas: ?u64,

    // EIP-4788 (Cancun - beacon root)
    parent_beacon_block_root: ?Hash,

    // EIP-7685 (Prague - requests)
    requests_hash: ?Hash,

    // Cached hash
    cached_hash: ?Hash,

    pub fn init() Header {
        return .{
            .parent_hash = Hash.zero(),
            .uncle_hash = Hash.zero(),
            .coinbase = Address.zero(),
            .root = Hash.zero(),
            .tx_hash = Hash.zero(),
            .receipt_hash = Hash.zero(),
            .bloom = Bloom.zero(),
            .difficulty = U256.zero(),
            .number = U256.zero(),
            .gas_limit = 0,
            .gas_used = 0,
            .time = 0,
            .extra = &[_]u8{},
            .mix_digest = Hash.zero(),
            .nonce = BlockNonce.zero(),
            .aura_step = null,
            .aura_seal = null,
            .base_fee = null,
            .withdrawals_hash = null,
            .blob_gas_used = null,
            .excess_blob_gas = null,
            .parent_beacon_block_root = null,
            .requests_hash = null,
            .cached_hash = null,
        };
    }

    pub fn clone(self: Header, allocator: std.mem.Allocator) !Header {
        const extra_copy = try allocator.dupe(u8, self.extra);
        errdefer allocator.free(extra_copy);

        var aura_seal_copy: ?[]const u8 = null;
        if (self.aura_seal) |seal| {
            aura_seal_copy = try allocator.dupe(u8, seal);
        }
        errdefer if (aura_seal_copy) |seal| allocator.free(seal);

        return .{
            .parent_hash = self.parent_hash,
            .uncle_hash = self.uncle_hash,
            .coinbase = self.coinbase,
            .root = self.root,
            .tx_hash = self.tx_hash,
            .receipt_hash = self.receipt_hash,
            .bloom = self.bloom,
            .difficulty = self.difficulty,
            .number = self.number,
            .gas_limit = self.gas_limit,
            .gas_used = self.gas_used,
            .time = self.time,
            .extra = extra_copy,
            .mix_digest = self.mix_digest,
            .nonce = self.nonce,
            .aura_step = self.aura_step,
            .aura_seal = aura_seal_copy,
            .base_fee = self.base_fee,
            .withdrawals_hash = self.withdrawals_hash,
            .blob_gas_used = self.blob_gas_used,
            .excess_blob_gas = self.excess_blob_gas,
            .parent_beacon_block_root = self.parent_beacon_block_root,
            .requests_hash = self.requests_hash,
            .cached_hash = self.cached_hash,
        };
    }

    pub fn deinit(self: *Header, allocator: std.mem.Allocator) void {
        if (self.extra.len > 0) {
            allocator.free(self.extra);
        }
        if (self.aura_seal) |seal| {
            allocator.free(seal);
        }
    }

    /// Calculate block hash (Keccak256 of RLP-encoded header)
    pub fn hash(self: *Header, allocator: std.mem.Allocator) !Hash {
        if (self.cached_hash) |h| {
            return h;
        }

        const encoded = try self.encode(allocator);
        defer allocator.free(encoded);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(encoded, &hash_bytes, .{});

        const h = Hash.fromBytesExact(hash_bytes);
        self.cached_hash = h;
        return h;
    }

    /// Encode header to RLP
    pub fn encode(self: Header, allocator: std.mem.Allocator) ![]u8 {
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();

        // Core fields
        try encoder.writeBytes(&self.parent_hash.bytes);
        try encoder.writeBytes(&self.uncle_hash.bytes);
        try encoder.writeBytes(&self.coinbase.bytes);
        try encoder.writeBytes(&self.root.bytes);
        try encoder.writeBytes(&self.tx_hash.bytes);
        try encoder.writeBytes(&self.receipt_hash.bytes);
        try encoder.writeBytes(&self.bloom.bytes);
        try encoder.writeU256(self.difficulty);
        try encoder.writeU256(self.number);
        try encoder.writeInt(self.gas_limit);
        try encoder.writeInt(self.gas_used);
        try encoder.writeInt(self.time);
        try encoder.writeBytes(self.extra);

        // PoW or AuRa fields
        if (self.aura_seal) |seal| {
            if (self.aura_step) |step| {
                try encoder.writeInt(step);
            }
            try encoder.writeBytes(seal);
        } else {
            try encoder.writeBytes(&self.mix_digest.bytes);
            try encoder.writeBytes(&self.nonce.bytes);
        }

        // EIP-1559
        if (self.base_fee) |fee| {
            try encoder.writeU256(fee);
        }

        // EIP-4895
        if (self.withdrawals_hash) |wh| {
            try encoder.writeBytes(&wh.bytes);
        }

        // EIP-4844
        if (self.blob_gas_used) |bgu| {
            try encoder.writeInt(bgu);
        }
        if (self.excess_blob_gas) |ebg| {
            try encoder.writeInt(ebg);
        }

        // EIP-4788
        if (self.parent_beacon_block_root) |pbbr| {
            try encoder.writeBytes(&pbbr.bytes);
        }

        // EIP-7685
        if (self.requests_hash) |rh| {
            try encoder.writeBytes(&rh.bytes);
        }

        try encoder.endList();

        return try encoder.toOwnedSlice();
    }
};

/// Block body (transactions and uncles)
pub const Body = struct {
    transactions: []Transaction,
    uncles: []Header,

    pub fn init() Body {
        return .{
            .transactions = &[_]Transaction{},
            .uncles = &[_]Header{},
        };
    }

    pub fn deinit(self: *Body, allocator: std.mem.Allocator) void {
        for (self.transactions) |*tx| {
            tx.deinit(allocator);
        }
        if (self.transactions.len > 0) {
            allocator.free(self.transactions);
        }

        for (self.uncles) |*uncle| {
            uncle.deinit(allocator);
        }
        if (self.uncles.len > 0) {
            allocator.free(self.uncles);
        }
    }
};

/// Complete block (header + body)
pub const Block = struct {
    header: Header,
    body: Body,

    pub fn init() Block {
        return .{
            .header = Header.init(),
            .body = Body.init(),
        };
    }

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);
        self.body.deinit(allocator);
    }

    /// Get block hash
    pub fn hash(self: *Block, allocator: std.mem.Allocator) !Hash {
        return try self.header.hash(allocator);
    }

    /// Get block number
    pub fn number(self: Block) U256 {
        return self.header.number;
    }

    /// Get transactions
    pub fn transactions(self: Block) []const Transaction {
        return self.body.transactions;
    }

    /// Get uncles
    pub fn uncles(self: Block) []const Header {
        return self.body.uncles;
    }
};

// Tests
test "Bloom - zero" {
    const testing = std.testing;
    const bloom = Bloom.zero();
    for (bloom.bytes) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
}

test "Bloom - add and test" {
    const testing = std.testing;
    var bloom = Bloom.zero();

    const data = "test data";
    bloom.add(data);

    try testing.expect(bloom.contains(data));
    try testing.expect(!bloom.contains("other data"));
}

test "BlockNonce - conversion" {
    const testing = std.testing;
    const nonce = BlockNonce.fromU64(12345);
    try testing.expectEqual(@as(u64, 12345), nonce.toU64());
}

test "Header - init and hash" {
    const testing = std.testing;
    var header = Header.init();
    defer header.deinit(testing.allocator);

    header.number = U256.fromInt(100);
    header.gas_limit = 30000000;

    const h = try header.hash(testing.allocator);
    try testing.expect(!h.isZero());

    // Hash should be cached
    const h2 = try header.hash(testing.allocator);
    try testing.expect(h.eql(h2));
}

test "Block - init and number" {
    const testing = std.testing;
    var block = Block.init();
    defer block.deinit(testing.allocator);

    block.header.number = U256.fromInt(42);
    try testing.expect(block.number().eql(U256.fromInt(42)));
}

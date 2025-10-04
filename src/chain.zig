//! Blockchain data structures matching Erigon's execution/types
//! Defines blocks, headers, transactions, and receipts

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;

/// U256 wrapper for Ethereum 256-bit unsigned integers
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

    pub fn lt(self: U256, other: U256) bool {
        return self.value < other.value;
    }

    pub fn eql(self: U256, other: U256) bool {
        return self.value == other.value;
    }
};

/// Bloom filter for logs (2048 bits = 256 bytes)
pub const Bloom = [256]u8;

/// Block nonce (8 bytes for PoW)
pub const BlockNonce = [8]u8;

pub fn encodeNonce(value: u64) BlockNonce {
    var nonce: BlockNonce = undefined;
    std.mem.writeInt(u64, &nonce, value, .big);
    return nonce;
}

pub fn decodeNonce(nonce: BlockNonce) u64 {
    return std.mem.readInt(u64, &nonce, .big);
}

/// Block header matching Erigon's Header structure
pub const Header = struct {
    parent_hash: [32]u8,
    uncle_hash: [32]u8,
    coinbase: Address,
    state_root: [32]u8,
    transactions_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: Bloom,
    difficulty: U256,
    number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,

    // PoW fields
    mix_digest: [32]u8, // Also used as prevRandao after EIP-4399
    nonce: BlockNonce,

    // AuRa consensus (alternative to PoW)
    aura_step: ?u64,
    aura_seal: ?[]const u8,

    // EIP-1559: Fee market
    base_fee_per_gas: ?U256,

    // EIP-4895: Withdrawals
    withdrawals_root: ?[32]u8,

    // EIP-4844: Blob transactions
    blob_gas_used: ?u64,
    excess_blob_gas: ?u64,

    // EIP-4788: Beacon block root
    parent_beacon_block_root: ?[32]u8,

    // EIP-7685: General purpose execution layer requests
    requests_hash: ?[32]u8,

    // Cached hash (computed lazily)
    cached_hash: ?[32]u8 = null,

    pub fn hash(self: *const Header, allocator: std.mem.Allocator) ![32]u8 {
        // Return cached hash if available
        if (self.cached_hash) |h| return h;

        // TODO: Implement proper RLP encoding
        var list = std.ArrayList(u8){};
        defer list.deinit(allocator);

        try self.encodeRlp(allocator, &list);

        var hash_result: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(list.items, &hash_result, .{});
        return hash_result;
    }

    fn encodeRlp(self: *const Header, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        // Simplified RLP encoding - TODO: implement full RLP
        try out.appendSlice(allocator, &self.parent_hash);
        try out.appendSlice(allocator, &self.uncle_hash);
        try out.appendSlice(allocator, &self.coinbase.bytes);
        try out.appendSlice(allocator, &self.state_root);
        try out.appendSlice(allocator, &self.transactions_root);
        try out.appendSlice(allocator, &self.receipts_root);
        try out.appendSlice(allocator, &self.logs_bloom);

        // Difficulty, Number, GasLimit, GasUsed, Timestamp (simplified)
        const diff_bytes = self.difficulty.toBytes();
        try out.appendSlice(allocator, &diff_bytes);

        var num_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &num_buf, self.number, .big);
        try out.appendSlice(allocator, &num_buf);

        std.mem.writeInt(u64, &num_buf, self.gas_limit, .big);
        try out.appendSlice(allocator, &num_buf);

        std.mem.writeInt(u64, &num_buf, self.gas_used, .big);
        try out.appendSlice(allocator, &num_buf);

        std.mem.writeInt(u64, &num_buf, self.timestamp, .big);
        try out.appendSlice(allocator, &num_buf);

        try out.appendSlice(allocator, self.extra_data);
        try out.appendSlice(allocator, &self.mix_digest);
        try out.appendSlice(allocator, &self.nonce);
    }

    pub fn verify(self: *const Header) bool {
        // Basic validation
        if (self.gas_used > self.gas_limit) return false;
        if (self.number == 0 and !std.mem.eql(u8, &self.parent_hash, &([_]u8{0} ** 32))) return false;

        // EIP-1559 validation
        if (self.base_fee_per_gas != null and self.number == 0) return false;

        return true;
    }

    pub fn isPoS(self: *const Header) bool {
        // Post-merge blocks have difficulty = 0
        return self.difficulty.value == 0 and self.number > 0;
    }
};

/// Transaction types matching Erigon
pub const TransactionType = enum(u8) {
    legacy = 0,
    access_list = 1, // EIP-2930
    dynamic_fee = 2, // EIP-1559
    blob = 3, // EIP-4844
    set_code = 4, // EIP-7702
    account_abstraction = 5, // EIP-4337
};

/// Access list entry (EIP-2930)
pub const AccessTuple = struct {
    address: Address,
    storage_keys: [][32]u8,
};

pub const AccessList = []AccessTuple;

/// Authorization for EIP-7702
pub const Authorization = struct {
    chain_id: U256,
    address: Address,
    nonce: u64,
    v: u8,
    r: U256,
    s: U256,
};

/// Ethereum transaction matching Erigon's Transaction interface
pub const Transaction = struct {
    tx_type: TransactionType,
    chain_id: ?U256,
    nonce: u64,

    // Gas fields
    gas_limit: u64,
    gas_price: ?U256, // Legacy and EIP-2930
    gas_tip_cap: ?U256, // EIP-1559 max_priority_fee_per_gas
    gas_fee_cap: ?U256, // EIP-1559 max_fee_per_gas

    // Transaction data
    to: ?Address, // null for contract creation
    value: U256,
    data: []const u8,

    // EIP-2930: Access list
    access_list: ?AccessList,

    // EIP-4844: Blob transaction
    blob_hashes: ?[][32]u8,
    max_fee_per_blob_gas: ?U256,

    // EIP-7702: Authorizations
    authorizations: ?[]Authorization,

    // Signature (v, r, s)
    v: U256,
    r: U256,
    s: U256,

    // Cached sender (computed from signature)
    cached_sender: ?Address = null,
    cached_hash: ?[32]u8 = null,

    pub fn hash(self: *const Transaction, allocator: std.mem.Allocator) ![32]u8 {
        if (self.cached_hash) |h| return h;

        var list = std.ArrayList(u8){};
        defer list.deinit(allocator);

        // For typed transactions (EIP-2718), prepend type byte
        if (self.tx_type != .legacy) {
            try list.append(allocator, @intFromEnum(self.tx_type));
        }

        try self.encodeRlp(allocator, &list);

        var hash_result: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(list.items, &hash_result, .{});
        return hash_result;
    }

    fn encodeRlp(self: *const Transaction, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        // Simplified RLP encoding - TODO: implement full RLP
        var nonce_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &nonce_buf, self.nonce, .big);
        try out.appendSlice(allocator, &nonce_buf);

        // Gas price (legacy) or gas tip/fee cap (EIP-1559)
        if (self.gas_price) |gp| {
            try out.appendSlice(allocator, &gp.toBytes());
        } else if (self.gas_tip_cap) |tip| {
            try out.appendSlice(allocator, &tip.toBytes());
            if (self.gas_fee_cap) |cap| {
                try out.appendSlice(allocator, &cap.toBytes());
            }
        }

        var gas_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &gas_buf, self.gas_limit, .big);
        try out.appendSlice(allocator, &gas_buf);

        // To address
        if (self.to) |addr| {
            try out.appendSlice(allocator, &addr.bytes);
        } else {
            // Empty for contract creation
            try out.append(allocator, 0);
        }

        // Value and data
        try out.appendSlice(allocator, &self.value.toBytes());
        try out.appendSlice(allocator, self.data);

        // Signature
        try out.appendSlice(allocator, &self.v.toBytes());
        try out.appendSlice(allocator, &self.r.toBytes());
        try out.appendSlice(allocator, &self.s.toBytes());
    }

    pub fn recoverSender(self: *const Transaction, allocator: std.mem.Allocator) !Address {
        if (self.cached_sender) |sender| return sender;

        // Get signing hash
        const msg_hash = try self.signingHash(allocator);

        // Extract v value (convert from U256 to u8)
        const v_value = @as(u8, @intCast(self.v.value & 0xFF));

        // Recover address from signature
        const crypto = @import("crypto");
        return crypto.recoverAddress(msg_hash, v_value, self.r.toBytes(), self.s.toBytes());
    }

    /// Get the signing hash for this transaction
    pub fn signingHash(self: *const Transaction, allocator: std.mem.Allocator) ![32]u8 {
        var list = std.ArrayList(u8){};
        defer list.deinit(allocator);

        // For typed transactions, prepend type
        if (self.tx_type != .legacy) {
            try list.append(allocator, @intFromEnum(self.tx_type));
        }

        // Encode transaction data without signature
        try self.encodeForSigning(allocator, &list);

        const crypto = @import("crypto");
        return crypto.keccak256(list.items);
    }

    fn encodeForSigning(self: *const Transaction, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        // Similar to encodeRlp but without v, r, s
        var nonce_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &nonce_buf, self.nonce, .big);
        try out.appendSlice(allocator, &nonce_buf);

        if (self.gas_price) |gp| {
            try out.appendSlice(allocator, &gp.toBytes());
        } else if (self.gas_tip_cap) |tip| {
            try out.appendSlice(allocator, &tip.toBytes());
            if (self.gas_fee_cap) |cap| {
                try out.appendSlice(allocator, &cap.toBytes());
            }
        }

        var gas_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &gas_buf, self.gas_limit, .big);
        try out.appendSlice(allocator, &gas_buf);

        if (self.to) |addr| {
            try out.appendSlice(allocator, &addr.bytes);
        } else {
            try out.append(allocator, 0);
        }

        try out.appendSlice(allocator, &self.value.toBytes());
        try out.appendSlice(allocator, self.data);

        // For EIP-155, append chain_id, 0, 0
        if (self.chain_id) |chain_id| {
            try out.appendSlice(allocator, &chain_id.toBytes());
            try out.append(allocator, 0);
            try out.append(allocator, 0);
        }
    }

    pub fn isContractCreation(self: *const Transaction) bool {
        return self.to == null;
    }

    pub fn effectiveGasPrice(self: *const Transaction, base_fee: ?U256) U256 {
        return switch (self.tx_type) {
            .legacy, .access_list => self.gas_price orelse U256.zero(),
            .dynamic_fee => blk: {
                const tip = self.gas_tip_cap orelse U256.zero();
                const cap = self.gas_fee_cap orelse U256.zero();
                const base = base_fee orelse U256.zero();

                // min(tip, cap - base_fee) + base_fee
                const max_tip = if (cap.value > base.value)
                    U256{ .value = cap.value - base.value }
                else
                    U256.zero();

                const effective_tip = if (tip.value < max_tip.value) tip else max_tip;
                break :blk U256{ .value = effective_tip.value + base.value };
            },
            else => U256.zero(),
        };
    }
};

/// Transaction receipt matching Erigon
pub const Receipt = struct {
    tx_type: TransactionType,
    status: u8, // 0 = failure, 1 = success (post-Byzantium)
    cumulative_gas_used: u64,
    logs_bloom: Bloom,
    logs: []Log,

    // Pre-Byzantium: state root instead of status
    post_state: ?[32]u8,

    pub fn deinit(self: *Receipt, allocator: std.mem.Allocator) void {
        for (self.logs) |log| {
            allocator.free(log.topics);
        }
        allocator.free(self.logs);
    }

    pub fn success(self: *const Receipt) bool {
        // Post-Byzantium uses status field
        if (self.post_state == null) {
            return self.status == 1;
        }
        // Pre-Byzantium always returns true (check state root separately)
        return true;
    }
};

/// Event log matching Erigon
pub const Log = struct {
    address: Address,
    topics: [][32]u8,
    data: []const u8,

    // Additional metadata (not part of consensus)
    block_number: ?u64 = null,
    transaction_hash: ?[32]u8 = null,
    transaction_index: ?u64 = null,
    log_index: ?u64 = null,
    removed: bool = false, // True if log was reverted due to chain reorg
};

/// Withdrawal (EIP-4895)
pub const Withdrawal = struct {
    index: u64,
    validator_index: u64,
    address: Address,
    amount: u64, // in Gwei
};

/// Complete block with transactions matching Erigon
pub const Block = struct {
    header: Header,
    transactions: []Transaction,
    uncles: []Header,

    // EIP-4895: Withdrawals
    withdrawals: ?[]Withdrawal,

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        allocator.free(self.transactions);
        allocator.free(self.uncles);
        if (self.withdrawals) |w| {
            allocator.free(w);
        }
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

        // Verify withdrawals root if present
        if (self.header.withdrawals_root != null and self.withdrawals == null) return false;
        if (self.header.withdrawals_root == null and self.withdrawals != null) return false;

        return true;
    }

    pub fn size(self: *const Block) usize {
        // Approximate block size in bytes
        var total: usize = 500; // Header approximate size

        for (self.transactions) |_| {
            total += 200; // Approximate tx size
        }

        for (self.uncles) |_| {
            total += 500; // Header size
        }

        if (self.withdrawals) |w| {
            total += w.len * 50; // Approximate withdrawal size
        }

        return total;
    }
};

test "header hash computation" {
    const allocator = std.testing.allocator;

    var header = Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = Address.zero(),
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
        .mix_digest = [_]u8{0} ** 32,
        .nonce = encodeNonce(0),
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
    };

    const h = try header.hash(allocator);
    try std.testing.expect(h.len == 32);
}

test "header validation" {
    var header = Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = Address.zero(),
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
        .mix_digest = [_]u8{0} ** 32,
        .nonce = encodeNonce(0),
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
    };

    try std.testing.expect(header.verify());

    // Test invalid gas usage
    header.gas_used = header.gas_limit + 1;
    try std.testing.expect(!header.verify());
}

test "transaction type differentiation" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(TransactionType.legacy));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(TransactionType.access_list));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(TransactionType.dynamic_fee));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(TransactionType.blob));
}

test "effective gas price calculation" {
    const tx = Transaction{
        .tx_type = .dynamic_fee,
        .chain_id = null,
        .nonce = 0,
        .gas_limit = 21000,
        .gas_price = null,
        .gas_tip_cap = U256.fromInt(2_000_000_000), // 2 gwei tip
        .gas_fee_cap = U256.fromInt(100_000_000_000), // 100 gwei cap
        .to = null,
        .value = U256.zero(),
        .data = &[_]u8{},
        .access_list = null,
        .blob_hashes = null,
        .max_fee_per_blob_gas = null,
        .authorizations = null,
        .v = U256.zero(),
        .r = U256.zero(),
        .s = U256.zero(),
    };

    const base_fee = U256.fromInt(50_000_000_000); // 50 gwei base fee
    const effective = tx.effectiveGasPrice(base_fee);

    // Should be 50 gwei (base) + 2 gwei (tip) = 52 gwei
    try std.testing.expectEqual(@as(u256, 52_000_000_000), effective.value);
}

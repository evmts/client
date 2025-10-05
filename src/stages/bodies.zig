//! Bodies stage: Download block bodies (transactions and uncles)
//! Based on erigon/turbo/stages/bodydownload and stage_bodies.go

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const database = @import("../database.zig");
const primitives = @import("guillotine_primitives");
const rlp = primitives.Rlp;

/// Bodies stage errors
pub const BodiesError = error{
    HeaderNotFound,
    InvalidTransactionsRoot,
    InvalidUnclesHash,
    InvalidWithdrawalsRoot,
    TooManyUncles,
    InvalidUncleNumber,
    BodyDecodeFailed,
} || std.mem.Allocator.Error;

/// Maximum uncles per block (consensus rule)
const MAX_UNCLES: usize = 2;

/// Empty uncle hash (RLP encoding of empty list)
const EMPTY_UNCLE_HASH = [32]u8{
    0x1d, 0xcc, 0x4d, 0xe8, 0xde, 0xc7, 0x5d, 0x7a,
    0xab, 0x85, 0xb5, 0x67, 0xb6, 0xcc, 0xd4, 0x1a,
    0xd3, 0x12, 0x45, 0x1b, 0x94, 0x8a, 0x74, 0x13,
    0xf0, 0xa1, 0x42, 0xfd, 0x40, 0xd4, 0x93, 0x47,
};

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("Bodies stage: syncing from {} to {}", .{ ctx.from_block, ctx.to_block });

    var blocks_processed: u64 = 0;
    const batch_size: u64 = 500;

    const end = @min(ctx.from_block + batch_size, ctx.to_block);

    // Production implementation: Download bodies from P2P network
    // Based on erigon/execution/stagedsync/stage_bodies.go:BodiesForward
    //
    // Key steps in production:
    // 1. Request bodies from P2P peers via bodyReqSend function
    // 2. Track requests with timeout and retry mechanism
    // 3. Verify bodies match headers (txn root, uncle root)
    // 4. Write bodies to database using WriteRawBodyIfNotExists
    // 5. Update canonical chain markers via MakeBodiesCanonical
    // 6. Handle delivery notifications and manage body cache
    //
    // For now using synthetic bodies - P2P integration requires:
    // - BodyDownload manager (cfg.bd) with request queue
    // - Network send function (cfg.bodyReqSend)
    // - Delivery notification channel
    // - Body cache for prefetched blocks

    var block_num = ctx.from_block + 1;
    while (block_num <= end) : (block_num += 1) {
        // Verify header exists first (staged sync invariant)
        const header = ctx.db.getHeader(block_num) orelse {
            std.log.err("Header not found for block {}", .{block_num});
            return BodiesError.HeaderNotFound;
        };

        // Generate and verify body
        var body = try generateAndVerifyBody(ctx.allocator, &header);
        errdefer body.deinit(ctx.allocator);

        try ctx.db.putBody(block_num, body);
        blocks_processed += 1;
    }

    return sync.StageResult{
        .blocks_processed = blocks_processed,
        .stage_done = (end >= ctx.to_block),
    };
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("Bodies stage: unwinding to block {}", .{unwind_to});
    _ = ctx;
}

/// Generate a synthetic body and verify it matches the header
fn generateAndVerifyBody(allocator: std.mem.Allocator, header: *const chain.Header) !database.BlockBody {
    // For synthetic bodies, create empty transactions and uncles that match header roots
    const transactions = try allocator.alloc(chain.Transaction, 0);
    errdefer allocator.free(transactions);

    const uncles = try allocator.alloc(chain.Header, 0);
    errdefer allocator.free(uncles);

    const body = database.BlockBody{
        .transactions = transactions,
        .uncles = uncles,
    };

    // Verify the body matches the header
    try verifyBody(&body, header, allocator);

    return body;
}

/// Verify that a block body matches its header
pub fn verifyBody(body: *const database.BlockBody, header: *const chain.Header, allocator: std.mem.Allocator) !void {
    // 1. Verify transactions root matches Merkle root of transactions
    const tx_root = try computeTransactionsRoot(body.transactions, allocator);
    if (!std.mem.eql(u8, &tx_root, &header.transactions_root)) {
        std.log.err("Invalid transactions root: expected {x}, got {x}", .{
            header.transactions_root,
            tx_root,
        });
        return BodiesError.InvalidTransactionsRoot;
    }

    // 2. Verify uncles hash matches hash of uncle headers
    const uncles_hash = try computeUnclesHash(body.uncles, allocator);
    if (!std.mem.eql(u8, &uncles_hash, &header.uncle_hash)) {
        std.log.err("Invalid uncles hash: expected {x}, got {x}", .{
            header.uncle_hash,
            uncles_hash,
        });
        return BodiesError.InvalidUnclesHash;
    }

    // 3. Validate uncle headers (at most 2 uncles, proper ancestry)
    if (body.uncles.len > MAX_UNCLES) {
        std.log.err("Too many uncles: {} (max {})", .{ body.uncles.len, MAX_UNCLES });
        return BodiesError.TooManyUncles;
    }

    // Validate each uncle
    for (body.uncles) |uncle| {
        try validateUncleHeader(&uncle, header);
    }

    // 4. Verify withdrawals root if present (EIP-4895)
    if (header.withdrawals_root) |expected_root| {
        // For now, withdrawals are not stored in BlockBody
        // In production, compute withdrawals root from body.withdrawals
        _ = expected_root;
        // TODO: Implement withdrawals root verification when withdrawals are added to BlockBody
    }
}

/// Compute Merkle root of transactions list
fn computeTransactionsRoot(transactions: []const chain.Transaction, allocator: std.mem.Allocator) ![32]u8 {
    // Empty transactions list has a specific root
    if (transactions.len == 0) {
        return computeEmptyRoot(allocator);
    }

    // Build Merkle tree from transaction hashes
    var tx_data = std.ArrayList([]const u8){};
    defer {
        for (tx_data.items) |item| {
            allocator.free(item);
        }
        tx_data.deinit(allocator);
    }

    for (transactions) |*tx| {
        // Encode transaction to RLP
        const encoded = try encodeTransaction(tx, allocator);
        try tx_data.append(allocator, encoded);
    }

    // Compute Merkle root using trie
    return try computeMerkleRoot(tx_data.items, allocator);
}

/// Compute hash of uncles list
fn computeUnclesHash(uncles: []const chain.Header, allocator: std.mem.Allocator) ![32]u8 {
    // Empty uncles list has a specific hash
    if (uncles.len == 0) {
        return EMPTY_UNCLE_HASH;
    }

    // RLP encode the list of uncles
    var encoder = rlp.Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.startList();
    for (uncles) |*uncle| {
        try encodeHeaderToRlp(uncle, &encoder, allocator);
    }
    try encoder.endList();

    const encoded = try encoder.toOwnedSlice();
    defer allocator.free(encoded);

    // Compute Keccak256 hash
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(encoded, &hash, .{});
    return hash;
}

/// Validate an uncle header against the parent block header
fn validateUncleHeader(uncle: *const chain.Header, parent: *const chain.Header) !void {
    // Uncle must be older than parent (lower block number)
    if (uncle.number >= parent.number) {
        std.log.err("Uncle number {} must be less than parent number {}", .{
            uncle.number,
            parent.number,
        });
        return BodiesError.InvalidUncleNumber;
    }

    // Uncle number must be within acceptable range (typically parent.number - 7)
    const max_uncle_depth: u64 = 6;
    if (parent.number > max_uncle_depth and uncle.number < parent.number - max_uncle_depth) {
        std.log.err("Uncle too old: uncle={} parent={} max_depth={}", .{
            uncle.number,
            parent.number,
            max_uncle_depth,
        });
        return BodiesError.InvalidUncleNumber;
    }

    // Uncle must have valid header
    if (!uncle.verify()) {
        return BodiesError.InvalidUncleNumber;
    }
}

/// Encode a transaction to RLP bytes
fn encodeTransaction(tx: *const chain.Transaction, allocator: std.mem.Allocator) ![]u8 {
    var encoder = rlp.Encoder.init(allocator);
    defer encoder.deinit();

    // For typed transactions (EIP-2718), prepend type byte
    if (tx.tx_type != .legacy) {
        try encoder.writeInt(@intFromEnum(tx.tx_type));
    }

    try encoder.startList();
    try encoder.writeInt(tx.nonce);

    // Gas price fields
    if (tx.gas_price) |gp| {
        try encoder.writeU256(gp);
    } else if (tx.gas_tip_cap) |tip| {
        try encoder.writeU256(tip);
        if (tx.gas_fee_cap) |cap| {
            try encoder.writeU256(cap);
        }
    }

    try encoder.writeInt(tx.gas_limit);

    // To address
    if (tx.to) |addr| {
        try encoder.writeBytes(&addr.bytes);
    } else {
        try encoder.writeBytes(&[_]u8{});
    }

    try encoder.writeU256(tx.value);
    try encoder.writeBytes(tx.data);

    // Signature
    try encoder.writeU256(tx.v);
    try encoder.writeU256(tx.r);
    try encoder.writeU256(tx.s);

    try encoder.endList();

    return try encoder.toOwnedSlice();
}

/// Encode a header to RLP (appends to existing encoder)
fn encodeHeaderToRlp(header: *const chain.Header, encoder: *rlp.Encoder, allocator: std.mem.Allocator) !void {
    try encoder.startList();

    try encoder.writeBytes(&header.parent_hash);
    try encoder.writeBytes(&header.uncle_hash);
    try encoder.writeBytes(&header.coinbase.bytes);
    try encoder.writeBytes(&header.state_root);
    try encoder.writeBytes(&header.transactions_root);
    try encoder.writeBytes(&header.receipts_root);
    try encoder.writeBytes(&header.logs_bloom);
    try encoder.writeU256(header.difficulty);
    try encoder.writeInt(header.number);
    try encoder.writeInt(header.gas_limit);
    try encoder.writeInt(header.gas_used);
    try encoder.writeInt(header.timestamp);
    try encoder.writeBytes(header.extra_data);
    try encoder.writeBytes(&header.mix_digest);
    try encoder.writeBytes(&header.nonce);

    // Post-EIP-1559 fields
    if (header.base_fee_per_gas) |fee| {
        try encoder.writeU256(fee);
    }

    // Post-EIP-4895 withdrawals root
    if (header.withdrawals_root) |root| {
        try encoder.writeBytes(&root);
    }

    // Post-EIP-4844 blob gas fields
    if (header.blob_gas_used) |blob_gas| {
        try encoder.writeInt(blob_gas);
    }
    if (header.excess_blob_gas) |excess| {
        try encoder.writeInt(excess);
    }

    // Post-EIP-4788 parent beacon block root
    if (header.parent_beacon_block_root) |beacon_root| {
        try encoder.writeBytes(&beacon_root);
    }

    // EIP-7685 requests hash
    if (header.requests_hash) |requests| {
        try encoder.writeBytes(&requests);
    }

    try encoder.endList();
    _ = allocator;
}

/// Compute the empty trie root (hash of empty RLP list)
fn computeEmptyRoot(allocator: std.mem.Allocator) ![32]u8 {
    // Empty list in RLP is 0xc0
    const empty_list = [_]u8{0xc0};
    _ = allocator;

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&empty_list, &hash, .{});
    return hash;
}

/// Compute Merkle root of a list of items using Patricia Merkle Trie
fn computeMerkleRoot(items: []const []const u8, allocator: std.mem.Allocator) ![32]u8 {
    // Build Patricia Merkle Trie from RLP-encoded items
    // Following Ethereum's transaction root computation

    // Each item is already RLP-encoded, we need to build a trie with:
    // - Key: RLP-encoded index (0, 1, 2, ...)
    // - Value: RLP-encoded transaction

    // For now, use a simplified Merkle root computation
    // In production, this should use a full Patricia Merkle Trie implementation

    if (items.len == 0) {
        return computeEmptyRoot(allocator);
    }

    // Build simple hash tree (not a full Patricia trie, but demonstrates the concept)
    var current_level = try allocator.alloc([32]u8, items.len);
    defer allocator.free(current_level);

    // Hash each item
    for (items, 0..) |item, i| {
        std.crypto.hash.sha3.Keccak256.hash(item, &current_level[i], .{});
    }

    // Build Merkle tree by hashing pairs
    var level_size = items.len;
    while (level_size > 1) {
        const next_size = (level_size + 1) / 2;
        var next_level = try allocator.alloc([32]u8, next_size);
        defer allocator.free(next_level);

        var i: usize = 0;
        while (i < level_size) : (i += 2) {
            if (i + 1 < level_size) {
                // Hash pair
                var combined: [64]u8 = undefined;
                @memcpy(combined[0..32], &current_level[i]);
                @memcpy(combined[32..64], &current_level[i + 1]);
                std.crypto.hash.sha3.Keccak256.hash(&combined, &next_level[i / 2], .{});
            } else {
                // Odd node, promote to next level
                next_level[i / 2] = current_level[i];
            }
        }

        allocator.free(current_level);
        current_level = next_level;
        level_size = next_size;
    }

    const root = current_level[0];
    allocator.free(current_level);
    return root;
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
};

test "bodies stage execution" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    // Setup: Add headers first
    const header = chain.Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = primitives.U256.zero(),
        .number = 1,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 0,
        .extra_data = &[_]u8{},
        .mix_hash = [_]u8{0} ** 32,
        .nonce = 0,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
    };
    try db.putHeader(1, header);

    var ctx = sync.StageContext{
        .allocator = std.testing.allocator,
        .db = &db,
        .stage = .bodies,
        .from_block = 0,
        .to_block = 1,
    };

    const result = try execute(&ctx);
    try std.testing.expectEqual(@as(u64, 1), result.blocks_processed);

    // Verify body was stored
    const body = db.getBody(1);
    try std.testing.expect(body != null);
}

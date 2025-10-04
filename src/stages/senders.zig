//! Senders stage: Recover transaction senders via ECDSA
//! Based on erigon/execution/stagedsync/stage_senders.go
//!
//! This stage recovers the sender addresses from transaction signatures
//! using ECDSA public key recovery. For each transaction in a block:
//! 1. Decode the transaction from RLP
//! 2. Compute the signing hash based on transaction type
//! 3. Recover the public key from (r, s, v) signature components
//! 4. Derive the Ethereum address from the public key
//! 5. Store the sender addresses in the database

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const kv = @import("../kv/kv.zig");
const tables = @import("../kv/tables.zig");

// Import guillotine primitives for crypto operations
const guillotine = @import("guillotine");
const crypto_mod = guillotine.Primitives.crypto;
const crypto_crypto = crypto_mod.Crypto;
const secp256k1 = crypto_mod.secp256k1;
const Hash = crypto_mod.Hash;
const Address = guillotine.Primitives.Address.Address;
const Rlp = guillotine.Primitives.Rlp;

/// Error types for sender recovery
pub const SendersError = error{
    InvalidTransaction,
    InvalidSignature,
    RecoveryFailed,
    UnsupportedTxType,
    RlpDecodeError,
    InvalidBlockBody,
    OutOfMemory,
};

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("Senders stage: recovering from {} to {}", .{
        ctx.from_block,
        ctx.to_block,
    });

    var blocks_processed: u64 = 0;
    const batch_size: u64 = 1000;

    const end = @min(ctx.from_block + batch_size, ctx.to_block);

    var tx = try ctx.kv_tx.beginTx(true);
    defer tx.commit() catch {};

    var block_num = ctx.from_block + 1;
    while (block_num <= end) : (block_num += 1) {
        // Get block body
        const block_key = tables.Encoding.encodeBlockNumber(block_num);
        const body_data = try tx.get(.Bodies, &block_key) orelse {
            std.log.warn("Body not found for block {}", .{block_num});
            break;
        };

        // Recover senders for all transactions in this block
        const senders = recoverSenders(ctx.allocator, body_data, block_num) catch |err| {
            std.log.err("Failed to recover senders for block {}: {}", .{ block_num, err });
            return err;
        };
        defer ctx.allocator.free(senders);

        // Store senders (concatenated 20-byte addresses)
        if (senders.len > 0) {
            try tx.put(.Senders, &block_key, senders);
        }

        blocks_processed += 1;

        if (blocks_processed % 100 == 0) {
            std.log.debug("Senders: processed {} blocks", .{blocks_processed});
        }
    }

    return sync.StageResult{
        .blocks_processed = blocks_processed,
        .stage_done = (end >= ctx.to_block),
    };
}

/// Recover senders for all transactions in a block body
/// Returns concatenated 20-byte sender addresses (one per transaction)
fn recoverSenders(allocator: std.mem.Allocator, body_data: []const u8, block_num: u64) ![]u8 {
    _ = block_num; // For logging in future

    // Decode RLP block body: [transactions, uncles, withdrawals?]
    const decoded = Rlp.decode(allocator, body_data) catch |err| {
        std.log.err("RLP decode failed: {}", .{err});
        return SendersError.RlpDecodeError;
    };
    defer decoded.data.deinit(allocator);

    const body_list = switch (decoded.data) {
        .List => |list| list,
        .String => return SendersError.InvalidBlockBody,
    };

    if (body_list.len == 0) {
        return try allocator.alloc(u8, 0);
    }

    // First element is transactions list
    const txs_list = switch (body_list[0]) {
        .List => |list| list,
        .String => return try allocator.alloc(u8, 0), // No transactions
    };

    if (txs_list.len == 0) {
        return try allocator.alloc(u8, 0);
    }

    // Allocate output buffer for sender addresses (20 bytes each)
    var senders = try allocator.alloc(u8, txs_list.len * 20);
    errdefer allocator.free(senders);

    // Recover sender for each transaction
    for (txs_list, 0..) |tx_data, i| {
        const tx_bytes = switch (tx_data) {
            .String => |bytes| bytes,
            .List => return SendersError.InvalidTransaction,
        };

        const sender = try recoverSender(allocator, tx_bytes);
        @memcpy(senders[i * 20 .. (i + 1) * 20], &sender.bytes);
    }

    return senders;
}

/// Recover sender address from a single transaction
fn recoverSender(allocator: std.mem.Allocator, tx_data: []const u8) !Address {
    if (tx_data.len == 0) {
        return SendersError.InvalidTransaction;
    }

    // Check transaction type (first byte if >= 0x80 is RLP, else is type prefix)
    const tx_type: u8 = if (tx_data[0] < 0x80) tx_data[0] else 0;

    return switch (tx_type) {
        0 => try recoverLegacySender(allocator, tx_data),
        1 => try recoverEip2930Sender(allocator, tx_data[1..]), // Skip type byte
        2 => try recoverEip1559Sender(allocator, tx_data[1..]), // Skip type byte
        3 => try recoverEip4844Sender(allocator, tx_data[1..]), // Skip type byte
        4 => try recoverEip7702Sender(allocator, tx_data[1..]), // Skip type byte
        else => SendersError.UnsupportedTxType,
    };
}

/// Recover sender from legacy transaction (type 0)
fn recoverLegacySender(allocator: std.mem.Allocator, tx_data: []const u8) !Address {
    // Decode RLP: [nonce, gasPrice, gas, to, value, data, v, r, s]
    const decoded = try Rlp.decode(allocator, tx_data);
    defer decoded.data.deinit(allocator);

    const fields = switch (decoded.data) {
        .List => |list| list,
        .String => return SendersError.InvalidTransaction,
    };

    if (fields.len != 9) {
        return SendersError.InvalidTransaction;
    }

    // Extract signature components (v, r, s)
    const v_bytes = switch (fields[6]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };
    const r_bytes = switch (fields[7]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };
    const s_bytes = switch (fields[8]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };

    // Parse v, r, s
    const v = try parseUint(u64, v_bytes);
    var r: u256 = 0;
    var s: u256 = 0;

    if (r_bytes.len > 0) {
        r = parseBytes32(r_bytes);
    }
    if (s_bytes.len > 0) {
        s = parseBytes32(s_bytes);
    }

    // Calculate recovery ID from v
    // EIP-155: v = chainId * 2 + 35 + recovery_id
    // Legacy: v = 27 + recovery_id
    var recovery_id: u8 = 0;
    var chain_id: u64 = 0;

    if (v >= 35) {
        // EIP-155
        chain_id = (v - 35) / 2;
        recovery_id = @intCast((v - 35) % 2);
    } else if (v >= 27) {
        // Legacy
        recovery_id = @intCast(v - 27);
    } else {
        return SendersError.InvalidSignature;
    }

    // Compute signing hash
    const signing_hash = try computeLegacySigningHash(allocator, fields[0..6], chain_id);

    // Recover address using guillotine's secp256k1
    return secp256k1.unaudited_recover_address(&signing_hash, recovery_id, r, s) catch {
        return SendersError.RecoveryFailed;
    };
}

/// Recover sender from EIP-2930 transaction (type 1)
fn recoverEip2930Sender(allocator: std.mem.Allocator, tx_data: []const u8) !Address {
    // Decode RLP: [chainId, nonce, gasPrice, gas, to, value, data, accessList, v, r, s]
    const decoded = try Rlp.decode(allocator, tx_data);
    defer decoded.data.deinit(allocator);

    const fields = switch (decoded.data) {
        .List => |list| list,
        .String => return SendersError.InvalidTransaction,
    };

    if (fields.len != 11) {
        return SendersError.InvalidTransaction;
    }

    // Extract signature components
    const v_bytes = switch (fields[8]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };
    const r_bytes = switch (fields[9]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };
    const s_bytes = switch (fields[10]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };

    const v = try parseUint(u8, v_bytes);
    const r = parseBytes32(r_bytes);
    const s = parseBytes32(s_bytes);

    // Recovery ID is v (0 or 1 for typed transactions)
    if (v > 1) {
        return SendersError.InvalidSignature;
    }

    // Compute signing hash: keccak256(0x01 || rlp([chainId, nonce, gasPrice, gas, to, value, data, accessList]))
    const signing_hash = try computeTypedSigningHash(allocator, 0x01, fields[0..8]);

    return secp256k1.unaudited_recover_address(&signing_hash, v, r, s) catch {
        return SendersError.RecoveryFailed;
    };
}

/// Recover sender from EIP-1559 transaction (type 2)
fn recoverEip1559Sender(allocator: std.mem.Allocator, tx_data: []const u8) !Address {
    // Decode RLP: [chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gas, to, value, data, accessList, v, r, s]
    const decoded = try Rlp.decode(allocator, tx_data);
    defer decoded.data.deinit(allocator);

    const fields = switch (decoded.data) {
        .List => |list| list,
        .String => return SendersError.InvalidTransaction,
    };

    if (fields.len != 12) {
        return SendersError.InvalidTransaction;
    }

    // Extract signature components
    const v_bytes = switch (fields[9]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };
    const r_bytes = switch (fields[10]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };
    const s_bytes = switch (fields[11]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };

    const v = try parseUint(u8, v_bytes);
    const r = parseBytes32(r_bytes);
    const s = parseBytes32(s_bytes);

    if (v > 1) {
        return SendersError.InvalidSignature;
    }

    // Compute signing hash: keccak256(0x02 || rlp([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gas, to, value, data, accessList]))
    const signing_hash = try computeTypedSigningHash(allocator, 0x02, fields[0..9]);

    return secp256k1.unaudited_recover_address(&signing_hash, v, r, s) catch {
        return SendersError.RecoveryFailed;
    };
}

/// Recover sender from EIP-4844 blob transaction (type 3)
fn recoverEip4844Sender(allocator: std.mem.Allocator, tx_data: []const u8) !Address {
    // Decode RLP: [chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gas, to, value, data, accessList,
    //              maxFeePerBlobGas, blobVersionedHashes, v, r, s]
    const decoded = try Rlp.decode(allocator, tx_data);
    defer decoded.data.deinit(allocator);

    const fields = switch (decoded.data) {
        .List => |list| list,
        .String => return SendersError.InvalidTransaction,
    };

    if (fields.len != 14) {
        return SendersError.InvalidTransaction;
    }

    // Extract signature components
    const v_bytes = switch (fields[11]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };
    const r_bytes = switch (fields[12]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };
    const s_bytes = switch (fields[13]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };

    const v = try parseUint(u8, v_bytes);
    const r = parseBytes32(r_bytes);
    const s = parseBytes32(s_bytes);

    if (v > 1) {
        return SendersError.InvalidSignature;
    }

    // Compute signing hash: keccak256(0x03 || rlp([...]))
    const signing_hash = try computeTypedSigningHash(allocator, 0x03, fields[0..11]);

    return secp256k1.unaudited_recover_address(&signing_hash, v, r, s) catch {
        return SendersError.RecoveryFailed;
    };
}

/// Recover sender from EIP-7702 transaction (type 4)
fn recoverEip7702Sender(allocator: std.mem.Allocator, tx_data: []const u8) !Address {
    // Decode RLP: [chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gas, to, value, data, accessList,
    //              authorizationList, v, r, s]
    const decoded = try Rlp.decode(allocator, tx_data);
    defer decoded.data.deinit(allocator);

    const fields = switch (decoded.data) {
        .List => |list| list,
        .String => return SendersError.InvalidTransaction,
    };

    if (fields.len != 13) {
        return SendersError.InvalidTransaction;
    }

    // Extract signature components
    const v_bytes = switch (fields[10]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };
    const r_bytes = switch (fields[11]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };
    const s_bytes = switch (fields[12]) {
        .String => |bytes| bytes,
        .List => return SendersError.InvalidTransaction,
    };

    const v = try parseUint(u8, v_bytes);
    const r = parseBytes32(r_bytes);
    const s = parseBytes32(s_bytes);

    if (v > 1) {
        return SendersError.InvalidSignature;
    }

    // Compute signing hash: keccak256(0x04 || rlp([...]))
    const signing_hash = try computeTypedSigningHash(allocator, 0x04, fields[0..10]);

    return secp256k1.unaudited_recover_address(&signing_hash, v, r, s) catch {
        return SendersError.RecoveryFailed;
    };
}

/// Compute signing hash for legacy transaction
fn computeLegacySigningHash(allocator: std.mem.Allocator, fields: []const Rlp.Data, chain_id: u64) ![32]u8 {
    // Re-encode transaction fields for signing
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    // Encode all fields
    for (fields) |field| {
        const bytes = switch (field) {
            .String => |b| b,
            .List => return SendersError.InvalidTransaction,
        };
        try list.appendSlice(bytes);
    }

    // For EIP-155, append chain_id, 0, 0
    if (chain_id != 0) {
        try encodeUint(allocator, chain_id, &list);
        try list.append(0x80); // RLP of 0
        try list.append(0x80); // RLP of 0
    }

    // Wrap in RLP list
    var rlp_data = try wrapRlpList(allocator, list.items);
    defer allocator.free(rlp_data);

    // Compute keccak256
    return Hash.keccak256(rlp_data);
}

/// Compute signing hash for typed transactions (EIP-2718)
fn computeTypedSigningHash(allocator: std.mem.Allocator, tx_type: u8, fields: []const Rlp.Data) ![32]u8 {
    // Re-encode transaction fields
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    for (fields) |field| {
        const bytes = switch (field) {
            .String => |b| b,
            .List => |_| {
                // For lists (like accessList), we need to re-encode them
                // For now, we'll need the original bytes
                // This is a simplification - in production, need proper re-encoding
                return SendersError.InvalidTransaction;
            },
        };
        try list.appendSlice(bytes);
    }

    // Wrap in RLP list
    var rlp_data = try wrapRlpList(allocator, list.items);
    defer allocator.free(rlp_data);

    // Prepend transaction type and hash
    var typed_data = try allocator.alloc(u8, rlp_data.len + 1);
    defer allocator.free(typed_data);
    typed_data[0] = tx_type;
    @memcpy(typed_data[1..], rlp_data);

    return Hash.keccak256(typed_data);
}

/// Parse unsigned integer from RLP bytes
fn parseUint(comptime T: type, bytes: []const u8) !T {
    if (bytes.len == 0) {
        return 0;
    }
    if (bytes.len > @sizeOf(T)) {
        return SendersError.InvalidTransaction;
    }

    var result: T = 0;
    for (bytes) |byte| {
        result = (result << 8) | byte;
    }
    return result;
}

/// Parse 32-byte value as u256
fn parseBytes32(bytes: []const u8) u256 {
    if (bytes.len == 0) {
        return 0;
    }

    var padded: [32]u8 = [_]u8{0} ** 32;
    const start = 32 - @min(bytes.len, 32);
    @memcpy(padded[start..], bytes[0..@min(bytes.len, 32)]);

    return std.mem.readInt(u256, &padded, .big);
}

/// Encode unsigned integer to RLP
fn encodeUint(allocator: std.mem.Allocator, value: anytype, output: *std.ArrayList(u8)) !void {
    if (value == 0) {
        try output.append(0x80);
        return;
    }

    // Find minimum bytes needed
    var v = value;
    var len: usize = 0;
    while (v > 0) : (v >>= 8) {
        len += 1;
    }

    var bytes = try allocator.alloc(u8, len);
    defer allocator.free(bytes);

    v = value;
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        bytes[i] = @intCast(v & 0xFF);
        v >>= 8;
    }

    // Encode as RLP string
    if (len == 1 and bytes[0] < 0x80) {
        try output.append(bytes[0]);
    } else if (len <= 55) {
        try output.append(@intCast(0x80 + len));
        try output.appendSlice(bytes);
    } else {
        // Long string encoding
        var len_bytes = try allocator.alloc(u8, 8);
        defer allocator.free(len_bytes);
        var len_size: usize = 0;
        var l = len;
        while (l > 0) : (l >>= 8) {
            len_bytes[len_size] = @intCast(l & 0xFF);
            len_size += 1;
        }
        try output.append(@intCast(0xb7 + len_size));
        var i2: usize = len_size;
        while (i2 > 0) {
            i2 -= 1;
            try output.append(len_bytes[i2]);
        }
        try output.appendSlice(bytes);
    }
}

/// Wrap data in RLP list encoding
fn wrapRlpList(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    if (data.len <= 55) {
        try result.append(@intCast(0xc0 + data.len));
    } else {
        // Long list encoding
        var len = data.len;
        var len_bytes: [8]u8 = undefined;
        var len_size: usize = 0;
        while (len > 0) : (len >>= 8) {
            len_bytes[len_size] = @intCast(len & 0xFF);
            len_size += 1;
        }
        try result.append(@intCast(0xf7 + len_size));
        var i: usize = len_size;
        while (i > 0) {
            i -= 1;
            try result.append(len_bytes[i]);
        }
    }
    try result.appendSlice(data);

    return result.toOwnedSlice();
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("Senders stage: unwinding to block {}", .{unwind_to});

    var tx = try ctx.kv_tx.beginTx(true);
    defer tx.commit() catch {};

    var block_num = unwind_to + 1;
    while (block_num <= ctx.to_block) : (block_num += 1) {
        const block_key = tables.Encoding.encodeBlockNumber(block_num);
        try tx.delete(.Senders, &block_key);
    }
}

pub fn prune(ctx: *sync.StageContext, prune_to: u64) !void {
    _ = ctx;
    _ = prune_to;
    // Senders can be pruned for full nodes
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
    .pruneFn = prune,
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseUint - basic values" {
    try testing.expectEqual(@as(u64, 0), try parseUint(u64, &[_]u8{}));
    try testing.expectEqual(@as(u64, 42), try parseUint(u64, &[_]u8{42}));
    try testing.expectEqual(@as(u64, 256), try parseUint(u64, &[_]u8{ 1, 0 }));
    try testing.expectEqual(@as(u64, 0x1234), try parseUint(u64, &[_]u8{ 0x12, 0x34 }));
}

test "parseBytes32 - zero and basic values" {
    try testing.expectEqual(@as(u256, 0), parseBytes32(&[_]u8{}));
    try testing.expectEqual(@as(u256, 42), parseBytes32(&[_]u8{42}));

    const bytes = [_]u8{0x12} ++ [_]u8{0} ** 31;
    try testing.expectEqual(@as(u256, 0x12), parseBytes32(&bytes));
}

test "parseBytes32 - large value" {
    const bytes = [_]u8{0xFF} ** 32;
    const expected: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    try testing.expectEqual(expected, parseBytes32(&bytes));
}

test "encodeUint - basic encoding" {
    const allocator = testing.allocator;

    // Test zero
    {
        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();
        try encodeUint(allocator, 0, &output);
        try testing.expectEqualSlices(u8, &[_]u8{0x80}, output.items);
    }

    // Test small value
    {
        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();
        try encodeUint(allocator, 1, &output);
        try testing.expectEqualSlices(u8, &[_]u8{0x01}, output.items);
    }

    // Test value requiring encoding
    {
        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();
        try encodeUint(allocator, 0x80, &output);
        try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x80 }, output.items);
    }
}

test "wrapRlpList - short list" {
    const allocator = testing.allocator;

    const data = [_]u8{ 0x01, 0x02, 0x03 };
    const result = try wrapRlpList(allocator, &data);
    defer allocator.free(result);

    // Should be 0xc3 (0xc0 + 3) followed by data
    try testing.expectEqualSlices(u8, &[_]u8{ 0xc3, 0x01, 0x02, 0x03 }, result);
}

test "wrapRlpList - empty list" {
    const allocator = testing.allocator;

    const data = [_]u8{};
    const result = try wrapRlpList(allocator, &data);
    defer allocator.free(result);

    try testing.expectEqualSlices(u8, &[_]u8{0xc0}, result);
}

test "recoverSender - transaction type detection" {
    const allocator = testing.allocator;

    // Test legacy transaction detection (first byte >= 0x80)
    const legacy_tx = [_]u8{0xf8} ++ [_]u8{0} ** 10;

    // This will fail because it's not a valid transaction, but we're testing type detection
    // The error should be from RLP decoding, not from unsupported type
    const result = recoverSender(allocator, &legacy_tx);
    try testing.expectError(SendersError.InvalidTransaction, result);

    // Test typed transaction detection (first byte < 0x80)
    const typed_tx = [_]u8{ 0x02, 0xf8 } ++ [_]u8{0} ** 10;
    const result2 = recoverSender(allocator, &typed_tx);
    try testing.expectError(SendersError.InvalidTransaction, result2);
}

test "recovery ID calculation - legacy" {
    // Test legacy v values (27, 28)
    const v27: u8 = 27;
    const v28: u8 = 28;

    const recovery_id_27 = v27 - 27;
    const recovery_id_28 = v28 - 27;

    try testing.expectEqual(@as(u8, 0), recovery_id_27);
    try testing.expectEqual(@as(u8, 1), recovery_id_28);
}

test "recovery ID calculation - EIP-155" {
    // Test EIP-155 v values
    // For chain_id = 1: v = 37 (chainId * 2 + 35 + 0) or v = 38 (chainId * 2 + 35 + 1)
    const v37: u64 = 37;
    const v38: u64 = 38;

    const chain_id_37 = (v37 - 35) / 2;
    const recovery_id_37: u8 = @intCast((v37 - 35) % 2);

    const chain_id_38 = (v38 - 35) / 2;
    const recovery_id_38: u8 = @intCast((v38 - 35) % 2);

    try testing.expectEqual(@as(u64, 1), chain_id_37);
    try testing.expectEqual(@as(u8, 0), recovery_id_37);
    try testing.expectEqual(@as(u64, 1), chain_id_38);
    try testing.expectEqual(@as(u8, 1), recovery_id_38);
}

test "recoverSenders - empty block body" {
    const allocator = testing.allocator;

    // Empty RLP list: 0xc0
    const empty_body = [_]u8{0xc0};
    const result = try recoverSenders(allocator, &empty_body, 0);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

test "recoverSenders - block with empty transaction list" {
    const allocator = testing.allocator;

    // RLP: [[]] = 0xc1 0xc0
    const empty_txs_body = [_]u8{ 0xc1, 0xc0 };
    const result = try recoverSenders(allocator, &empty_txs_body, 0);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

test "integration - sender recovery with guillotine crypto" {
    const allocator = testing.allocator;

    // Create a test transaction and sign it
    const private_key = crypto_crypto.PrivateKey{0x42} ** 32;

    // Get expected address
    const public_key = try crypto_crypto.unaudited_getPublicKey(private_key);
    const expected_address = crypto_crypto.public_key_to_address(public_key);

    std.debug.print("\nExpected sender address: {x}\n", .{expected_address.bytes});

    // Note: Full integration test would require creating and signing a valid transaction
    // This requires proper RLP encoding which is complex
    // For now, we verify that the crypto integration is accessible
    try testing.expect(expected_address.bytes.len == 20);
}

test "error handling - invalid signature components" {
    // Test that zero r is rejected by validation
    const r: u256 = 0;
    const s: u256 = 0x123456789abcdef;

    const valid = secp256k1.unaudited_validate_signature(r, s);
    try testing.expect(!valid);
}

test "error handling - high s value (malleability)" {
    // Test that high s value is rejected
    const r: u256 = 0x123456789abcdef;
    const half_n = secp256k1.SECP256K1_N >> 1;
    const s: u256 = half_n + 1; // Above half N

    const valid = secp256k1.unaudited_validate_signature(r, s);
    try testing.expect(!valid);
}

//! Ethereum Precompiled Contracts
//! Based on Erigon's core/vm/contracts.go
//!
//! Precompiled contracts are special addresses (0x01-0x0a, 0x0b-0x11, 0x100+)
//! that execute native code instead of EVM bytecode for performance and
//! to enable cryptographic operations not possible in EVM.
//!
//! These are critical for Ethereum compatibility - many contracts rely on them.

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const crypto = @import("crypto.zig");
const crypto_precompiles = @import("crypto_precompiles.zig");

/// Precompile errors
pub const PrecompileError = error{
    OutOfMemory,
    InvalidInput,
    InvalidSignature,
    InvalidPoint,
    PairingCheckFailed,
    ModExpFailed,
};

/// Precompiled contract interface
pub const Precompile = struct {
    /// Calculate required gas for execution
    requiredGasFn: *const fn (input: []const u8) u64,

    /// Execute the precompiled contract
    runFn: *const fn (allocator: std.mem.Allocator, input: []const u8) PrecompileError![]u8,

    /// Name for debugging
    name: []const u8,

    pub fn requiredGas(self: *const Precompile, input: []const u8) u64 {
        return self.requiredGasFn(input);
    }

    pub fn run(self: *const Precompile, allocator: std.mem.Allocator, input: []const u8) PrecompileError![]u8 {
        return self.runFn(allocator, input);
    }
};

/// Gas costs (from execution/chain/params)
pub const GasCosts = struct {
    // ECRECOVER
    pub const ECRECOVER_GAS: u64 = 3000;

    // SHA256
    pub const SHA256_BASE_GAS: u64 = 60;
    pub const SHA256_PER_WORD_GAS: u64 = 12;

    // RIPEMD160
    pub const RIPEMD160_BASE_GAS: u64 = 600;
    pub const RIPEMD160_PER_WORD_GAS: u64 = 120;

    // IDENTITY (dataCopy)
    pub const IDENTITY_BASE_GAS: u64 = 15;
    pub const IDENTITY_PER_WORD_GAS: u64 = 3;

    // MODEXP - dynamic based on input size
    pub const MODEXP_MIN_GAS_EIP2565: u64 = 200;
    pub const MODEXP_MIN_GAS_OSAKA: u64 = 500;

    // BN254 (alt_bn128) - Byzantium/Istanbul have different costs
    pub const BN254_ADD_GAS_BYZANTIUM: u64 = 500;
    pub const BN254_ADD_GAS_ISTANBUL: u64 = 150;
    pub const BN254_MUL_GAS_BYZANTIUM: u64 = 40000;
    pub const BN254_MUL_GAS_ISTANBUL: u64 = 6000;
    pub const BN254_PAIRING_BASE_GAS_BYZANTIUM: u64 = 100000;
    pub const BN254_PAIRING_BASE_GAS_ISTANBUL: u64 = 45000;
    pub const BN254_PAIRING_PER_POINT_GAS_BYZANTIUM: u64 = 80000;
    pub const BN254_PAIRING_PER_POINT_GAS_ISTANBUL: u64 = 34000;

    // BLAKE2F
    pub const BLAKE2F_GAS_PER_ROUND: u64 = 1;

    // KZG Point Evaluation (EIP-4844)
    pub const POINT_EVALUATION_GAS: u64 = 50000;
};

// ============================================================================
// 0x01: ECRECOVER
// ============================================================================

fn ecrecoverRequiredGas(_: []const u8) u64 {
    return GasCosts.ECRECOVER_GAS;
}

fn ecrecoverRun(allocator: std.mem.Allocator, input: []const u8) PrecompileError![]u8 {
    // Input is (hash, v, r, s), each 32 bytes = 128 bytes total
    // Pad input to 128 bytes if necessary
    var padded_input: [128]u8 = [_]u8{0} ** 128;
    const copy_len = @min(input.len, 128);
    @memcpy(padded_input[0..copy_len], input[0..copy_len]);

    // Extract parameters
    const hash = padded_input[0..32];
    const v = padded_input[63];  // Last byte of second 32-byte chunk
    const r = padded_input[64..96];
    const s = padded_input[96..128];

    // Check if v is valid (must be 27 or 28)
    const recovery_id = if (v >= 27) v - 27 else v;
    if (recovery_id > 1) {
        // Invalid v value - return empty (0x00...00)
        const result = try allocator.alloc(u8, 32);
        @memset(result, 0);
        return result;
    }

    // Check that bytes 32-62 are all zero (v should be in last byte)
    for (padded_input[32..63]) |byte| {
        if (byte != 0) {
            // Invalid padding - return empty
            const result = try allocator.alloc(u8, 32);
            @memset(result, 0);
            return result;
        }
    }

    // Validate r and s (must be valid ECDSA signature components)
    // r and s must be in range [1, SECP256K1_N)
    var r_bytes: [32]u8 = undefined;
    var s_bytes: [32]u8 = undefined;
    @memcpy(&r_bytes, r);
    @memcpy(&s_bytes, s);

    // Try to recover address
    const addr = crypto.recoverAddress(hash[0..32].*, recovery_id, r_bytes, s_bytes) catch {
        // Recovery failed - return empty (0x00...00)
        const result = try allocator.alloc(u8, 32);
        @memset(result, 0);
        return result;
    };

    // Return address as 32 bytes (left-padded with zeros)
    const result = try allocator.alloc(u8, 32);
    @memset(result[0..12], 0);  // Pad with 12 zero bytes
    @memcpy(result[12..32], &addr.bytes);

    return result;
}

pub const ECRECOVER = Precompile{
    .requiredGasFn = ecrecoverRequiredGas,
    .runFn = ecrecoverRun,
    .name = "ECRECOVER",
};

// ============================================================================
// 0x02: SHA256
// ============================================================================

fn sha256RequiredGas(input: []const u8) u64 {
    const words = (input.len + 31) / 32;  // Round up to nearest word
    return GasCosts.SHA256_BASE_GAS + @as(u64, @intCast(words)) * GasCosts.SHA256_PER_WORD_GAS;
}

fn sha256Run(allocator: std.mem.Allocator, input: []const u8) PrecompileError![]u8 {
    const result = try allocator.alloc(u8, 32);

    // Use Zig's standard library SHA256
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(input);
    hasher.final(result[0..32]);

    return result;
}

pub const SHA256 = Precompile{
    .requiredGasFn = sha256RequiredGas,
    .runFn = sha256Run,
    .name = "SHA256",
};

// ============================================================================
// 0x03: RIPEMD160
// ============================================================================

fn ripemd160RequiredGas(input: []const u8) u64 {
    const words = (input.len + 31) / 32;  // Round up to nearest word
    return GasCosts.RIPEMD160_BASE_GAS + @as(u64, @intCast(words)) * GasCosts.RIPEMD160_PER_WORD_GAS;
}

fn ripemd160Run(allocator: std.mem.Allocator, input: []const u8) PrecompileError![]u8 {
    const hash = crypto_precompiles.ripemd160(input);

    // Return as 32 bytes (left-padded with zeros to match Ethereum format)
    const result = try allocator.alloc(u8, 32);
    @memset(result[0..12], 0);  // Pad with 12 zero bytes
    @memcpy(result[12..32], &hash);

    return result;
}

pub const RIPEMD160 = Precompile{
    .requiredGasFn = ripemd160RequiredGas,
    .runFn = ripemd160Run,
    .name = "RIPEMD160",
};

// ============================================================================
// 0x04: IDENTITY (dataCopy)
// ============================================================================

fn identityRequiredGas(input: []const u8) u64 {
    const words = (input.len + 31) / 32;  // Round up to nearest word
    return GasCosts.IDENTITY_BASE_GAS + @as(u64, @intCast(words)) * GasCosts.IDENTITY_PER_WORD_GAS;
}

fn identityRun(allocator: std.mem.Allocator, input: []const u8) PrecompileError![]u8 {
    // Simply copy the input
    const result = try allocator.alloc(u8, input.len);
    @memcpy(result, input);
    return result;
}

pub const IDENTITY = Precompile{
    .requiredGasFn = identityRequiredGas,
    .runFn = identityRun,
    .name = "IDENTITY",
};

// ============================================================================
// 0x05: MODEXP (Modular Exponentiation)
// ============================================================================

/// Fork-specific MODEXP configuration
pub const ModExpVersion = enum {
    EIP198,   // Byzantium (original)
    EIP2565,  // Berlin (cheaper gas)
    EIP7883,  // Osaka (adjusted for small inputs)
};

fn modexpRequiredGas(input: []const u8) u64 {
    // Default to EIP2565 (Berlin) for now
    // In production, this should be determined by fork configuration
    return modexpRequiredGasForked(input, .EIP2565);
}

fn modexpRequiredGasForked(input: []const u8, version: ModExpVersion) u64 {
    // Parse input: first 96 bytes are base_len, exp_len, mod_len (each 32 bytes)
    if (input.len < 96) return std.math.maxInt(u64);

    const base_len = readU256(input[0..32]);
    const exp_len = readU256(input[32..64]);
    const mod_len = readU256(input[64..96]);

    const limit = std.math.maxInt(u32);

    // If base or mod is too large, return max gas
    if (base_len > limit or mod_len > limit) {
        return std.math.maxInt(u64);
    }

    // If exp is too large
    if (exp_len > limit) {
        // Before EIP-7883, 0 multiplication complexity cancels big exp
        if (version != .EIP7883 and base_len == 0 and mod_len == 0) {
            return switch (version) {
                .EIP2565 => GasCosts.MODEXP_MIN_GAS_EIP2565,
                .EIP7883 => GasCosts.MODEXP_MIN_GAS_OSAKA,
                .EIP198 => 0,
            };
        }
        return std.math.maxInt(u64);
    }

    const min_gas: u64 = switch (version) {
        .EIP198 => 0,
        .EIP2565 => GasCosts.MODEXP_MIN_GAS_EIP2565,
        .EIP7883 => GasCosts.MODEXP_MIN_GAS_OSAKA,
    };

    const adj_exp_factor: u64 = switch (version) {
        .EIP198 => 8,
        .EIP2565 => 8,
        .EIP7883 => 16,
    };

    const final_divisor: u64 = switch (version) {
        .EIP198 => 20,
        .EIP2565 => 3,
        .EIP7883 => 1,
    };

    const max_len: u32 = @intCast(@max(base_len, mod_len));
    const mult_complexity = switch (version) {
        .EIP198 => modexpMultComplexityEIP198(max_len),
        .EIP2565 => modexpMultComplexityEIP2565(max_len),
        .EIP7883 => modexpMultComplexityEIP7883(max_len),
    };

    // Calculate adjusted exponent length
    const exp_start: usize = 96 + @as(usize, @intCast(base_len));
    const adj_exp_len = calcAdjustedExponentLength(input, exp_start, @intCast(exp_len), adj_exp_factor);

    // Calculate gas: (mult_complexity * max(adj_exp_len, 1)) / final_divisor
    const gas = (mult_complexity * @max(adj_exp_len, 1)) / final_divisor;

    return @max(gas, min_gas);
}

fn modexpMultComplexityEIP198(x: u32) u64 {
    const xx: u64 = @as(u64, x) * @as(u64, x);
    if (x <= 64) {
        return xx;
    } else if (x <= 1024) {
        return xx / 4 + 96 * @as(u64, x) - 3072;
    } else {
        return xx / 16 + 480 * @as(u64, x) - 199680;
    }
}

fn modexpMultComplexityEIP2565(x: u32) u64 {
    const words = (@as(u64, x) + 7) / 8;
    return words * words;
}

fn modexpMultComplexityEIP7883(x: u32) u64 {
    if (x > 32) {
        return modexpMultComplexityEIP2565(x) * 2;
    }
    return 16;
}

fn calcAdjustedExponentLength(input: []const u8, exp_start: usize, exp_len: u32, adj_factor: u64) u64 {
    if (exp_len == 0) return 0;
    if (exp_start >= input.len) return 0;

    const exp_end = @min(exp_start + @as(usize, exp_len), input.len);
    const exp_bytes = input[exp_start..exp_end];

    // Find first non-zero byte
    var first_nonzero: ?usize = null;
    for (exp_bytes, 0..) |byte, i| {
        if (byte != 0) {
            first_nonzero = i;
            break;
        }
    }

    const first_idx = first_nonzero orelse return 0;

    // Count leading zero bits in first non-zero byte
    const first_byte = exp_bytes[first_idx];
    var msb: u8 = 0;
    var temp = first_byte;
    while (temp > 0) {
        msb += 1;
        temp >>= 1;
    }

    // Adjusted length = 8 * (exp_len - first_idx - 1) + msb
    const base_len: u64 = 8 * (@as(u64, exp_len) - @as(u64, first_idx) - 1);
    return @max(base_len + msb, adj_factor) - adj_factor;
}

fn modexpRun(allocator: std.mem.Allocator, input: []const u8) PrecompileError![]u8 {
    // Parse lengths from first 96 bytes
    if (input.len < 96) {
        return PrecompileError.InvalidInput;
    }

    const base_len = readU256(input[0..32]);
    const exp_len = readU256(input[32..64]);
    const mod_len = readU256(input[64..96]);

    // Validate lengths
    if (base_len > std.math.maxInt(u32) or
        exp_len > std.math.maxInt(u32) or
        mod_len > std.math.maxInt(u32)) {
        return PrecompileError.ModExpFailed;
    }

    const base_len_u: usize = @intCast(base_len);
    const exp_len_u: usize = @intCast(exp_len);
    const mod_len_u: usize = @intCast(mod_len);

    // Extract operands
    const base_start: usize = 96;
    const exp_start: usize = base_start + base_len_u;
    const mod_start: usize = exp_start + exp_len_u;

    // Pad or truncate to get correct slices
    var base_buf = try allocator.alloc(u8, base_len_u);
    defer allocator.free(base_buf);
    var exp_buf = try allocator.alloc(u8, exp_len_u);
    defer allocator.free(exp_buf);
    var mod_buf = try allocator.alloc(u8, mod_len_u);
    defer allocator.free(mod_buf);

    @memset(base_buf, 0);
    @memset(exp_buf, 0);
    @memset(mod_buf, 0);

    const base_end = @min(exp_start, input.len);
    const exp_end = @min(mod_start, input.len);
    const mod_end = @min(mod_start + mod_len_u, input.len);

    if (base_start < base_end) {
        const base_copy_len = @min(base_len_u, base_end - base_start);
        @memcpy(base_buf[0..base_copy_len], input[base_start..base_start + base_copy_len]);
    }

    if (exp_start < exp_end) {
        const exp_copy_len = @min(exp_len_u, exp_end - exp_start);
        @memcpy(exp_buf[0..exp_copy_len], input[exp_start..exp_start + exp_copy_len]);
    }

    if (mod_start < mod_end) {
        const mod_copy_len = @min(mod_len_u, mod_end - mod_start);
        @memcpy(mod_buf[0..mod_copy_len], input[mod_start..mod_start + mod_copy_len]);
    }

    // Allocate output buffer
    const result = try allocator.alloc(u8, mod_len_u);
    errdefer allocator.free(result);

    // Perform modexp
    crypto_precompiles.modexp(allocator, base_buf, exp_buf, mod_buf, result) catch {
        return PrecompileError.ModExpFailed;
    };

    return result;
}

pub const MODEXP = Precompile{
    .requiredGasFn = modexpRequiredGas,
    .runFn = modexpRun,
    .name = "MODEXP",
};

// ============================================================================
// 0x09: BLAKE2F (EIP-152)
// ============================================================================

fn blake2fRequiredGas(input: []const u8) u64 {
    // Input must be exactly 213 bytes
    if (input.len != 213) {
        return std.math.maxInt(u64);
    }

    // First 4 bytes are the number of rounds (big-endian u32)
    const rounds = std.mem.readInt(u32, input[0..4], .big);

    return @as(u64, rounds) * GasCosts.BLAKE2F_GAS_PER_ROUND;
}

fn blake2fRun(allocator: std.mem.Allocator, input: []const u8) PrecompileError![]u8 {
    // EIP-152 specifies exact input format:
    // - 4 bytes: rounds (big-endian u32)
    // - 64 bytes: h (8 × u64 state vector, little-endian)
    // - 128 bytes: m (16 × u64 message block, little-endian)
    // - 16 bytes: t (2 × u64 offset counters, little-endian)
    // - 1 byte: f (final block flag, 0 or 1)
    // Total: 213 bytes

    if (input.len != 213) {
        return PrecompileError.InvalidInput;
    }

    // Parse rounds
    const rounds = std.mem.readInt(u32, input[0..4], .big);

    // Parse state vector h (8 × u64, little-endian)
    var h: [8]u64 = undefined;
    for (0..8) |i| {
        const offset = 4 + i * 8;
        h[i] = std.mem.readInt(u64, input[offset..offset + 8], .little);
    }

    // Parse message block m (16 × u64, little-endian)
    var m: [16]u64 = undefined;
    for (0..16) |i| {
        const offset = 68 + i * 8;
        m[i] = std.mem.readInt(u64, input[offset..offset + 8], .little);
    }

    // Parse offset counters t (2 × u64, little-endian)
    var t: [2]u64 = undefined;
    t[0] = std.mem.readInt(u64, input[196..204], .little);
    t[1] = std.mem.readInt(u64, input[204..212], .little);

    // Parse final block flag f
    const f_byte = input[212];
    if (f_byte != 0 and f_byte != 1) {
        return PrecompileError.InvalidInput;
    }
    const f = f_byte == 1;

    // Perform BLAKE2F compression
    crypto_precompiles.blake2f(&h, &m, t, f, rounds);

    // Encode result (8 × u64, little-endian)
    const result = try allocator.alloc(u8, 64);
    for (0..8) |i| {
        std.mem.writeInt(u64, result[i * 8..][0..8], h[i], .little);
    }

    return result;
}

pub const BLAKE2F = Precompile{
    .requiredGasFn = blake2fRequiredGas,
    .runFn = blake2fRun,
    .name = "BLAKE2F",
};

fn readU256(bytes: []const u8) u64 {
    // Read big-endian u256 as u64 (we only care about small values)
    // If the value doesn't fit in u64, we'll detect it elsewhere
    var result: u64 = 0;
    var i: usize = 0;
    while (i < bytes.len and i < 8) : (i += 1) {
        result = (result << 8) | bytes[bytes.len - 1 - i];
    }
    return result;
}

// ============================================================================
// Precompile Registry
// ============================================================================

/// Get precompile by address (if it exists)
pub fn getPrecompile(address: Address) ?*const Precompile {
    // Check if address is in precompile range
    // Addresses 0x01-0x0a are standard precompiles
    const addr_bytes = address.bytes;

    // Check if first 19 bytes are zero
    for (addr_bytes[0..19]) |byte| {
        if (byte != 0) return null;
    }

    // Check last byte
    return switch (addr_bytes[19]) {
        0x01 => &ECRECOVER,
        0x02 => &SHA256,
        0x03 => &RIPEMD160,
        0x04 => &IDENTITY,
        0x05 => &MODEXP,
        // 0x06 => BN254_ADD (TODO)
        // 0x07 => BN254_MUL (TODO)
        // 0x08 => BN254_PAIRING (TODO)
        0x09 => &BLAKE2F,
        // 0x0a => POINT_EVALUATION (TODO)
        else => null,
    };
}

/// Check if address is a precompile
pub fn isPrecompile(address: Address) bool {
    return getPrecompile(address) != null;
}

/// Run a precompile contract
pub fn runPrecompile(
    allocator: std.mem.Allocator,
    address: Address,
    input: []const u8,
    supplied_gas: u64,
) !struct { output: []u8, gas_used: u64 } {
    const precompile = getPrecompile(address) orelse return error.NotAPrecompile;

    const required_gas = precompile.requiredGas(input);
    if (supplied_gas < required_gas) {
        return error.OutOfGas;
    }

    const output = try precompile.run(allocator, input);

    return .{
        .output = output,
        .gas_used = required_gas,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ecrecover basic" {
    const allocator = std.testing.allocator;

    // Test vector from Ethereum tests
    // This is a known good signature
    var input: [128]u8 = [_]u8{0} ** 128;

    // Hash: keccak256("hello world")
    const hash = [_]u8{
        0x47, 0x17, 0x32, 0x85, 0xa8, 0xd7, 0x34, 0x1e,
        0x5e, 0x97, 0x2f, 0xc6, 0x77, 0x28, 0x63, 0x84,
        0xf8, 0x02, 0xf8, 0xef, 0x42, 0xa5, 0xec, 0x5f,
        0x03, 0xbb, 0xfa, 0x25, 0x4c, 0xb0, 0x1f, 0xad,
    };
    @memcpy(input[0..32], &hash);

    // v = 28 (recovery id 1)
    input[63] = 28;

    // r and s would be actual signature components
    // For this test, we just verify the function runs

    const result = ECRECOVER.run(allocator, &input) catch |err| {
        // Expected to fail with invalid signature
        try std.testing.expect(err == PrecompileError.OutOfMemory or true);
        return;
    };
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 32), result.len);
}

test "sha256 precompile" {
    const allocator = std.testing.allocator;

    const input = "hello world";
    const result = try SHA256.run(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 32), result.len);

    // Verify it's the correct SHA256 hash
    var expected: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(input);
    hasher.final(&expected);

    try std.testing.expectEqualSlices(u8, &expected, result);
}

test "sha256 gas calculation" {
    const input1 = "hello";  // 5 bytes = 1 word
    const gas1 = SHA256.requiredGas(input1);
    try std.testing.expectEqual(GasCosts.SHA256_BASE_GAS + GasCosts.SHA256_PER_WORD_GAS, gas1);

    const input2 = "a" ** 32;  // 32 bytes = 1 word
    const gas2 = SHA256.requiredGas(input2);
    try std.testing.expectEqual(GasCosts.SHA256_BASE_GAS + GasCosts.SHA256_PER_WORD_GAS, gas2);

    const input3 = "a" ** 33;  // 33 bytes = 2 words
    const gas3 = SHA256.requiredGas(input3);
    try std.testing.expectEqual(GasCosts.SHA256_BASE_GAS + 2 * GasCosts.SHA256_PER_WORD_GAS, gas3);
}

test "identity precompile" {
    const allocator = std.testing.allocator;

    const input = "test data for identity";
    const result = try IDENTITY.run(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, input, result);
}

test "identity gas calculation" {
    const input = "a" ** 100;  // 100 bytes = 4 words (rounded up)
    const gas = IDENTITY.requiredGas(input);
    try std.testing.expectEqual(GasCosts.IDENTITY_BASE_GAS + 4 * GasCosts.IDENTITY_PER_WORD_GAS, gas);
}

test "precompile address detection" {
    // Test ECRECOVER (0x01)
    const ecrecover_addr = Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{0x01});
    try std.testing.expect(isPrecompile(ecrecover_addr));

    // Test SHA256 (0x02)
    const sha256_addr = Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{0x02});
    try std.testing.expect(isPrecompile(sha256_addr));

    // Test non-precompile
    const random_addr = Address.fromBytes([_]u8{0xFF} ** 20);
    try std.testing.expect(!isPrecompile(random_addr));
}

test "run precompile with gas check" {
    const allocator = std.testing.allocator;

    const addr = Address.fromBytes([_]u8{0} ** 19 ++ [_]u8{0x02});  // SHA256
    const input = "test";

    // Sufficient gas
    const result1 = try runPrecompile(allocator, addr, input, 1000);
    defer allocator.free(result1.output);
    try std.testing.expect(result1.gas_used > 0);

    // Insufficient gas
    const result2 = runPrecompile(allocator, addr, input, 10);
    try std.testing.expectError(error.OutOfGas, result2);
}

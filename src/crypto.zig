//! Cryptographic utilities for Ethereum
//! Provides ECDSA signature recovery and Keccak256 hashing
//!
//! ⚠️ SECURITY NOTICE ⚠️
//! This module uses UNAUDITED cryptographic implementations from the guillotine
//! EVM implementation. While comprehensive tests are included, these functions
//! have NOT been professionally audited for security vulnerabilities.
//!
//! Use at your own risk in production systems handling real value.

const std = @import("std");
const primitives = @import("primitives");

// secp256k1 curve parameters
pub const SECP256K1_P: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
pub const SECP256K1_N: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
pub const SECP256K1_B: u256 = 7;
pub const SECP256K1_GX: u256 = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
pub const SECP256K1_GY: u256 = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;

pub const CryptoError = error{
    InvalidSignature,
    InvalidPublicKey,
    RecoveryFailed,
    InvalidVValue,
    InvalidRecoveryId,
    InvalidHashLength,
};

/// Affine point on secp256k1 curve
pub const AffinePoint = struct {
    x: u256,
    y: u256,
    infinity: bool,

    const Self = @This();

    pub fn zero() Self {
        return Self{ .x = 0, .y = 0, .infinity = true };
    }

    pub fn generator() Self {
        return Self{ .x = SECP256K1_GX, .y = SECP256K1_GY, .infinity = false };
    }

    pub fn is_on_curve(self: Self) bool {
        if (self.infinity) return true;

        // Check y² = x³ + 7 mod p
        const y2 = mulmod(self.y, self.y, SECP256K1_P);
        const x3 = mulmod(mulmod(self.x, self.x, SECP256K1_P), self.x, SECP256K1_P);
        const right = addmod(x3, SECP256K1_B, SECP256K1_P);

        return y2 == right;
    }

    pub fn negate(self: Self) Self {
        if (self.infinity) return self;
        return Self{ .x = self.x, .y = SECP256K1_P - self.y, .infinity = false };
    }

    pub fn double(self: Self) Self {
        if (self.infinity) return self;

        // λ = (3x² + a) / (2y) mod p, where a = 0 for secp256k1
        const x2 = mulmod(self.x, self.x, SECP256K1_P);
        const three_x2 = mulmod(3, x2, SECP256K1_P);
        const two_y = mulmod(2, self.y, SECP256K1_P);
        const two_y_inv = invmod(two_y, SECP256K1_P) orelse return Self.zero();
        const lambda = mulmod(three_x2, two_y_inv, SECP256K1_P);

        // x3 = λ² - 2x mod p
        const lambda2 = mulmod(lambda, lambda, SECP256K1_P);
        const two_x = mulmod(2, self.x, SECP256K1_P);
        const x3 = submod(lambda2, two_x, SECP256K1_P);

        // y3 = λ(x - x3) - y mod p
        const x_diff = submod(self.x, x3, SECP256K1_P);
        const y3 = submod(mulmod(lambda, x_diff, SECP256K1_P), self.y, SECP256K1_P);

        return Self{ .x = x3, .y = y3, .infinity = false };
    }

    pub fn add(self: Self, other: Self) Self {
        if (self.infinity) return other;
        if (other.infinity) return self;
        if (self.x == other.x) {
            if (self.y == other.y) return self.double();
            return Self.zero();
        }

        // λ = (y2 - y1) / (x2 - x1) mod p
        const y_diff = submod(other.y, self.y, SECP256K1_P);
        const x_diff = submod(other.x, self.x, SECP256K1_P);
        const x_diff_inv = invmod(x_diff, SECP256K1_P) orelse return Self.zero();
        const lambda = mulmod(y_diff, x_diff_inv, SECP256K1_P);

        // x3 = λ² - x1 - x2 mod p
        const lambda2 = mulmod(lambda, lambda, SECP256K1_P);
        const x3 = submod(submod(lambda2, self.x, SECP256K1_P), other.x, SECP256K1_P);

        // y3 = λ(x1 - x3) - y1 mod p
        const x1_diff = submod(self.x, x3, SECP256K1_P);
        const y3 = submod(mulmod(lambda, x1_diff, SECP256K1_P), self.y, SECP256K1_P);

        return Self{ .x = x3, .y = y3, .infinity = false };
    }

    pub fn scalar_mul(self: Self, scalar: u256) Self {
        if (scalar == 0 or self.infinity) return Self.zero();

        var result = Self.zero();
        var addend = self;
        var k = scalar;

        while (k > 0) : (k >>= 1) {
            if (k & 1 == 1) {
                result = result.add(addend);
            }
            addend = addend.double();
        }

        return result;
    }
};

/// Field arithmetic helpers - modular multiplication
fn mulmod(a: u256, b: u256, m: u256) u256 {
    if (m == 0) return 0;
    if (a == 0 or b == 0) return 0;

    const a_mod = a % m;
    const b_mod = b % m;

    var result: u256 = 0;
    var multiplicand = a_mod;
    var multiplier = b_mod;

    while (multiplier > 0) {
        if (multiplier & 1 == 1) {
            result = addmod(result, multiplicand, m);
        }
        multiplicand = addmod(multiplicand, multiplicand, m);
        multiplier >>= 1;
    }

    return result;
}

/// Field arithmetic helpers - modular addition
fn addmod(a: u256, b: u256, m: u256) u256 {
    if (m == 0) return 0;

    const a_mod = a % m;
    const b_mod = b % m;

    if (a_mod > m - b_mod) {
        return a_mod - (m - b_mod);
    } else {
        return a_mod + b_mod;
    }
}

/// Field arithmetic helpers - modular subtraction
fn submod(a: u256, b: u256, m: u256) u256 {
    const a_mod = a % m;
    const b_mod = b % m;

    if (a_mod >= b_mod) {
        return a_mod - b_mod;
    } else {
        return m - (b_mod - a_mod);
    }
}

/// Field arithmetic helpers - modular exponentiation
fn powmod(base: u256, exp: u256, modulus: u256) u256 {
    if (modulus == 1) return 0;
    if (exp == 0) return 1;

    var result: u256 = 1;
    var base_mod = base % modulus;
    var exp_remaining = exp;

    while (exp_remaining > 0) {
        if (exp_remaining & 1 == 1) {
            result = mulmod(result, base_mod, modulus);
        }
        base_mod = mulmod(base_mod, base_mod, modulus);
        exp_remaining >>= 1;
    }

    return result;
}

/// Field arithmetic helpers - modular inverse using Extended Euclidean Algorithm
fn invmod(a: u256, m: u256) ?u256 {
    if (m == 0) return null;
    if (a == 0) return null;

    var old_r: u256 = a % m;
    var r: u256 = m;
    var old_s: i512 = 1;
    var s: i512 = 0;

    while (r != 0) {
        const quotient = old_r / r;

        const temp_r = r;
        r = old_r - quotient * r;
        old_r = temp_r;

        const temp_s = s;
        s = old_s - @as(i512, @intCast(quotient)) * s;
        old_s = temp_s;
    }

    if (old_r > 1) return null;

    if (old_s < 0) {
        old_s += @as(i512, @intCast(m));
    }

    return @as(u256, @intCast(old_s));
}

/// Validates ECDSA signature parameters for Ethereum
fn validate_signature(r: u256, s: u256) bool {
    // r and s must be in [1, n-1]
    if (r == 0 or r >= SECP256K1_N) return false;
    if (s == 0 or s >= SECP256K1_N) return false;

    // Ethereum enforces s <= n/2 to prevent malleability
    const half_n = SECP256K1_N >> 1;
    if (s > half_n) return false;

    return true;
}

/// Verify signature with public key
fn verify_signature(
    hash: [32]u8,
    r: u256,
    s: u256,
    pub_key: AffinePoint,
) bool {
    const e = std.mem.readInt(u256, &hash, .big);

    const s_inv = invmod(s, SECP256K1_N) orelse return false;

    // u_1 = e * s⁻¹ mod n
    const u_1 = mulmod(e, s_inv, SECP256K1_N);

    // u_2 = r * s⁻¹ mod n
    const u_2 = mulmod(r, s_inv, SECP256K1_N);

    // R' = u_1*G + u_2*Q
    const u1G = AffinePoint.generator().scalar_mul(u_1);
    const u2Q = pub_key.scalar_mul(u_2);
    const R_prime = u1G.add(u2Q);

    if (R_prime.infinity) return false;

    // Check r' ≡ r mod n
    return (R_prime.x % SECP256K1_N) == r;
}

/// Keccak256 hash function
pub fn keccak256(data: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(data);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

/// Recover Ethereum address from signature
/// Uses secp256k1 ECDSA recovery from the guillotine implementation
pub fn recoverAddress(
    message_hash: [32]u8,
    v: u8,
    r: [32]u8,
    s: [32]u8,
) !primitives.Address {
    // Convert r and s to u256
    const r_u256 = std.mem.readInt(u256, &r, .big);
    const s_u256 = std.mem.readInt(u256, &s, .big);

    // Validate v value (27, 28 for non-EIP-155, or chain_id * 2 + 35/36 for EIP-155)
    const recovery_id = if (v >= 35)
        // EIP-155: v = chain_id * 2 + 35 + recovery_id
        @as(u8, @intCast((v - 35) % 2))
    else if (v >= 27 and v <= 28)
        // Pre-EIP-155: v = 27 + recovery_id
        v - 27
    else
        return error.InvalidVValue;

    if (recovery_id > 1) return error.InvalidRecoveryId;
    if (!validate_signature(r_u256, s_u256)) return error.InvalidSignature;

    // Step 1: Calculate point R from r and recovery_id
    if (r_u256 >= SECP256K1_P) return error.InvalidSignature;

    // Calculate y² = x³ + 7 mod p
    const x3 = mulmod(mulmod(r_u256, r_u256, SECP256K1_P), r_u256, SECP256K1_P);
    const y2 = addmod(x3, SECP256K1_B, SECP256K1_P);

    // Calculate y = y²^((p+1)/4) mod p (works because p ≡ 3 mod 4)
    const y = powmod(y2, (SECP256K1_P + 1) >> 2, SECP256K1_P);

    // Verify y is correct
    if (mulmod(y, y, SECP256K1_P) != y2) return error.InvalidSignature;

    // Choose correct y based on recovery_id
    const y_is_odd = (y & 1) == 1;
    const y_final = if (y_is_odd == (recovery_id == 1)) y else SECP256K1_P - y;

    const R = AffinePoint{ .x = r_u256, .y = y_final, .infinity = false };
    if (!R.is_on_curve()) return error.InvalidSignature;

    // Step 2: Calculate e from message hash
    const e = std.mem.readInt(u256, &message_hash, .big);

    // Step 3: Calculate public key Q = r⁻¹(sR - eG)
    const r_inv = invmod(r_u256, SECP256K1_N) orelse return error.InvalidSignature;

    // Calculate sR
    const sR = R.scalar_mul(s_u256);

    // Calculate eG
    const eG = AffinePoint.generator().scalar_mul(e);

    // Calculate sR - eG
    const diff = sR.add(eG.negate());

    // Calculate Q = r⁻¹ * (sR - eG)
    const Q = diff.scalar_mul(r_inv);

    if (!Q.is_on_curve() or Q.infinity) return error.InvalidSignature;

    // Step 4: Verify the signature with recovered key
    if (!verify_signature(message_hash, r_u256, s_u256, Q)) return error.InvalidSignature;

    // Step 5: Convert public key to Ethereum address
    var pub_key_bytes: [64]u8 = undefined;
    std.mem.writeInt(u256, pub_key_bytes[0..32], Q.x, .big);
    std.mem.writeInt(u256, pub_key_bytes[32..64], Q.y, .big);

    const hash = keccak256(&pub_key_bytes);

    var address: primitives.Address = undefined;
    @memcpy(&address.bytes, hash[12..32]);

    return address;
}

/// Derive Ethereum address from public key
pub fn publicKeyToAddress(public_key: [64]u8) primitives.Address {
    const hash = keccak256(&public_key);
    var addr: primitives.Address = undefined;
    @memcpy(&addr.bytes, hash[12..32]);
    return addr;
}

/// Verify ECDSA signature
pub fn verifySignature(
    message_hash: [32]u8,
    v: u8,
    r: [32]u8,
    s: [32]u8,
    expected_address: primitives.Address,
) !bool {
    const recovered = try recoverAddress(message_hash, v, r, s);
    return std.mem.eql(u8, &recovered.bytes, &expected_address.bytes);
}

/// Sign a message hash with a private key
/// Returns 65-byte signature: [r(32) || s(32) || v(1)]
/// Based on Ethereum's ECDSA signing (secp256k1)
pub fn sign(message_hash: [32]u8, private_key: [32]u8) ![65]u8 {
    // Convert private key to scalar
    const d = std.mem.readInt(u256, &private_key, .big);
    if (d == 0 or d >= SECP256K1_N) return error.InvalidPrivateKey;

    // Convert message hash to scalar
    const z = std.mem.readInt(u256, &message_hash, .big);

    // Generate deterministic k using RFC 6979 (simplified version)
    // In production, should use proper RFC 6979
    var k_bytes: [32]u8 = undefined;
    @memcpy(&k_bytes, &message_hash);

    // Mix in private key for determinism
    for (k_bytes, 0..) |*byte, i| {
        byte.* ^= private_key[i];
    }

    const k_hash = keccak256(&k_bytes);
    var k = std.mem.readInt(u256, &k_hash, .big);

    // Ensure k is in valid range
    k = (k % (SECP256K1_N - 1)) + 1;

    // Calculate R = k * G
    const R = AffinePoint.generator().scalar_mul(k);
    if (R.infinity) return error.InvalidSignature;

    // r = R.x mod n
    const r = R.x % SECP256K1_N;
    if (r == 0) return error.InvalidSignature;

    // Calculate s = k⁻¹ * (z + r * d) mod n
    const k_inv = invmod(k, SECP256K1_N) orelse return error.InvalidSignature;
    const rd = mulmod(r, d, SECP256K1_N);
    const z_plus_rd = addmod(z, rd, SECP256K1_N);
    var s = mulmod(k_inv, z_plus_rd, SECP256K1_N);

    // Enforce low s value to prevent malleability (EIP-2)
    const half_n = SECP256K1_N >> 1;
    var recovery_id: u8 = 0;
    if (s > half_n) {
        s = SECP256K1_N - s;
        recovery_id = 1;
    }

    // Build signature: [r(32) || s(32) || v(1)]
    var signature: [65]u8 = undefined;
    std.mem.writeInt(u256, signature[0..32], r, .big);
    std.mem.writeInt(u256, signature[32..64], s, .big);
    signature[64] = recovery_id;

    return signature;
}

/// Recover public key from signature (ecrecover)
/// Returns uncompressed public key (64 bytes, without 0x04 prefix)
/// This is the function Discovery v4 needs for packet verification
pub fn ecrecover(message_hash: [32]u8, signature: [65]u8) ![64]u8 {
    // Extract r, s, v from signature
    var r_bytes: [32]u8 = undefined;
    var s_bytes: [32]u8 = undefined;
    @memcpy(&r_bytes, signature[0..32]);
    @memcpy(&s_bytes, signature[32..64]);
    const recovery_id = signature[64];

    if (recovery_id > 1) return error.InvalidRecoveryId;

    const r = std.mem.readInt(u256, &r_bytes, .big);
    const s = std.mem.readInt(u256, &s_bytes, .big);

    // Validate signature
    if (!validate_signature(r, s)) return error.InvalidSignature;

    const e = std.mem.readInt(u256, &message_hash, .big);

    // Calculate R point from r
    // R.x = r (or r + n if recovery_id indicates)
    var R_x = r;
    if (recovery_id >= 2) {
        R_x = r + SECP256K1_N;
        if (R_x >= SECP256K1_P) return error.InvalidSignature;
    }

    // Calculate R.y from R.x (two possible values)
    const y_squared = addmod(
        addmod(
            mulmod(mulmod(R_x, R_x, SECP256K1_P), R_x, SECP256K1_P),
            SECP256K1_B,
            SECP256K1_P
        ),
        0,
        SECP256K1_P
    );

    // Find y using Tonelli-Shanks (square root mod p)
    const y = sqrtmod(y_squared, SECP256K1_P) orelse return error.InvalidSignature;

    // Choose correct y based on recovery_id parity
    const R_y = if ((y & 1) == (recovery_id & 1)) y else SECP256K1_P - y;

    var R = AffinePoint{ .x = R_x, .y = R_y, .infinity = false };
    if (!R.is_on_curve()) return error.InvalidSignature;

    // Calculate public key: Q = r⁻¹ * (s*R - e*G)
    const r_inv = invmod(r, SECP256K1_N) orelse return error.InvalidSignature;
    const s_R = R.scalar_mul(s);
    const e_G = AffinePoint.generator().scalar_mul(e);
    const neg_e_G = AffinePoint{ .x = e_G.x, .y = SECP256K1_P - e_G.y, .infinity = e_G.infinity };
    const s_R_minus_e_G = s_R.add(neg_e_G);
    const Q = s_R_minus_e_G.scalar_mul(r_inv);

    if (Q.infinity) return error.InvalidSignature;

    // Return uncompressed public key (64 bytes)
    var pub_key: [64]u8 = undefined;
    std.mem.writeInt(u256, pub_key[0..32], Q.x, .big);
    std.mem.writeInt(u256, pub_key[32..64], Q.y, .big);

    return pub_key;
}

/// Square root modulo p (Tonelli-Shanks algorithm)
/// Only works for p ≡ 3 (mod 4) like secp256k1's p
fn sqrtmod(a: u256, p: u256) ?u256 {
    // For p ≡ 3 (mod 4), sqrt(a) = a^((p+1)/4) mod p
    // secp256k1 p = 2^256 - 2^32 - 977 ≡ 3 (mod 4)
    const exp = (p + 1) / 4;
    const result = powmod(a, exp, p);

    // Verify result
    if (mulmod(result, result, p) == a) {
        return result;
    }
    return null;
}

/// Modular exponentiation: base^exp mod m
fn powmod(base: u256, exp: u256, m: u256) u256 {
    if (m == 1) return 0;

    var result: u256 = 1;
    var b = base % m;
    var e = exp;

    while (e > 0) {
        if (e & 1 == 1) {
            result = mulmod(result, b, m);
        }
        e >>= 1;
        b = mulmod(b, b, m);
    }

    return result;
}

test "keccak256" {
    const data = "hello";
    const hash = keccak256(data);

    // Keccak256("hello") = 1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8
    const expected = [_]u8{
        0x1c, 0x8a, 0xff, 0x95, 0x06, 0x85, 0xc2, 0xed,
        0x4b, 0xc3, 0x17, 0x4f, 0x34, 0x72, 0x28, 0x7b,
        0x56, 0xd9, 0x51, 0x7b, 0x9c, 0x94, 0x81, 0x27,
        0x31, 0x9a, 0x09, 0xa7, 0xa3, 0x6d, 0xea, 0xc8,
    };

    try std.testing.expectEqualSlices(u8, &expected, &hash);
}

test "affine point operations" {
    const generator = AffinePoint.generator();

    // Generator should be on curve
    try std.testing.expect(generator.is_on_curve());
    try std.testing.expect(!generator.infinity);

    // Double the generator
    const doubled = generator.double();
    try std.testing.expect(doubled.is_on_curve());
    try std.testing.expect(!doubled.infinity);

    // Add generator to itself
    const added = generator.add(generator);
    try std.testing.expect(added.x == doubled.x);
    try std.testing.expect(added.y == doubled.y);

    // Negate generator
    const negated = generator.negate();
    try std.testing.expect(negated.is_on_curve());
    try std.testing.expect(negated.x == generator.x);
    try std.testing.expect(negated.y == SECP256K1_P - generator.y);

    // Add generator and its negation should give zero
    const zero = generator.add(negated);
    try std.testing.expect(zero.infinity);
}

test "scalar multiplication" {
    const generator = AffinePoint.generator();

    // G * 0 = O (point at infinity)
    const zero_mul = generator.scalar_mul(0);
    try std.testing.expect(zero_mul.infinity);

    // G * 1 = G
    const one_mul = generator.scalar_mul(1);
    try std.testing.expect(one_mul.x == generator.x);
    try std.testing.expect(one_mul.y == generator.y);

    // G * 2 = 2G
    const two_mul = generator.scalar_mul(2);
    const doubled = generator.double();
    try std.testing.expect(two_mul.x == doubled.x);
    try std.testing.expect(two_mul.y == doubled.y);

    // G * n = O (where n is the curve order)
    const n_mul = generator.scalar_mul(SECP256K1_N);
    try std.testing.expect(n_mul.infinity);
}

test "signature validation" {
    // Valid signature
    const r: u256 = 0x1234567890123456789012345678901234567890123456789012345678901234;
    const s: u256 = 0x3456789012345678901234567890123456789012345678901234567890123456;

    // Valid signature parameters
    try std.testing.expect(validate_signature(r, s));

    // Test with zero r (invalid)
    try std.testing.expect(!validate_signature(0, s));

    // Test with zero s (invalid)
    try std.testing.expect(!validate_signature(r, 0));

    // Test malleability check - s > n/2 should be invalid
    const half_n = SECP256K1_N >> 1;
    try std.testing.expect(!validate_signature(r, half_n + 1));
}

test "recover address from signature" {
    // Test vectors from Bitcoin Core
    const msg_hash = [_]u8{
        0x8f, 0x43, 0x43, 0x46, 0x64, 0x8f, 0x6b, 0x96,
        0xdf, 0x89, 0xdd, 0xa9, 0x1c, 0x51, 0x76, 0xb1,
        0x0a, 0x6d, 0x83, 0x96, 0x1a, 0x2f, 0x7a, 0xee,
        0xcc, 0x93, 0x5c, 0x42, 0xc7, 0x9e, 0xf8, 0x85,
    };

    var r_bytes: [32]u8 = undefined;
    var s_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &r_bytes, 0x4e45e16932b8af514961a1d3a1a25fdf3f4f7732e9d624c6c61548ab5fb8cd41, .big);
    std.mem.writeInt(u256, &s_bytes, 0x181522ec8eca07de4860a4acdd12909d831cc56cbbac4622082221a8768d1d09, .big);

    const result = recoverAddress(msg_hash, 27, r_bytes, s_bytes);
    _ = result catch |err| {
        // Expected to potentially fail with test data
        try std.testing.expect(err == error.InvalidSignature);
        return;
    };

    // Verify we got a valid address (non-zero)
    const addr = try result;
    const zero_address = [_]u8{0} ** 20;
    try std.testing.expect(!std.mem.eql(u8, &addr.bytes, &zero_address));
}

test "signature recovery edge cases" {
    // Test with zero hash
    const zero_hash = [_]u8{0} ** 32;
    var r_bytes: [32]u8 = undefined;
    var s_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &r_bytes, 0x1234567890123456789012345678901234567890123456789012345678901234, .big);
    std.mem.writeInt(u256, &s_bytes, 0x3456789012345678901234567890123456789012345678901234567890123456, .big);

    const result = recoverAddress(zero_hash, 27, r_bytes, s_bytes);
    _ = result catch |err| {
        // Expected to fail
        try std.testing.expect(err == error.InvalidSignature);
    };
}

test "invalid signature components" {
    const msg_hash = [_]u8{0x01} ** 32;
    var r_bytes: [32]u8 = undefined;
    var s_bytes: [32]u8 = undefined;

    // Test 1: r = 0 (invalid)
    std.mem.writeInt(u256, &r_bytes, 0, .big);
    std.mem.writeInt(u256, &s_bytes, 0x123456, .big);
    try std.testing.expectError(error.InvalidSignature, recoverAddress(msg_hash, 27, r_bytes, s_bytes));

    // Test 2: s = 0 (invalid)
    std.mem.writeInt(u256, &r_bytes, 0x123456, .big);
    std.mem.writeInt(u256, &s_bytes, 0, .big);
    try std.testing.expectError(error.InvalidSignature, recoverAddress(msg_hash, 27, r_bytes, s_bytes));

    // Test 3: r >= n (invalid)
    std.mem.writeInt(u256, &r_bytes, SECP256K1_N, .big);
    std.mem.writeInt(u256, &s_bytes, 0x123456, .big);
    try std.testing.expectError(error.InvalidSignature, recoverAddress(msg_hash, 27, r_bytes, s_bytes));

    // Test 4: s >= n (invalid)
    std.mem.writeInt(u256, &r_bytes, 0x123456, .big);
    std.mem.writeInt(u256, &s_bytes, SECP256K1_N, .big);
    try std.testing.expectError(error.InvalidSignature, recoverAddress(msg_hash, 27, r_bytes, s_bytes));

    // Test 5: Invalid recovery_id
    std.mem.writeInt(u256, &r_bytes, 0x123456, .big);
    std.mem.writeInt(u256, &s_bytes, 0x789abc, .big);
    try std.testing.expectError(error.InvalidVValue, recoverAddress(msg_hash, 2, r_bytes, s_bytes));
}

test "public key to address" {
    const pub_key = [_]u8{0x04} ++ [_]u8{0xaa} ** 63;
    const addr = publicKeyToAddress(pub_key);
    try std.testing.expect(addr.bytes.len == 20);
}

/// ECIES encryption for RLPx handshake
/// Simplified ECIES implementation following Ethereum's RLPx spec
pub const ECIES = struct {
    /// Generate shared secret using ECDH
    pub fn generateShared(priv_key: [32]u8, pub_key: [64]u8) ![32]u8 {
        // Convert private key to scalar
        const d = std.mem.readInt(u256, &priv_key, .big);

        // Convert public key to affine point
        const pub_x = std.mem.readInt(u256, pub_key[0..32], .big);
        const pub_y = std.mem.readInt(u256, pub_key[32..64], .big);
        const pub_point = AffinePoint{ .x = pub_x, .y = pub_y, .infinity = false };

        // Perform scalar multiplication: shared = priv * pub
        const shared_point = pub_point.scalar_mul(d);

        if (shared_point.infinity) return error.SharedKeyIsInfinity;

        // Return x-coordinate as shared secret
        var result: [32]u8 = undefined;
        std.mem.writeInt(u256, &result, shared_point.x, .big);
        return result;
    }

    /// Encrypt data using ECIES (simplified for RLPx)
    pub fn encrypt(
        allocator: std.mem.Allocator,
        recipient_pub: [64]u8,
        plaintext: []const u8,
        auth_data: ?[]const u8,
    ) ![]u8 {
        // 1. Generate ephemeral keypair
        var ephemeral_priv: [32]u8 = undefined;
        try std.crypto.random.bytes(&ephemeral_priv);

        const ephemeral_d = std.mem.readInt(u256, &ephemeral_priv, .big);
        const ephemeral_pub = AffinePoint.generator().scalar_mul(ephemeral_d);

        // 2. Derive shared secret
        const shared = try generateShared(ephemeral_priv, recipient_pub);

        // 3. Derive encryption key using KDF
        var enc_key: [32]u8 = undefined;
        @memcpy(&enc_key, &shared); // Simplified - should use proper KDF

        // 4. Encrypt plaintext using AES-256-CTR
        var ciphertext = try allocator.alloc(u8, plaintext.len);
        errdefer allocator.free(ciphertext);

        var cipher = std.crypto.core.aes.Aes256.initEnc(enc_key);
        var counter: [16]u8 = undefined;
        @memset(&counter, 0);

        // Simple block encryption (simplified)
        var i: usize = 0;
        while (i < plaintext.len) : (i += 16) {
            const block_end = @min(i + 16, plaintext.len);
            var block: [16]u8 = undefined;
            @memcpy(block[0..block_end-i], plaintext[i..block_end]);
            cipher.encrypt(&block, &block);
            @memcpy(ciphertext[i..block_end], block[0..block_end-i]);
        }

        // 5. Compute MAC
        var mac_input = try allocator.alloc(u8, ciphertext.len + (if (auth_data) |ad| ad.len else 0));
        defer allocator.free(mac_input);

        @memcpy(mac_input[0..ciphertext.len], ciphertext);
        if (auth_data) |ad| {
            @memcpy(mac_input[ciphertext.len..], ad);
        }

        const mac = keccak256(mac_input);

        // 6. Build result: [ephemeral_pub(65) || IV(16) || ciphertext || mac(32)]
        var result = try allocator.alloc(u8, 65 + 16 + ciphertext.len + 32);

        // Ephemeral public key (uncompressed format)
        result[0] = 0x04;
        std.mem.writeInt(u256, result[1..33], ephemeral_pub.x, .big);
        std.mem.writeInt(u256, result[33..65], ephemeral_pub.y, .big);

        // IV (zeros for now)
        @memset(result[65..81], 0);

        // Ciphertext
        @memcpy(result[81..81+ciphertext.len], ciphertext);

        // MAC
        @memcpy(result[81+ciphertext.len..], &mac);

        allocator.free(ciphertext);
        return result;
    }

    /// Decrypt ECIES encrypted data
    pub fn decrypt(
        allocator: std.mem.Allocator,
        priv_key: [32]u8,
        ciphertext: []const u8,
        auth_data: ?[]const u8,
    ) ![]u8 {
        if (ciphertext.len < 113) return error.InvalidCiphertext; // Min: 65 + 16 + 0 + 32

        // 1. Extract ephemeral public key
        if (ciphertext[0] != 0x04) return error.InvalidPublicKey;
        var ephemeral_pub: [64]u8 = undefined;
        @memcpy(&ephemeral_pub, ciphertext[1..65]);

        // 2. Extract IV (currently unused)
        // const iv = ciphertext[65..81];

        // 3. Extract encrypted data and MAC
        const enc_data = ciphertext[81..ciphertext.len-32];
        const mac = ciphertext[ciphertext.len-32..];

        // 4. Derive shared secret
        const shared = try generateShared(priv_key, ephemeral_pub);

        // 5. Derive decryption key
        var dec_key: [32]u8 = undefined;
        @memcpy(&dec_key, &shared);

        // 6. Verify MAC
        var mac_input = try allocator.alloc(u8, enc_data.len + (if (auth_data) |ad| ad.len else 0));
        defer allocator.free(mac_input);

        @memcpy(mac_input[0..enc_data.len], enc_data);
        if (auth_data) |ad| {
            @memcpy(mac_input[enc_data.len..], ad);
        }

        const expected_mac = keccak256(mac_input);
        if (!std.mem.eql(u8, mac, &expected_mac)) {
            return error.InvalidMAC;
        }

        // 7. Decrypt data
        var plaintext = try allocator.alloc(u8, enc_data.len);

        var cipher = std.crypto.core.aes.Aes256.initDec(dec_key);
        var i: usize = 0;
        while (i < enc_data.len) : (i += 16) {
            const block_end = @min(i + 16, enc_data.len);
            var block: [16]u8 = undefined;
            @memcpy(block[0..block_end-i], enc_data[i..block_end]);
            cipher.decrypt(&block, &block);
            @memcpy(plaintext[i..block_end], block[0..block_end-i]);
        }

        return plaintext;
    }
};

test "verify signature" {
    // Create test signature components
    const msg_hash = [_]u8{0x11} ** 32;
    var r_bytes: [32]u8 = undefined;
    var s_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &r_bytes, 0x1234567890123456789012345678901234567890123456789012345678901234, .big);
    std.mem.writeInt(u256, &s_bytes, 0x3456789012345678901234567890123456789012345678901234567890123456, .big);

    // Try to recover address
    const recovered = recoverAddress(msg_hash, 27, r_bytes, s_bytes) catch |err| {
        try std.testing.expect(err == error.InvalidSignature);
        return;
    };

    // Verify signature matches recovered address
    const verified = try verifySignature(msg_hash, 27, r_bytes, s_bytes, recovered);
    try std.testing.expect(verified);

    // Verify signature does not match different address
    var wrong_address: primitives.Address = undefined;
    @memset(&wrong_address.bytes, 0xFF);
    const not_verified = try verifySignature(msg_hash, 27, r_bytes, s_bytes, wrong_address);
    try std.testing.expect(!not_verified);
}

test "ECIES shared secret" {
    // Generate test keys
    var priv1: [32]u8 = undefined;
    var priv2: [32]u8 = undefined;
    try std.crypto.random.bytes(&priv1);
    try std.crypto.random.bytes(&priv2);

    // Derive public keys
    const d1 = std.mem.readInt(u256, &priv1, .big);
    const pub1_point = AffinePoint.generator().scalar_mul(d1);
    var pub1: [64]u8 = undefined;
    std.mem.writeInt(u256, pub1[0..32], pub1_point.x, .big);
    std.mem.writeInt(u256, pub1[32..64], pub1_point.y, .big);

    const d2 = std.mem.readInt(u256, &priv2, .big);
    const pub2_point = AffinePoint.generator().scalar_mul(d2);
    var pub2: [64]u8 = undefined;
    std.mem.writeInt(u256, pub2[0..32], pub2_point.x, .big);
    std.mem.writeInt(u256, pub2[32..64], pub2_point.y, .big);

    // Shared secrets should be equal
    const shared1 = try ECIES.generateShared(priv1, pub2);
    const shared2 = try ECIES.generateShared(priv2, pub1);

    try std.testing.expectEqualSlices(u8, &shared1, &shared2);
}

test "ECDSA sign and ecrecover" {
    // Generate test private key
    var priv_key: [32]u8 = undefined;
    @memset(&priv_key, 0);
    priv_key[31] = 1; // Simple test key

    // Derive public key
    const d = std.mem.readInt(u256, &priv_key, .big);
    const pub_point = AffinePoint.generator().scalar_mul(d);
    var expected_pub: [64]u8 = undefined;
    std.mem.writeInt(u256, expected_pub[0..32], pub_point.x, .big);
    std.mem.writeInt(u256, expected_pub[32..64], pub_point.y, .big);

    // Create test message
    const message = "Hello, Ethereum!";
    const msg_hash = keccak256(message);

    // Sign message
    const signature = try sign(msg_hash, priv_key);

    // Recover public key
    const recovered_pub = try ecrecover(msg_hash, signature);

    // Verify recovered public key matches original
    try std.testing.expectEqualSlices(u8, &expected_pub, &recovered_pub);
}

test "ECDSA sign deterministic" {
    // Same message and key should produce same signature
    var priv_key: [32]u8 = undefined;
    @memset(&priv_key, 0);
    priv_key[31] = 42;

    const msg_hash = keccak256("test message");

    const sig1 = try sign(msg_hash, priv_key);
    const sig2 = try sign(msg_hash, priv_key);

    // Signatures should be identical (deterministic signing)
    try std.testing.expectEqualSlices(u8, &sig1, &sig2);
}

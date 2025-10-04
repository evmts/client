//! Cryptographic utilities for Ethereum
//! Provides ECDSA signature recovery and Keccak256 hashing

const std = @import("std");
const primitives = @import("primitives");

pub const CryptoError = error{
    InvalidSignature,
    InvalidPublicKey,
    RecoveryFailed,
    InvalidVValue,
};

/// Keccak256 hash function
pub fn keccak256(data: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(data);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

/// Recover Ethereum address from signature
/// This is a simplified implementation - production should use secp256k1 library
pub fn recoverAddress(
    message_hash: [32]u8,
    v: u8,
    r: [32]u8,
    s: [32]u8,
) !primitives.Address {
    // Validate v value (27, 28 for non-EIP-155, or chain_id * 2 + 35/36 for EIP-155)
    const recovery_id = if (v >= 35)
        // EIP-155: v = chain_id * 2 + 35 + recovery_id
        @as(u8, @intCast((v - 35) % 2))
    else if (v >= 27 and v <= 28)
        // Pre-EIP-155: v = 27 + recovery_id
        v - 27
    else
        return error.InvalidVValue;

    if (recovery_id > 1) return error.InvalidVValue;

    // For now, use a placeholder implementation
    // TODO: Integrate with secp256k1 library for proper ECDSA recovery
    // The real implementation would:
    // 1. Recover public key from (r, s, recovery_id, message_hash)
    // 2. Hash public key with Keccak256
    // 3. Take last 20 bytes as address

    // Placeholder: derive address from r (first 20 bytes)
    var addr_bytes: [20]u8 = undefined;
    @memcpy(&addr_bytes, r[0..20]);

    // Mix in message hash and s to make it more deterministic
    for (0..20) |i| {
        addr_bytes[i] ^= message_hash[i] ^ s[i];
    }

    return primitives.Address.fromBytes(&addr_bytes);
}

/// Sign a message hash (placeholder - needs proper secp256k1)
pub fn sign(
    message_hash: [32]u8,
    private_key: [32]u8,
) !struct { v: u8, r: [32]u8, s: [32]u8 } {
    _ = message_hash;
    _ = private_key;

    // TODO: Implement proper ECDSA signing with secp256k1
    return error.RecoveryFailed;
}

/// Derive public key from private key (placeholder)
pub fn derivePublicKey(private_key: [32]u8) ![64]u8 {
    _ = private_key;

    // TODO: Implement proper public key derivation
    return error.RecoveryFailed;
}

/// Derive Ethereum address from public key
pub fn publicKeyToAddress(public_key: [64]u8) primitives.Address {
    const hash = keccak256(&public_key);
    var addr_bytes: [20]u8 = undefined;
    @memcpy(&addr_bytes, hash[12..32]);
    return primitives.Address.fromBytes(&addr_bytes);
}

/// Verify ECDSA signature (placeholder)
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

test "recover address from signature" {
    const message_hash = [_]u8{0xaa} ** 32;
    const r = [_]u8{0xbb} ** 32;
    const s = [_]u8{0xcc} ** 32;
    const v: u8 = 27;

    const addr = try recoverAddress(message_hash, v, r, s);
    try std.testing.expect(addr.bytes.len == 20);
}

test "public key to address" {
    const pub_key = [_]u8{0x04} ++ [_]u8{0xaa} ** 63; // Uncompressed public key format
    const addr = publicKeyToAddress(pub_key);
    try std.testing.expect(addr.bytes.len == 20);
}

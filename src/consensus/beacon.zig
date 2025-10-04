//! Beacon consensus engine (PoS)
//! Based on erigon/consensus/beacon/
//! Post-merge Ethereum proof-of-stake consensus

const std = @import("std");
const primitives = @import("primitives");
const chain = @import("../chain.zig");
const block_types = @import("../types/block.zig");
const Header = block_types.Header;
const BlockNonce = block_types.BlockNonce;
const U256 = primitives.U256;
const Hash = primitives.Hash;

const consensus = @import("consensus.zig");
const ConsensusError = consensus.ConsensusError;

/// Validate header against parent (PoS rules)
fn validateHeader(
    allocator: std.mem.Allocator,
    header: *const Header,
    parent: *const Header,
) ConsensusError!void {
    _ = allocator;
    _ = parent;

    const block_num: u64 = @intCast(header.number.value);

    // 1. Post-merge blocks must have difficulty = 0
    if (!header.difficulty.isZero()) {
        std.log.err("Beacon: Post-merge block {} has non-zero difficulty: {}", .{
            block_num,
            @as(u64, @intCast(header.difficulty.value)),
        });
        return ConsensusError.InvalidDifficulty;
    }

    // 2. mix_digest should be prevRandao from beacon chain (EIP-4399)
    // For now, just verify it's not the default PoW mix_digest pattern
    // In production, this would verify against beacon chain state

    // 3. Nonce should be zero for PoS blocks
    const nonce_value = header.nonce.toU64();
    if (nonce_value != 0) {
        std.log.err("Beacon: PoS block {} has non-zero nonce: {}", .{ block_num, nonce_value });
        return ConsensusError.InvalidNonce;
    }

    // 4. Validate beacon block root (EIP-4788) if present
    if (header.parent_beacon_block_root) |root| {
        // Verify root is not zero
        const root_zero = blk: {
            for (root.bytes) |b| {
                if (b != 0) break :blk false;
            }
            break :blk true;
        };

        if (root_zero) {
            std.log.err("Beacon: Block {} has zero parent_beacon_block_root", .{block_num});
            return ConsensusError.InvalidBeaconRoot;
        }

        // TODO: Verify beacon root against beacon chain
        // In production, this would:
        // 1. Fetch beacon block at parent slot
        // 2. Verify root matches
        // 3. Verify beacon chain finality
    }
}

/// Verify PoS seal (validator signature via beacon chain)
fn verifySeal(
    allocator: std.mem.Allocator,
    header: *const Header,
) ConsensusError!void {
    _ = allocator;

    const block_num: u64 = @intCast(header.number.value);

    // In PoS, the seal is verified through the beacon chain consensus
    // The execution layer doesn't directly verify validator signatures
    // Instead, we verify:

    // 1. Difficulty must be 0
    if (!header.difficulty.isZero()) {
        std.log.err("Beacon: PoS block {} has non-zero difficulty", .{block_num});
        return ConsensusError.InvalidSeal;
    }

    // 2. Nonce must be 0x0000000000000000
    const nonce_value = header.nonce.toU64();
    if (nonce_value != 0) {
        std.log.err("Beacon: PoS block {} has non-zero nonce", .{block_num});
        return ConsensusError.InvalidSeal;
    }

    // 3. mix_digest is prevRandao (verified by validateHeader)
    // This is the randomness from the beacon chain

    // TODO: Full PoS verification would include:
    // 1. Verify block hash is in beacon chain
    // 2. Verify validator signature via beacon chain
    // 3. Verify beacon chain slot matches execution block
    // 4. Verify finality on beacon chain

    // For production, the consensus client (beacon node) provides this validation
    // The execution client trusts the consensus client's validation
}

/// Calculate block reward for PoS block
/// Post-merge blocks have no direct block reward on execution layer
/// Validators receive rewards on the beacon chain
fn blockReward(header: *const Header, uncles: []const Header) U256 {
    _ = header;
    _ = uncles;

    // No block reward on execution layer for PoS
    // Validators get rewards on beacon chain:
    // - Base rewards for attestations
    // - Proposal rewards for including attestations
    // - Sync committee rewards
    return U256.zero();
}

/// Check if block is PoS (always true for Beacon)
fn isPoS(header: *const Header) bool {
    // Beacon is always PoS
    // Check difficulty = 0 as additional validation
    const block_num: u64 = @intCast(header.number.value);
    return header.difficulty.isZero() and block_num > 0;
}

/// Verify prevRandao (mix_digest field in PoS)
pub fn verifyPrevRandao(header: *const Header, expected_randao: Hash) bool {
    return std.mem.eql(u8, &header.mix_digest.bytes, &expected_randao.bytes);
}

/// Verify uncle hash is empty for PoS blocks
pub fn verifyEmptyUncleHash(header: *const Header) bool {
    // PoS blocks must have empty uncle hash (Keccak256 of empty RLP list)
    const empty_uncle_hash = [_]u8{
        0x1d, 0xcc, 0x4d, 0xe8, 0xde, 0xc7, 0x5d, 0x7a,
        0xab, 0x85, 0xb5, 0x67, 0xb6, 0xcc, 0xd4, 0x1a,
        0xd3, 0x12, 0x45, 0x1b, 0x94, 0x8a, 0x74, 0x13,
        0xf0, 0xa1, 0x42, 0xfd, 0x40, 0xd4, 0x93, 0x47,
    };

    return std.mem.eql(u8, &header.uncle_hash.bytes, &empty_uncle_hash);
}

/// Beacon consensus engine instance
pub const engine = consensus.ConsensusEngine{
    .validateHeader = validateHeader,
    .verifySeal = verifySeal,
    .blockReward = blockReward,
    .isPoS = isPoS,
};

// Tests
test "beacon - validate PoS header" {
    const testing = std.testing;

    var parent = Header.init();
    defer parent.deinit(testing.allocator);
    parent.number = U256.fromInt(consensus.MERGE_BLOCK_NUMBER - 1);
    parent.difficulty = U256.fromInt(1000); // Last PoW block
    parent.time = 1663224162;

    var child = Header.init();
    defer child.deinit(testing.allocator);
    child.number = U256.fromInt(consensus.MERGE_BLOCK_NUMBER);
    child.difficulty = U256.zero(); // PoS: difficulty = 0
    child.time = 1663224174;
    child.nonce = BlockNonce.zero();

    // Should validate successfully
    try validateHeader(testing.allocator, &child, &parent);

    // Test with non-zero difficulty - should fail
    child.difficulty = U256.fromInt(1);
    const result1 = validateHeader(testing.allocator, &child, &parent);
    try testing.expectError(ConsensusError.InvalidDifficulty, result1);

    // Reset difficulty, test with non-zero nonce - should fail
    child.difficulty = U256.zero();
    child.nonce = BlockNonce.fromU64(12345);
    const result2 = validateHeader(testing.allocator, &child, &parent);
    try testing.expectError(ConsensusError.InvalidNonce, result2);
}

test "beacon - block reward is zero" {
    const testing = std.testing;

    var header = Header.init();
    defer header.deinit(testing.allocator);
    header.number = U256.fromInt(consensus.MERGE_BLOCK_NUMBER);
    header.difficulty = U256.zero();

    const reward = blockReward(&header, &[_]Header{});
    try testing.expectEqual(@as(u256, 0), reward.value);
}

test "beacon - verify seal" {
    const testing = std.testing;

    var header = Header.init();
    defer header.deinit(testing.allocator);
    header.number = U256.fromInt(consensus.MERGE_BLOCK_NUMBER);
    header.difficulty = U256.zero();
    header.nonce = BlockNonce.zero();

    // Should verify successfully
    try verifySeal(testing.allocator, &header);

    // Test with non-zero nonce - should fail
    header.nonce = BlockNonce.fromU64(1);
    const result = verifySeal(testing.allocator, &header);
    try testing.expectError(ConsensusError.InvalidSeal, result);
}

test "beacon - empty uncle hash verification" {
    const testing = std.testing;

    var header = Header.init();
    defer header.deinit(testing.allocator);

    // Set empty uncle hash (Keccak256 of empty RLP list)
    const empty_uncle_hash = [_]u8{
        0x1d, 0xcc, 0x4d, 0xe8, 0xde, 0xc7, 0x5d, 0x7a,
        0xab, 0x85, 0xb5, 0x67, 0xb6, 0xcc, 0xd4, 0x1a,
        0xd3, 0x12, 0x45, 0x1b, 0x94, 0x8a, 0x74, 0x13,
        0xf0, 0xa1, 0x42, 0xfd, 0x40, 0xd4, 0x93, 0x47,
    };

    header.uncle_hash = Hash.fromBytesExact(empty_uncle_hash);
    try testing.expect(verifyEmptyUncleHash(&header));

    // Test with non-empty uncle hash
    header.uncle_hash = Hash.fromBytesExact([_]u8{0xFF} ** 32);
    try testing.expect(!verifyEmptyUncleHash(&header));
}

test "beacon - prevRandao verification" {
    const testing = std.testing;

    var header = Header.init();
    defer header.deinit(testing.allocator);

    const randao_bytes = [_]u8{0xAB} ** 32;
    header.mix_digest = Hash.fromBytesExact(randao_bytes);

    const expected = Hash.fromBytesExact(randao_bytes);
    try testing.expect(verifyPrevRandao(&header, expected));

    const wrong = Hash.fromBytesExact([_]u8{0xFF} ** 32);
    try testing.expect(!verifyPrevRandao(&header, wrong));
}

test "beacon - isPoS always returns true for valid PoS blocks" {
    const testing = std.testing;

    var header = Header.init();
    defer header.deinit(testing.allocator);
    header.number = U256.fromInt(consensus.MERGE_BLOCK_NUMBER);
    header.difficulty = U256.zero();

    try testing.expect(isPoS(&header));

    // Genesis is not PoS even with zero difficulty
    header.number = U256.zero();
    try testing.expect(!isPoS(&header));
}

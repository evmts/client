//! Consensus engine interface for Ethereum
//! Supports both Ethash (PoW pre-merge) and Beacon (PoS post-merge)
//! Port of erigon/consensus/

const std = @import("std");
const primitives = @import("primitives");
const block_types = @import("../types/block.zig");
const Header = block_types.Header;
const U256 = primitives.U256;

const ethash = @import("ethash.zig");
const beacon = @import("beacon.zig");

/// The Merge block number (Mainnet)
pub const MERGE_BLOCK_NUMBER: u64 = 15_537_394;

/// Consensus validation errors
pub const ConsensusError = error{
    InvalidSeal,
    InvalidDifficulty,
    InvalidUncleHash,
    InvalidMixDigest,
    InvalidNonce,
    InvalidBeaconRoot,
    InvalidPoSBlock,
    InvalidPoWBlock,
    UnclesNotAllowed,
    OutOfMemory,
};

/// Function pointer type for header validation
pub const ValidateHeaderFn = *const fn (
    allocator: std.mem.Allocator,
    header: *const Header,
    parent: *const Header,
) ConsensusError!void;

/// Function pointer type for seal verification
pub const VerifySealFn = *const fn (
    allocator: std.mem.Allocator,
    header: *const Header,
) ConsensusError!void;

/// Function pointer type for block reward calculation
pub const BlockRewardFn = *const fn (
    header: *const Header,
    uncles: []const Header,
) U256;

/// Function pointer type for PoS check
pub const IsPoSFn = *const fn (header: *const Header) bool;

/// Consensus engine interface
/// Provides validation and reward logic for both PoW and PoS
pub const ConsensusEngine = struct {
    /// Validate block header against parent
    validateHeader: ValidateHeaderFn,

    /// Verify seal (PoW nonce or PoS signature)
    verifySeal: VerifySealFn,

    /// Calculate block reward
    blockReward: BlockRewardFn,

    /// Check if block is post-merge (PoS)
    isPoS: IsPoSFn,

    /// Verify header against parent with seal verification
    pub fn verify(
        self: ConsensusEngine,
        allocator: std.mem.Allocator,
        header: *const Header,
        parent: *const Header,
    ) ConsensusError!void {
        // Validate header rules
        try self.validateHeader(allocator, header, parent);

        // Verify seal (PoW or PoS)
        try self.verifySeal(allocator, header);
    }

    /// Full block validation including uncles
    pub fn verifyBlock(
        self: ConsensusEngine,
        allocator: std.mem.Allocator,
        header: *const Header,
        parent: *const Header,
        uncles: []const Header,
    ) ConsensusError!void {
        // First verify the header
        try self.verify(allocator, header, parent);

        // Validate uncles based on consensus type
        if (self.isPoS(header)) {
            // PoS: no uncles allowed
            if (uncles.len > 0) {
                return ConsensusError.UnclesNotAllowed;
            }
        } else {
            // PoW: validate uncle headers
            for (uncles) |*uncle| {
                try self.validateHeader(allocator, uncle, parent);
            }
        }
    }
};

/// Get consensus engine for given block number
/// Returns Ethash for pre-merge blocks, Beacon for post-merge
pub fn getConsensusEngine(block_number: u64) ConsensusEngine {
    if (block_number >= MERGE_BLOCK_NUMBER) {
        return beacon.engine;
    } else {
        return ethash.engine;
    }
}

/// Get consensus engine based on header properties
/// Checks difficulty to determine PoW vs PoS
pub fn getConsensusEngineForHeader(header: *const Header) ConsensusEngine {
    const block_num: u64 = @intCast(header.number.value);

    // Post-merge blocks have difficulty = 0
    if (header.difficulty.isZero() and block_num > 0) {
        return beacon.engine;
    } else {
        return ethash.engine;
    }
}

/// Validate uncle header (pre-merge only)
pub fn validateUncle(
    allocator: std.mem.Allocator,
    uncle: *const Header,
    parent: *const Header,
) ConsensusError!void {
    const engine = ethash.engine;
    try engine.validateHeader(allocator, uncle, parent);
}

// Tests
test "consensus - get engine by block number" {
    // Pre-merge block
    const pow_engine = getConsensusEngine(MERGE_BLOCK_NUMBER - 1);
    _ = pow_engine;
    // Just verify we got an engine without error

    // Post-merge block
    const pos_engine = getConsensusEngine(MERGE_BLOCK_NUMBER);
    _ = pos_engine;
    // Just verify we got an engine without error
}

test "consensus - get engine by header" {
    const testing = std.testing;

    // PoW header (difficulty > 0)
    var pow_header = Header.init();
    defer pow_header.deinit(testing.allocator);
    pow_header.number = U256.fromInt(100);
    pow_header.difficulty = U256.fromInt(1000);

    const pow_engine = getConsensusEngineForHeader(&pow_header);
    try testing.expect(!pow_engine.isPoS(&pow_header));

    // PoS header (difficulty = 0)
    var pos_header = Header.init();
    defer pos_header.deinit(testing.allocator);
    pos_header.number = U256.fromInt(MERGE_BLOCK_NUMBER);
    pos_header.difficulty = U256.zero();

    const pos_engine = getConsensusEngineForHeader(&pos_header);
    try testing.expect(pos_engine.isPoS(&pos_header));
}

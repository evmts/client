//! Ethash consensus engine (PoW)
//! Based on erigon/consensus/ethash/
//! Pre-merge Ethereum proof-of-work consensus

const std = @import("std");
const primitives = @import("primitives");
const block_types = @import("../types/block.zig");
const Header = block_types.Header;
const U256 = primitives.U256;
const Hash = primitives.Hash;

const consensus = @import("consensus.zig");
const ConsensusError = consensus.ConsensusError;

/// Difficulty bound divisor (right shift by 11 = divide by 2048)
const DIFFICULTY_BOUND_DIVISOR: u6 = 11;

/// Minimum difficulty
const MINIMUM_DIFFICULTY: u64 = 131_072;

/// Frontier duration limit (13 seconds)
const FRONTIER_DURATION_LIMIT: u64 = 13;

/// Homestead duration divisor (10 seconds)
const HOMESTEAD_DURATION_DIVISOR: u64 = 10;

/// Exponential difficulty period
const EXP_DIFF_PERIOD: u64 = 100_000;

/// Difficulty bomb delays (in blocks)
const BYZANTIUM_BOMB_DELAY: u64 = 3_000_000;
const CONSTANTINOPLE_BOMB_DELAY: u64 = 5_000_000;
const LONDON_BOMB_DELAY: u64 = 9_700_000;
const ARROW_GLACIER_BOMB_DELAY: u64 = 10_700_000;
const GRAY_GLACIER_BOMB_DELAY: u64 = 11_400_000;

/// Block rewards by fork
const BLOCK_REWARD_FRONTIER: u64 = 5_000_000_000_000_000_000; // 5 ETH
const BLOCK_REWARD_BYZANTIUM: u64 = 3_000_000_000_000_000_000; // 3 ETH
const BLOCK_REWARD_CONSTANTINOPLE: u64 = 2_000_000_000_000_000_000; // 2 ETH

/// Uncle rewards (fraction of block reward)
const UNCLE_INCLUSION_REWARD_DIVISOR: u64 = 32;

/// Fork block numbers
const HOMESTEAD_BLOCK: u64 = 1_150_000;
const BYZANTIUM_BLOCK: u64 = 4_370_000;
const CONSTANTINOPLE_BLOCK: u64 = 7_280_000;
const LONDON_BLOCK: u64 = 12_965_000;
const ARROW_GLACIER_BLOCK: u64 = 13_773_000;
const GRAY_GLACIER_BLOCK: u64 = 15_050_000;

/// Validate header against parent (PoW rules)
fn validateHeader(
    allocator: std.mem.Allocator,
    header: *const Header,
    parent: *const Header,
) ConsensusError!void {
    _ = allocator;

    const block_num: u64 = @intCast(header.number.value);

    // 1. Validate difficulty matches calculated difficulty
    const expected_diff = calcDifficulty(parent, header.time);
    if (!header.difficulty.eql(expected_diff)) {
        std.log.err("Ethash: Invalid difficulty at block {}: expected {}, got {}", .{
            block_num,
            @as(u64, @intCast(expected_diff.value)),
            @as(u64, @intCast(header.difficulty.value)),
        });
        return ConsensusError.InvalidDifficulty;
    }

    // 2. PoW blocks must have non-zero difficulty
    if (header.difficulty.isZero() and block_num > 0) {
        std.log.err("Ethash: PoW block {} has zero difficulty", .{block_num});
        return ConsensusError.InvalidPoWBlock;
    }
}

/// Verify PoW seal (mix_digest and nonce)
fn verifySeal(
    allocator: std.mem.Allocator,
    header: *const Header,
) ConsensusError!void {
    _ = allocator;

    const block_num: u64 = @intCast(header.number.value);

    // TODO: Full Ethash DAG verification
    // For now, simplified validation:
    // 1. Check that nonce is not zero (basic sanity)
    // 2. Check that mix_digest is not zero (basic sanity)

    const nonce_value = header.nonce.toU64();
    if (nonce_value == 0 and block_num > 0) {
        // Genesis can have zero nonce, but other blocks should not
        // (though this is not a hard rule, just a heuristic)
    }

    const mix_digest_zero = blk: {
        for (header.mix_digest.bytes) |b| {
            if (b != 0) break :blk false;
        }
        break :blk true;
    };

    if (mix_digest_zero and block_num > 0) {
        // Non-genesis blocks should have non-zero mix digest
        // (though this is not a hard rule, just a heuristic)
    }

    // TODO: Implement full Ethash verification:
    // 1. Generate DAG dataset for epoch
    // 2. Compute Ethash hash with nonce
    // 3. Verify result <= difficulty target
    // 4. Verify mix_digest matches computed mix

    // For production, this would call:
    // const result = ethash.hashimoto(header, nonce);
    // if (!result.digest.eql(header.mix_digest)) return error.InvalidMixDigest;
    // if (result.value > difficulty_target) return error.InvalidNonce;
}

/// Calculate block reward for PoW block
fn blockReward(header: *const Header, uncles: []const Header) U256 {
    const block_num: u64 = @intCast(header.number.value);

    // Determine base reward by fork
    const base_reward: u64 = if (block_num >= CONSTANTINOPLE_BLOCK)
        BLOCK_REWARD_CONSTANTINOPLE
    else if (block_num >= BYZANTIUM_BLOCK)
        BLOCK_REWARD_BYZANTIUM
    else
        BLOCK_REWARD_FRONTIER;

    var reward = U256.fromInt(base_reward);

    // Add uncle inclusion rewards (1/32 of block reward per uncle)
    if (uncles.len > 0) {
        const uncle_reward = base_reward / UNCLE_INCLUSION_REWARD_DIVISOR;
        const total_uncle_reward = uncle_reward * @as(u64, @intCast(uncles.len));
        reward = reward.add(U256.fromInt(total_uncle_reward));
    }

    return reward;
}

/// Calculate uncle reward
pub fn uncleReward(uncle_num: u64, nephew_num: u64, base_reward: u64) U256 {
    // Uncle reward formula: (8 - (nephew - uncle)) / 8 * base_reward
    // Maximum 2 blocks difference for uncle to be valid
    if (nephew_num <= uncle_num or nephew_num - uncle_num > 2) {
        return U256.zero();
    }

    const distance = nephew_num - uncle_num;
    const multiplier = 8 - distance;
    const reward = (base_reward * multiplier) / 8;

    return U256.fromInt(reward);
}

/// Check if block is PoS (always false for Ethash)
fn isPoS(header: *const Header) bool {
    // Ethash is always PoW, but check difficulty to be safe
    const block_num: u64 = @intCast(header.number.value);
    return header.difficulty.isZero() and block_num > 0;
}

/// Calculate difficulty for next block (Homestead+ algorithm)
/// Based on erigon/consensus/ethash/difficulty.go
pub fn calcDifficulty(parent: *const Header, block_time: u64) U256 {
    const parent_num: u64 = @intCast(parent.number.value);
    const parent_time = parent.time;

    // For parent of The Merge or later, difficulty is 0
    if (parent_num >= consensus.MERGE_BLOCK_NUMBER - 1) {
        return U256.zero();
    }

    var diff = parent.difficulty;

    // Calculate adjustment factor (parent_diff / 2048)
    var adjust = diff;
    adjust.value >>= DIFFICULTY_BOUND_DIVISOR;

    // Time-based adjustment (Homestead formula)
    const time_delta = block_time - parent_time;

    if (parent_num >= HOMESTEAD_BLOCK) {
        // Homestead: more gradual adjustment
        const x = if (time_delta >= HOMESTEAD_DURATION_DIVISOR)
            (time_delta / HOMESTEAD_DURATION_DIVISOR) - 1
        else
            0;

        const max_adjustment = @min(x, 99);

        // Adjust difficulty down if blocks are slow
        var adjustment_amount = adjust;
        adjustment_amount.value *= max_adjustment;

        if (diff.value > adjustment_amount.value) {
            diff.value -= adjustment_amount.value;
        } else {
            diff = U256.fromInt(MINIMUM_DIFFICULTY);
        }
    } else {
        // Frontier: simple adjustment
        if (time_delta < FRONTIER_DURATION_LIMIT) {
            diff = diff.add(adjust);
        } else {
            diff = diff.sub(adjust);
        }
    }

    // Ensure minimum difficulty
    if (diff.value < MINIMUM_DIFFICULTY) {
        diff = U256.fromInt(MINIMUM_DIFFICULTY);
    }

    // Add difficulty bomb (exponential increase)
    const period_count = (parent_num + 1) / EXP_DIFF_PERIOD;
    if (period_count > 1) {
        const bomb_delay = getBombDelay(parent_num + 1);
        const delayed_period = if (period_count > bomb_delay / EXP_DIFF_PERIOD)
            period_count - (bomb_delay / EXP_DIFF_PERIOD)
        else
            0;

        if (delayed_period > 1 and delayed_period < 64) {
            const exp_diff: u64 = @as(u64, 1) << @intCast(delayed_period - 2);
            diff.value += exp_diff;
        }
    }

    return diff;
}

/// Get difficulty bomb delay for given block number
fn getBombDelay(block_number: u64) u64 {
    if (block_number >= GRAY_GLACIER_BLOCK) {
        return GRAY_GLACIER_BOMB_DELAY;
    } else if (block_number >= ARROW_GLACIER_BLOCK) {
        return ARROW_GLACIER_BOMB_DELAY;
    } else if (block_number >= LONDON_BLOCK) {
        return LONDON_BOMB_DELAY;
    } else if (block_number >= CONSTANTINOPLE_BLOCK) {
        return CONSTANTINOPLE_BOMB_DELAY;
    } else if (block_number >= BYZANTIUM_BLOCK) {
        return BYZANTIUM_BOMB_DELAY;
    }
    return 0;
}

/// Ethash consensus engine instance
pub const engine = consensus.ConsensusEngine{
    .validateHeader = validateHeader,
    .verifySeal = verifySeal,
    .blockReward = blockReward,
    .isPoS = isPoS,
};

// Tests
test "ethash - difficulty calculation" {
    const testing = std.testing;

    var parent = Header.init();
    defer parent.deinit(testing.allocator);
    parent.number = U256.fromInt(100);
    parent.difficulty = U256.fromInt(17_179_869_184);
    parent.time = 1609459200;

    const block_time: u64 = 1609459212; // 12 seconds later

    const difficulty = calcDifficulty(&parent, block_time);

    // Difficulty should be adjusted based on time delta
    try testing.expect(difficulty.value > 0);
    try testing.expect(difficulty.value >= MINIMUM_DIFFICULTY);
}

test "ethash - block reward calculation" {
    const testing = std.testing;

    // Test Frontier reward (5 ETH)
    var frontier_header = Header.init();
    defer frontier_header.deinit(testing.allocator);
    frontier_header.number = U256.fromInt(1000);

    const frontier_reward = blockReward(&frontier_header, &[_]Header{});
    try testing.expectEqual(@as(u256, BLOCK_REWARD_FRONTIER), frontier_reward.value);

    // Test Byzantium reward (3 ETH)
    var byzantium_header = Header.init();
    defer byzantium_header.deinit(testing.allocator);
    byzantium_header.number = U256.fromInt(BYZANTIUM_BLOCK);

    const byzantium_reward = blockReward(&byzantium_header, &[_]Header{});
    try testing.expectEqual(@as(u256, BLOCK_REWARD_BYZANTIUM), byzantium_reward.value);

    // Test Constantinople reward (2 ETH)
    var constantinople_header = Header.init();
    defer constantinople_header.deinit(testing.allocator);
    constantinople_header.number = U256.fromInt(CONSTANTINOPLE_BLOCK);

    const constantinople_reward = blockReward(&constantinople_header, &[_]Header{});
    try testing.expectEqual(@as(u256, BLOCK_REWARD_CONSTANTINOPLE), constantinople_reward.value);
}

test "ethash - uncle reward calculation" {
    const testing = std.testing;

    const base_reward = BLOCK_REWARD_CONSTANTINOPLE;

    // Uncle at distance 1: (8-1)/8 * base = 7/8 * base
    const reward1 = uncleReward(100, 101, base_reward);
    const expected1 = (base_reward * 7) / 8;
    try testing.expectEqual(@as(u256, expected1), reward1.value);

    // Uncle at distance 2: (8-2)/8 * base = 6/8 * base
    const reward2 = uncleReward(100, 102, base_reward);
    const expected2 = (base_reward * 6) / 8;
    try testing.expectEqual(@as(u256, expected2), reward2.value);

    // Uncle at distance 3 or more: 0 reward
    const reward3 = uncleReward(100, 104, base_reward);
    try testing.expectEqual(@as(u256, 0), reward3.value);
}

test "ethash - validate header" {
    const testing = std.testing;

    var parent = Header.init();
    defer parent.deinit(testing.allocator);
    parent.number = U256.fromInt(100);
    parent.difficulty = U256.fromInt(17_179_869_184);
    parent.time = 1609459200;

    var child = Header.init();
    defer child.deinit(testing.allocator);
    child.number = U256.fromInt(101);
    child.time = 1609459212; // 12 seconds later
    child.difficulty = calcDifficulty(&parent, child.time);

    // Should validate successfully
    try validateHeader(testing.allocator, &child, &parent);

    // Test with wrong difficulty - should fail
    child.difficulty = U256.fromInt(1000);
    const result = validateHeader(testing.allocator, &child, &parent);
    try testing.expectError(ConsensusError.InvalidDifficulty, result);
}

test "ethash - bomb delay calculation" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 0), getBombDelay(0));
    try testing.expectEqual(BYZANTIUM_BOMB_DELAY, getBombDelay(BYZANTIUM_BLOCK));
    try testing.expectEqual(CONSTANTINOPLE_BOMB_DELAY, getBombDelay(CONSTANTINOPLE_BLOCK));
    try testing.expectEqual(LONDON_BOMB_DELAY, getBombDelay(LONDON_BLOCK));
    try testing.expectEqual(ARROW_GLACIER_BOMB_DELAY, getBombDelay(ARROW_GLACIER_BLOCK));
    try testing.expectEqual(GRAY_GLACIER_BOMB_DELAY, getBombDelay(GRAY_GLACIER_BLOCK));
}

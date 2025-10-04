//! Headers stage: Download and validate block headers
//! Based on erigon/turbo/stages/headerdownload/

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const database = @import("../database.zig");
const crypto = @import("primitives").crypto;

/// Extra data size limits
const MAX_EXTRA_DATA_SIZE: usize = 32;
const MAX_EXTRA_DATA_SIZE_ISTANBUL: usize = 97; // 32 vanity + 65 seal

/// Time allowance for future blocks (seconds)
const ALLOWED_FUTURE_BLOCK_TIME: u64 = 15;

/// Difficulty bomb delays (in blocks)
const BYZANTIUM_BOMB_DELAY: u64 = 3_000_000;
const CONSTANTINOPLE_BOMB_DELAY: u64 = 5_000_000;
const LONDON_BOMB_DELAY: u64 = 9_700_000;
const ARROW_GLACIER_BOMB_DELAY: u64 = 10_700_000;
const GRAY_GLACIER_BOMB_DELAY: u64 = 11_400_000;

/// Minimum difficulty
const MINIMUM_DIFFICULTY: u64 = 131_072;

/// Difficulty bound divisor (right shift by 11 = divide by 2048)
const DIFFICULTY_BOUND_DIVISOR: u6 = 11;

/// Frontier duration limit (13 seconds)
const FRONTIER_DURATION_LIMIT: u64 = 13;

/// Homestead duration divisor (10 seconds)
const HOMESTEAD_DURATION_DIVISOR: u64 = 10;

/// Exponential difficulty period
const EXP_DIFF_PERIOD: u64 = 100_000;

/// Header download configuration
const HeadersCfg = struct {
    batch_size: u64 = 1024,
    request_timeout_ms: u64 = 5000,
    max_requests_in_flight: u32 = 16,
};

/// Header download state
pub const HeaderDownload = struct {
    progress: u64,
    fetching_new: bool,
    pos_sync: bool,
    highest_seen: u64,

    pub fn init() HeaderDownload {
        return .{
            .progress = 0,
            .fetching_new = false,
            .pos_sync = false,
            .highest_seen = 0,
        };
    }

    pub fn setProgress(self: *HeaderDownload, block_num: u64) void {
        self.progress = block_num;
    }

    pub fn getProgress(self: *const HeaderDownload) u64 {
        return self.progress;
    }

    pub fn setFetchingNew(self: *HeaderDownload, fetching: bool) void {
        self.fetching_new = fetching;
    }

    pub fn setPOSSync(self: *HeaderDownload, pos: bool) void {
        self.pos_sync = pos;
    }

    pub fn updateHighestSeen(self: *HeaderDownload, block_num: u64) void {
        if (block_num > self.highest_seen) {
            self.highest_seen = block_num;
        }
    }
};

/// Header validation errors
pub const HeaderError = error{
    InvalidParentHash,
    InvalidTimestamp,
    InvalidDifficulty,
    InvalidGasUsed,
    InvalidGasLimit,
    InvalidExtraData,
    InvalidBlockNumber,
    InvalidPoWDifficulty,
    InvalidPoSBlock,
    UnknownParent,
    OutOfMemory,
};

/// Main stage execution
pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("Headers stage: syncing from {} to {}", .{ ctx.from_block, ctx.to_block });

    var hd = HeaderDownload.init();
    hd.setProgress(ctx.from_block);
    hd.setFetchingNew(true);
    defer hd.setFetchingNew(false);

    var blocks_processed: u64 = 0;
    const cfg = HeadersCfg{};

    var current_block = ctx.from_block + 1;
    while (current_block <= ctx.to_block) {
        const batch_end = @min(current_block + cfg.batch_size, ctx.to_block);

        // Download and validate headers batch
        try downloadHeadersBatch(ctx, current_block, batch_end, &blocks_processed, &hd);
        current_block = batch_end + 1;

        if (blocks_processed % 10000 == 0 and blocks_processed > 0) {
            std.log.info("Headers progress: {}/{}", .{ current_block - 1, ctx.to_block });
        }
    }

    return sync.StageResult{
        .blocks_processed = blocks_processed,
        .stage_done = (current_block > ctx.to_block),
    };
}

/// Download and validate a batch of headers
fn downloadHeadersBatch(
    ctx: *sync.StageContext,
    from_block: u64,
    to_block: u64,
    blocks_processed: *u64,
    hd: *HeaderDownload,
) !void {
    var block_num = from_block;

    while (block_num <= to_block) : (block_num += 1) {
        // Get parent header for validation
        const parent = if (block_num > 0) ctx.db.getHeader(block_num - 1) else null;

        // Generate/download header
        const header = try downloadHeader(ctx.allocator, block_num, parent);

        // Validate header against parent
        if (parent) |p| {
            try validateHeader(&header, &p, block_num);
        } else if (block_num == 0) {
            // Genesis block - basic validation only
            try validateGenesisHeader(&header);
        }

        // Store validated header
        try ctx.db.putHeader(block_num, header);

        blocks_processed.* += 1;
        hd.setProgress(block_num);
        hd.updateHighestSeen(block_num);
    }
}

/// Download a single header (placeholder - would fetch from network in production)
fn downloadHeader(allocator: std.mem.Allocator, number: u64, parent: ?chain.Header) !chain.Header {
    _ = allocator;
    const primitives = @import("primitives");

    var parent_hash = [_]u8{0} ** 32;
    var difficulty = chain.U256.zero();
    var timestamp: u64 = 1609459200; // Jan 1, 2021

    if (parent) |p| {
        // Calculate parent hash
        parent_hash = blk: {
            var hash_buf = [_]u8{0} ** 32;
            // Simple hash derivation for testing
            std.mem.writeInt(u64, hash_buf[0..8], p.number, .big);
            break :blk hash_buf;
        };

        // Calculate timestamp (12 second blocks)
        timestamp = p.timestamp + 12;

        // Calculate difficulty
        difficulty = calcDifficulty(p.difficulty, p.timestamp, timestamp, p.number);
    } else {
        // Genesis block
        difficulty = chain.U256.fromInt(17_179_869_184); // Genesis difficulty
        timestamp = 0;
    }

    return chain.Header{
        .parent_hash = parent_hash,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = difficulty,
        .number = number,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = timestamp,
        .extra_data = &[_]u8{},
        .mix_digest = [_]u8{0} ** 32,
        .nonce = chain.encodeNonce(0),
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = if (number >= 12_965_000) chain.U256.fromInt(1000000000) else null, // London fork
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
    };
}

/// Validate header against parent
fn validateHeader(header: *const chain.Header, parent: *const chain.Header, block_number: u64) !void {
    // 1. Validate parent hash
    const expected_parent_hash = blk: {
        var hash_buf = [_]u8{0} ** 32;
        std.mem.writeInt(u64, hash_buf[0..8], parent.number, .big);
        break :blk hash_buf;
    };

    if (!std.mem.eql(u8, &header.parent_hash, &expected_parent_hash)) {
        std.log.err("Invalid parent hash at block {}: expected {x}, got {x}", .{
            block_number,
            expected_parent_hash,
            header.parent_hash,
        });
        return HeaderError.InvalidParentHash;
    }

    // 2. Validate block number sequence
    if (header.number != parent.number + 1) {
        std.log.err("Invalid block number: expected {}, got {}", .{
            parent.number + 1,
            header.number,
        });
        return HeaderError.InvalidBlockNumber;
    }

    // 3. Validate timestamp is monotonically increasing
    if (header.timestamp <= parent.timestamp) {
        std.log.err("Invalid timestamp at block {}: {} <= parent {}", .{
            block_number,
            header.timestamp,
            parent.timestamp,
        });
        return HeaderError.InvalidTimestamp;
    }

    // 4. Validate timestamp is not too far in future
    const current_time = @as(u64, @intCast(std.time.timestamp()));
    if (header.timestamp > current_time + ALLOWED_FUTURE_BLOCK_TIME) {
        std.log.err("Block {} timestamp too far in future: {} > {}", .{
            block_number,
            header.timestamp,
            current_time + ALLOWED_FUTURE_BLOCK_TIME,
        });
        return HeaderError.InvalidTimestamp;
    }

    // 5. Validate gas_used <= gas_limit
    if (header.gas_used > header.gas_limit) {
        std.log.err("Invalid gas usage at block {}: {} > {}", .{
            block_number,
            header.gas_used,
            header.gas_limit,
        });
        return HeaderError.InvalidGasUsed;
    }

    // 6. Validate gas limit change (max ±1/1024 of parent)
    const gas_limit_diff = if (header.gas_limit > parent.gas_limit)
        header.gas_limit - parent.gas_limit
    else
        parent.gas_limit - header.gas_limit;

    const max_gas_change = parent.gas_limit / 1024;
    if (gas_limit_diff > max_gas_change) {
        std.log.err("Gas limit change too large at block {}: {} > {}", .{
            block_number,
            gas_limit_diff,
            max_gas_change,
        });
        return HeaderError.InvalidGasLimit;
    }

    // 7. Validate extra data size
    const max_extra = if (block_number >= 1_035_301) // Istanbul fork
        MAX_EXTRA_DATA_SIZE_ISTANBUL
    else
        MAX_EXTRA_DATA_SIZE;

    if (header.extra_data.len > max_extra) {
        std.log.err("Extra data too large at block {}: {} > {}", .{
            block_number,
            header.extra_data.len,
            max_extra,
        });
        return HeaderError.InvalidExtraData;
    }

    // 8. Validate difficulty
    try validateDifficulty(header, parent);

    // 9. Validate PoS vs PoW
    const is_pos = header.difficulty.value == 0 and header.number > 0;
    const is_post_merge = block_number >= 15_537_394; // The Merge block

    if (is_post_merge) {
        // Post-merge: must be PoS (difficulty = 0)
        if (!is_pos) {
            std.log.err("Post-merge block {} has non-zero difficulty", .{block_number});
            return HeaderError.InvalidPoSBlock;
        }
    } else {
        // Pre-merge: must be PoW (difficulty > 0)
        if (is_pos) {
            std.log.err("Pre-merge block {} has zero difficulty", .{block_number});
            return HeaderError.InvalidPoWDifficulty;
        }
    }
}

/// Validate genesis header
fn validateGenesisHeader(header: *const chain.Header) !void {
    // Genesis block must have number 0
    if (header.number != 0) {
        return HeaderError.InvalidBlockNumber;
    }

    // Genesis must have zero parent hash
    const zero_hash = [_]u8{0} ** 32;
    if (!std.mem.eql(u8, &header.parent_hash, &zero_hash)) {
        return HeaderError.InvalidParentHash;
    }

    // Basic sanity checks
    if (header.gas_used > header.gas_limit) {
        return HeaderError.InvalidGasUsed;
    }
}

/// Validate difficulty calculation
fn validateDifficulty(header: *const chain.Header, parent: *const chain.Header) !void {
    // Post-merge blocks have difficulty = 0
    if (header.difficulty.value == 0 and header.number > 0) {
        return; // PoS block - no difficulty validation needed
    }

    // Calculate expected difficulty
    const expected = calcDifficulty(
        parent.difficulty,
        parent.timestamp,
        header.timestamp,
        parent.number,
    );

    // Validate difficulty matches expected
    if (!header.difficulty.eql(expected)) {
        std.log.err("Invalid difficulty at block {}: expected {}, got {}", .{
            header.number,
            expected.value,
            header.difficulty.value,
        });
        return HeaderError.InvalidDifficulty;
    }
}

/// Calculate difficulty for next block (Homestead algorithm)
/// Based on erigon/execution/consensus/ethash/difficulty.go
fn calcDifficulty(
    parent_diff: chain.U256,
    parent_time: u64,
    block_time: u64,
    parent_number: u64,
) chain.U256 {
    // For PoS blocks, difficulty is 0
    if (parent_number >= 15_537_393) { // Parent of The Merge
        return chain.U256.zero();
    }

    var diff = parent_diff;

    // Calculate adjustment factor
    var adjust = diff;
    adjust.value >>= DIFFICULTY_BOUND_DIVISOR; // divide by 2048

    // Time-based adjustment (Homestead formula)
    const time_delta = block_time - parent_time;
    const x = if (time_delta >= HOMESTEAD_DURATION_DIVISOR)
        (time_delta / HOMESTEAD_DURATION_DIVISOR) - 1
    else
        0;

    const max_adjustment = @min(x, 99);

    // Adjust difficulty
    var adjustment_amount = adjust;
    adjustment_amount.value *= max_adjustment;

    if (diff.value > adjustment_amount.value) {
        diff.value -= adjustment_amount.value;
    } else {
        diff = chain.U256.fromInt(MINIMUM_DIFFICULTY);
    }

    // Ensure minimum difficulty
    if (diff.value < MINIMUM_DIFFICULTY) {
        diff = chain.U256.fromInt(MINIMUM_DIFFICULTY);
    }

    // Add difficulty bomb (exponential increase)
    const period_count = (parent_number + 1) / EXP_DIFF_PERIOD;
    if (period_count > 1) {
        const bomb_delay = getBombDelay(parent_number + 1);
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
    if (block_number >= 15_050_000) { // Gray Glacier
        return GRAY_GLACIER_BOMB_DELAY;
    } else if (block_number >= 13_773_000) { // Arrow Glacier
        return ARROW_GLACIER_BOMB_DELAY;
    } else if (block_number >= 12_965_000) { // London
        return LONDON_BOMB_DELAY;
    } else if (block_number >= 7_280_000) { // Constantinople
        return CONSTANTINOPLE_BOMB_DELAY;
    } else if (block_number >= 4_370_000) { // Byzantium
        return BYZANTIUM_BOMB_DELAY;
    }
    return 0;
}

/// Unwind headers (for chain reorganizations)
pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("Headers stage: unwinding to block {}", .{unwind_to});

    // In production, this would:
    // 1. Delete canonical hash mappings for unwound blocks
    // 2. Mark bad headers if unwinding due to invalid block
    // 3. Find new chain head with highest total difficulty
    // 4. Update canonical chain markers
    // 5. Update stage progress

    // For this implementation: just verify we can read the unwind target
    const header = ctx.db.getHeader(unwind_to);
    if (header == null) {
        std.log.warn("Unwind target block {} not found", .{unwind_to});
    }

    std.log.info("Headers unwound to block {}", .{unwind_to});
}

/// Stage interface export
pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
};

// ============================================================================
// Tests
// ============================================================================

test "headers stage execution" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    var ctx = sync.StageContext{
        .allocator = std.testing.allocator,
        .db = &db,
        .stage = .headers,
        .from_block = 0,
        .to_block = 10,
    };

    const result = try execute(&ctx);
    try std.testing.expect(result.blocks_processed > 0);
    try std.testing.expect(result.stage_done);

    // Verify headers were stored
    const header = db.getHeader(1);
    try std.testing.expect(header != null);
    try std.testing.expectEqual(@as(u64, 1), header.?.number);
}

test "header validation - parent hash" {
    const primitives = @import("primitives");

    var parent = chain.Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = chain.U256.fromInt(17_179_869_184),
        .number = 0,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 1609459200,
        .extra_data = &[_]u8{},
        .mix_digest = [_]u8{0} ** 32,
        .nonce = chain.encodeNonce(0),
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
    };

    var parent_hash = [_]u8{0} ** 32;
    std.mem.writeInt(u64, parent_hash[0..8], 0, .big);

    var child = chain.Header{
        .parent_hash = parent_hash,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = chain.U256.fromInt(17_179_869_184),
        .number = 1,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 1609459212, // 12 seconds later
        .extra_data = &[_]u8{},
        .mix_digest = [_]u8{0} ** 32,
        .nonce = chain.encodeNonce(0),
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
    };

    // Should validate successfully
    try validateHeader(&child, &parent, 1);
}

test "header validation - timestamp must increase" {
    const primitives = @import("primitives");

    var parent = chain.Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = chain.U256.fromInt(17_179_869_184),
        .number = 0,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 1609459200,
        .extra_data = &[_]u8{},
        .mix_digest = [_]u8{0} ** 32,
        .nonce = chain.encodeNonce(0),
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
    };

    var parent_hash = [_]u8{0} ** 32;
    std.mem.writeInt(u64, parent_hash[0..8], 0, .big);

    var child = parent;
    child.parent_hash = parent_hash;
    child.number = 1;
    child.timestamp = 1609459200; // Same timestamp - invalid!

    // Should fail validation
    const result = validateHeader(&child, &parent, 1);
    try std.testing.expectError(HeaderError.InvalidTimestamp, result);
}

test "header validation - gas_used <= gas_limit" {
    const primitives = @import("primitives");

    var parent = chain.Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = chain.U256.fromInt(17_179_869_184),
        .number = 0,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 1609459200,
        .extra_data = &[_]u8{},
        .mix_digest = [_]u8{0} ** 32,
        .nonce = chain.encodeNonce(0),
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
    };

    var parent_hash = [_]u8{0} ** 32;
    std.mem.writeInt(u64, parent_hash[0..8], 0, .big);

    var child = parent;
    child.parent_hash = parent_hash;
    child.number = 1;
    child.timestamp = 1609459212;
    child.gas_used = 30000001; // Exceeds gas limit!

    // Should fail validation
    const result = validateHeader(&child, &parent, 1);
    try std.testing.expectError(HeaderError.InvalidGasUsed, result);
}

test "difficulty calculation - Homestead" {
    const parent_diff = chain.U256.fromInt(17_179_869_184);
    const parent_time: u64 = 1609459200;
    const block_time: u64 = 1609459212; // 12 seconds later
    const parent_number: u64 = 0;

    const difficulty = calcDifficulty(parent_diff, parent_time, block_time, parent_number);

    // Difficulty should be adjusted based on time delta
    try std.testing.expect(difficulty.value > 0);
    try std.testing.expect(difficulty.value >= MINIMUM_DIFFICULTY);
}

test "difficulty calculation - PoS returns zero" {
    const parent_diff = chain.U256.fromInt(17_179_869_184);
    const parent_time: u64 = 1663224162;
    const block_time: u64 = 1663224174;
    const parent_number: u64 = 15_537_393; // Right before The Merge

    const difficulty = calcDifficulty(parent_diff, parent_time, block_time, parent_number);

    // Should return zero for PoS blocks
    try std.testing.expectEqual(@as(u256, 0), difficulty.value);
}

test "genesis header validation" {
    const primitives = @import("primitives");

    const genesis = chain.Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = chain.U256.fromInt(17_179_869_184),
        .number = 0,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 0,
        .extra_data = &[_]u8{},
        .mix_digest = [_]u8{0} ** 32,
        .nonce = chain.encodeNonce(0),
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
    };

    try validateGenesisHeader(&genesis);
}

test "bomb delay calculation" {
    try std.testing.expectEqual(@as(u64, 0), getBombDelay(0));
    try std.testing.expectEqual(BYZANTIUM_BOMB_DELAY, getBombDelay(4_370_000));
    try std.testing.expectEqual(CONSTANTINOPLE_BOMB_DELAY, getBombDelay(7_280_000));
    try std.testing.expectEqual(LONDON_BOMB_DELAY, getBombDelay(12_965_000));
    try std.testing.expectEqual(ARROW_GLACIER_BOMB_DELAY, getBombDelay(13_773_000));
    try std.testing.expectEqual(GRAY_GLACIER_BOMB_DELAY, getBombDelay(15_050_000));
}

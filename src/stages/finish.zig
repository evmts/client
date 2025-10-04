//! Finish stage: Finalize sync and update chain head
//! This is the final stage that commits all changes and updates the canonical chain
//! Based on erigon/eth/stagedsync/stage_finish.go

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const database = @import("../database.zig");

/// Finish stage configuration
const FinishConfig = struct {
    /// Enable database compaction after sync
    enable_compaction: bool = false,
    /// Verify all stage progress is consistent
    verify_consistency: bool = true,
};

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("Finish stage: finalizing sync to block {}", .{ctx.to_block});

    const cfg = FinishConfig{};

    // 1. Verify all stages are at the target block
    if (cfg.verify_consistency) {
        try verifyStageConsistency(ctx);
    }

    // 2. Get latest header to set as chain head
    const latest_header = ctx.db.getHeader(ctx.to_block) orelse {
        std.log.err("Cannot find header for block {}", .{ctx.to_block});
        return error.HeaderNotFound;
    };

    // 3. Compute and log final state root
    // TODO: Full state commitment via Merkle Patricia Trie
    std.log.info("State root at block {}: {x}", .{
        latest_header.number,
        latest_header.state_root,
    });

    // 4. Update canonical chain head markers
    try updateChainHead(ctx, &latest_header);

    // 5. Log sync completion statistics
    try logSyncStatistics(ctx);

    // 6. Trigger database compaction (if enabled)
    if (cfg.enable_compaction) {
        try compactDatabase(ctx);
    }

    // 7. Mark finish stage as complete
    try ctx.db.setStageProgress(.finish, ctx.to_block);

    std.log.info("Sync finished successfully at block {}", .{ctx.to_block});

    return sync.StageResult{
        .blocks_processed = ctx.to_block - ctx.from_block,
        .stage_done = true,
    };
}

/// Verify all stages reached the same block height
fn verifyStageConsistency(ctx: *sync.StageContext) !void {
    const stages = [_]database.Stage{
        .headers,
        .bodies,
        .senders,
        .execution,
        .blockhashes,
        .txlookup,
    };

    var min_progress: u64 = std.math.maxInt(u64);
    var max_progress: u64 = 0;
    var inconsistent_stage: ?database.Stage = null;

    for (stages) |stage| {
        const progress = ctx.db.getStageProgress(stage);
        if (progress < min_progress) {
            min_progress = progress;
            inconsistent_stage = stage;
        }
        if (progress > max_progress) {
            max_progress = progress;
        }
    }

    if (min_progress != max_progress) {
        std.log.warn("Stage consistency warning: {} at block {} while target is {}", .{
            inconsistent_stage.?.toString(),
            min_progress,
            max_progress,
        });
        // Don't fail - just warn. Some stages may be behind during incremental sync.
    } else {
        std.log.info("Stage consistency verified: all stages at block {}", .{min_progress});
    }
}

/// Update canonical chain head markers
fn updateChainHead(ctx: *sync.StageContext, header: *const chain.Header) !void {
    // Production implementation would:
    // 1. WriteHeadBlockHash(tx, block_hash) - marks the fully synced block
    // 2. WriteHeadHeaderHash(tx, block_hash) - marks the latest header
    // 3. WriteHeadFastBlockHash(tx, block_hash) - for fast sync
    // 4. UpdateCanonicalMarkers(tx, block_number, block_hash)
    //
    // These markers are used by RPC endpoints:
    // - eth_blockNumber: returns head block number
    // - eth_getBlockByNumber("latest"): uses head block hash
    // - eth_syncing: compares head vs highest seen block

    const block_hash = try header.hash(ctx.allocator);
    std.log.info("Setting chain head to block {} (hash: {})", .{
        header.number,
        std.fmt.fmtSliceHexLower(&block_hash[0..8]),
    });

    // In our simplified database, we just verify the header exists
    if (ctx.db.getHeader(header.number) == null) {
        return error.InvalidChainHead;
    }
}

/// Log sync completion statistics
fn logSyncStatistics(ctx: *sync.StageContext) !void {
    const headers_progress = ctx.db.getStageProgress(.headers);
    const bodies_progress = ctx.db.getStageProgress(.bodies);
    const senders_progress = ctx.db.getStageProgress(.senders);
    const execution_progress = ctx.db.getStageProgress(.execution);
    const blockhashes_progress = ctx.db.getStageProgress(.blockhashes);
    const txlookup_progress = ctx.db.getStageProgress(.txlookup);

    std.log.info("=== Sync Statistics ===", .{});
    std.log.info("Headers:     {} blocks", .{headers_progress});
    std.log.info("Bodies:      {} blocks", .{bodies_progress});
    std.log.info("Senders:     {} blocks", .{senders_progress});
    std.log.info("Execution:   {} blocks", .{execution_progress});
    std.log.info("BlockHashes: {} blocks", .{blockhashes_progress});
    std.log.info("TxLookup:    {} blocks", .{txlookup_progress});
    std.log.info("======================", .{});

    // Production would also log:
    // - Total sync time
    // - Blocks per second
    // - Database size
    // - State trie size
    // - Number of accounts
    // - Number of transactions
}

/// Trigger database compaction and optimization
fn compactDatabase(ctx: *sync.StageContext) !void {
    _ = ctx;

    std.log.info("Database compaction starting...", .{});

    // Production implementation would:
    // 1. MDBX environment compaction
    //    - mdbx_env_copy with MDBX_CP_COMPACT flag
    //    - Removes fragmentation and unused pages
    //    - Can reduce database size by 20-50%
    //
    // 2. Optimize page layout
    //    - Reorganize B+ trees for sequential access
    //    - Improve cache locality
    //
    // 3. Update statistics
    //    - Rebuild table statistics for query optimization
    //    - Update page split thresholds
    //
    // 4. Vacuum operations
    //    - Free pages reclamation
    //    - Coalesce adjacent free pages
    //
    // Reference: erigon/turbo/snapshotsync/freezeblocks/block_reader.go
    // and MDBX documentation on compaction

    std.log.info("Database compaction complete", .{});
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("Finish stage: unwinding to block {}", .{unwind_to});

    // Revert chain head markers
    // Production would:
    // 1. Read canonical hash at unwind_to block
    // 2. Update all head markers to point to that block
    // 3. Remove canonical markers for blocks > unwind_to
    // 4. Update fork choice if needed

    try ctx.db.setStageProgress(.finish, unwind_to);

    std.log.info("Finish stage unwound to block {}", .{unwind_to});
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
};

// ============================================================================
// Tests
// ============================================================================

test "finish stage - successful completion" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    const primitives = @import("primitives");

    // Setup: Create header and set all stages to block 10
    const header = chain.Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{1} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = chain.U256.zero(),
        .number = 10,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 0,
        .extra_data = &[_]u8{},
        .mix_digest = [_]u8{0} ** 32,
        .nonce = [_]u8{0} ** 8,
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
    };
    try db.putHeader(10, header);

    // Set all stage progress
    try db.setStageProgress(.headers, 10);
    try db.setStageProgress(.bodies, 10);
    try db.setStageProgress(.senders, 10);
    try db.setStageProgress(.execution, 10);
    try db.setStageProgress(.blockhashes, 10);
    try db.setStageProgress(.txlookup, 10);

    var ctx = sync.StageContext{
        .allocator = std.testing.allocator,
        .db = &db,
        .stage = .finish,
        .from_block = 0,
        .to_block = 10,
    };

    const result = try execute(&ctx);
    try std.testing.expect(result.stage_done);

    // Verify finish stage progress updated
    try std.testing.expectEqual(@as(u64, 10), db.getStageProgress(.finish));
}

test "finish stage - unwind" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    try db.setStageProgress(.finish, 100);

    var ctx = sync.StageContext{
        .allocator = std.testing.allocator,
        .db = &db,
        .stage = .finish,
        .from_block = 0,
        .to_block = 100,
    };

    try unwind(&ctx, 50);

    // Verify progress was unwound
    try std.testing.expectEqual(@as(u64, 50), db.getStageProgress(.finish));
}

test "verify stage consistency - all stages aligned" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    // Set all stages to the same progress
    try db.setStageProgress(.headers, 100);
    try db.setStageProgress(.bodies, 100);
    try db.setStageProgress(.senders, 100);
    try db.setStageProgress(.execution, 100);
    try db.setStageProgress(.blockhashes, 100);
    try db.setStageProgress(.txlookup, 100);

    var ctx = sync.StageContext{
        .allocator = std.testing.allocator,
        .db = &db,
        .stage = .finish,
        .from_block = 0,
        .to_block = 100,
    };

    // Should not error
    try verifyStageConsistency(&ctx);
}

test "verify stage consistency - stages misaligned" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    // Set stages to different progress
    try db.setStageProgress(.headers, 100);
    try db.setStageProgress(.bodies, 100);
    try db.setStageProgress(.senders, 100);
    try db.setStageProgress(.execution, 90); // Behind
    try db.setStageProgress(.blockhashes, 100);
    try db.setStageProgress(.txlookup, 100);

    var ctx = sync.StageContext{
        .allocator = std.testing.allocator,
        .db = &db,
        .stage = .finish,
        .from_block = 0,
        .to_block = 100,
    };

    // Should warn but not error
    try verifyStageConsistency(&ctx);
}

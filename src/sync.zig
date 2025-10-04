//! Staged sync engine - Erigon's core innovation
//! Each stage runs to completion before the next stage begins
//! Based on erigon/turbo/stages/stageloop.go

const std = @import("std");
const database = @import("database.zig");

/// Stage execution order - critical for correctness
/// Each stage depends on data from previous stages
pub const STAGE_ORDER = [_]database.Stage{
    .headers, // 1. Download block headers first
    .bodies, // 2. Download block bodies (requires headers)
    .senders, // 3. Recover transaction senders (requires bodies)
    .execution, // 4. Execute transactions (requires senders)
    .blockhashes, // 5. Index block hashes (requires headers)
    .txlookup, // 6. Index transaction hashes (requires bodies)
    .finish, // 7. Finalize sync (requires all stages)
};

pub const SyncError = error{
    StageExecutionFailed,
    UnwindFailed,
    InvalidStageOrder,
    OutOfMemory,
};

/// Stage execution context
pub const StageContext = struct {
    allocator: std.mem.Allocator,
    db: *database.Database,
    stage: database.Stage,
    from_block: u64,
    to_block: u64,
};

/// Stage execution result
pub const StageResult = struct {
    blocks_processed: u64,
    stage_done: bool,
};

/// Stage interface - each stage implements these functions
pub const StageInterface = struct {
    /// Execute the stage forward
    executeFn: *const fn (ctx: *StageContext) anyerror!StageResult,
    /// Unwind the stage (for chain reorgs)
    unwindFn: *const fn (ctx: *StageContext, unwind_to: u64) anyerror!void,
};

/// Staged sync engine orchestrating all stages
pub const StagedSync = struct {
    allocator: std.mem.Allocator,
    db: *database.Database,
    stages: []const StageDef,
    target_block: u64,
    sync_started_at: i64,
    total_blocks_processed: u64,

    pub const StageDef = struct {
        stage: database.Stage,
        interface: StageInterface,
    };

    pub fn init(allocator: std.mem.Allocator, db: *database.Database, stages: []const StageDef) StagedSync {
        return .{
            .allocator = allocator,
            .db = db,
            .stages = stages,
            .target_block = 0,
            .sync_started_at = 0,
            .total_blocks_processed = 0,
        };
    }

    /// Run all stages to sync to target block
    /// This is the main entry point for staged sync
    pub fn run(self: *StagedSync, target_block: u64) !void {
        self.target_block = target_block;
        self.sync_started_at = std.time.timestamp();
        self.total_blocks_processed = 0;

        std.log.info("Starting staged sync to block {}", .{target_block});

        // Verify stages are in correct order
        try self.verifyStageOrder();

        // Run each stage in order
        for (self.stages) |stage_def| {
            const stage_start = std.time.milliTimestamp();
            try self.runStage(stage_def);
            const stage_elapsed = std.time.milliTimestamp() - stage_start;

            const progress = self.db.getStageProgress(stage_def.stage);
            std.log.info("Stage {s} completed in {}ms (block {})", .{
                stage_def.stage.toString(),
                stage_elapsed,
                progress,
            });
        }

        const total_elapsed = std.time.timestamp() - self.sync_started_at;
        std.log.info("Staged sync complete: {} blocks in {}s", .{
            self.total_blocks_processed,
            total_elapsed,
        });
    }

    /// Run staged sync with incremental progress updates
    /// Useful for long-running syncs that need resumability
    pub fn runIncremental(self: *StagedSync, target_block: u64, checkpoint_interval: u64) !void {
        self.target_block = target_block;
        self.sync_started_at = std.time.timestamp();
        self.total_blocks_processed = 0;

        std.log.info("Starting incremental staged sync to block {} (checkpoint every {} blocks)", .{
            target_block,
            checkpoint_interval,
        });

        var current_checkpoint: u64 = checkpoint_interval;
        while (current_checkpoint <= target_block) {
            const checkpoint_target = @min(current_checkpoint, target_block);

            std.log.info("Syncing to checkpoint {}", .{checkpoint_target});
            try self.run(checkpoint_target);

            current_checkpoint += checkpoint_interval;
        }

        // Handle remaining blocks if target isn't aligned to checkpoint
        if (current_checkpoint - checkpoint_interval < target_block) {
            try self.run(target_block);
        }
    }

    fn verifyStageOrder(self: *StagedSync) !void {
        // Verify that stages match expected order
        if (self.stages.len != STAGE_ORDER.len) {
            std.log.err("Stage count mismatch: expected {}, got {}", .{
                STAGE_ORDER.len,
                self.stages.len,
            });
            return SyncError.InvalidStageOrder;
        }

        for (self.stages, 0..) |stage_def, i| {
            if (stage_def.stage != STAGE_ORDER[i]) {
                std.log.err("Stage order violation at index {}: expected {s}, got {s}", .{
                    i,
                    STAGE_ORDER[i].toString(),
                    stage_def.stage.toString(),
                });
                return SyncError.InvalidStageOrder;
            }
        }
    }

    fn runStage(self: *StagedSync, stage_def: StageDef) !void {
        const progress = self.db.getStageProgress(stage_def.stage);

        if (progress >= self.target_block) {
            // Stage already synced to target
            std.log.debug("Stage {s} already at block {} (target: {})", .{
                stage_def.stage.toString(),
                progress,
                self.target_block,
            });
            return;
        }

        // Check dependencies: ensure previous stages have caught up
        try self.checkStageDependencies(stage_def.stage, progress);

        std.log.info("Stage {s}: syncing from {} to {}", .{
            stage_def.stage.toString(),
            progress,
            self.target_block,
        });

        var ctx = StageContext{
            .allocator = self.allocator,
            .db = self.db,
            .stage = stage_def.stage,
            .from_block = progress,
            .to_block = self.target_block,
        };

        const result = stage_def.interface.executeFn(&ctx) catch |err| {
            std.log.err("Stage {s} failed: {}", .{ stage_def.stage.toString(), err });
            return SyncError.StageExecutionFailed;
        };

        if (result.stage_done) {
            const new_progress = progress + result.blocks_processed;
            try self.db.setStageProgress(stage_def.stage, new_progress);
            self.total_blocks_processed += result.blocks_processed;

            std.log.info("Stage {s}: processed {} blocks, now at block {}", .{
                stage_def.stage.toString(),
                result.blocks_processed,
                new_progress,
            });
        } else {
            std.log.warn("Stage {s} not complete (processed {} blocks)", .{
                stage_def.stage.toString(),
                result.blocks_processed,
            });
        }
    }

    /// Check that prerequisite stages have progressed sufficiently
    fn checkStageDependencies(self: *StagedSync, stage: database.Stage, current_progress: u64) !void {
        // Define stage dependencies
        const required_stages: []const database.Stage = switch (stage) {
            .headers => &.{}, // No dependencies
            .bodies => &.{.headers}, // Requires headers
            .senders => &.{.bodies}, // Requires bodies
            .execution => &.{.senders}, // Requires senders
            .blockhashes => &.{.headers}, // Requires headers
            .txlookup => &.{.bodies}, // Requires bodies
            .finish => &.{ .headers, .bodies, .senders, .execution, .blockhashes, .txlookup }, // Requires all
        };

        for (required_stages) |required_stage| {
            const required_progress = self.db.getStageProgress(required_stage);
            if (required_progress < current_progress) {
                std.log.warn("Stage dependency warning: {s} at block {} but {s} only at {}", .{
                    stage.toString(),
                    current_progress,
                    required_stage.toString(),
                    required_progress,
                });
            }
        }
    }

    /// Unwind stages to handle chain reorganization
    /// Unwinds in reverse order to maintain consistency
    pub fn unwind(self: *StagedSync, unwind_to: u64) !void {
        std.log.info("Unwinding all stages to block {}", .{unwind_to});

        // Unwind in reverse order - critical for correctness
        var i = self.stages.len;
        while (i > 0) {
            i -= 1;
            const stage_def = self.stages[i];
            const progress = self.db.getStageProgress(stage_def.stage);

            if (progress > unwind_to) {
                std.log.info("Unwinding stage {s} from {} to {}", .{
                    stage_def.stage.toString(),
                    progress,
                    unwind_to,
                });

                var ctx = StageContext{
                    .allocator = self.allocator,
                    .db = self.db,
                    .stage = stage_def.stage,
                    .from_block = unwind_to,
                    .to_block = progress,
                };

                stage_def.interface.unwindFn(&ctx, unwind_to) catch |err| {
                    std.log.err("Unwind of stage {s} failed: {}", .{ stage_def.stage.toString(), err });
                    return SyncError.UnwindFailed;
                };

                try self.db.setStageProgress(stage_def.stage, unwind_to);
            }
        }

        std.log.info("Unwind complete to block {}", .{unwind_to});
    }

    /// Unwind a specific stage (and all dependent stages)
    pub fn unwindStage(self: *StagedSync, target_stage: database.Stage, unwind_to: u64) !void {
        std.log.info("Unwinding stage {s} to block {}", .{ target_stage.toString(), unwind_to });

        // Find the target stage index
        var stage_index: ?usize = null;
        for (self.stages, 0..) |stage_def, i| {
            if (stage_def.stage == target_stage) {
                stage_index = i;
                break;
            }
        }

        if (stage_index == null) {
            std.log.err("Stage {s} not found in staged sync", .{target_stage.toString()});
            return SyncError.InvalidStageOrder;
        }

        // Unwind from the end to the target stage
        var i = self.stages.len;
        while (i > stage_index.?) {
            i -= 1;
            const stage_def = self.stages[i];
            const progress = self.db.getStageProgress(stage_def.stage);

            if (progress > unwind_to) {
                var ctx = StageContext{
                    .allocator = self.allocator,
                    .db = self.db,
                    .stage = stage_def.stage,
                    .from_block = unwind_to,
                    .to_block = progress,
                };

                stage_def.interface.unwindFn(&ctx, unwind_to) catch |err| {
                    std.log.err("Unwind of stage {s} failed: {}", .{ stage_def.stage.toString(), err });
                    return SyncError.UnwindFailed;
                };

                try self.db.setStageProgress(stage_def.stage, unwind_to);
            }
        }
    }

    /// Get current sync status with detailed metrics
    pub fn getStatus(self: *StagedSync) SyncStatus {
        const stage_count = @min(self.stages.len, 16);
        var stage_status: [16]StageStatus = undefined;

        var min_progress: u64 = std.math.maxInt(u64);
        var max_progress: u64 = 0;

        for (self.stages, 0..) |stage_def, i| {
            if (i >= stage_count) break;
            const progress = self.db.getStageProgress(stage_def.stage);

            if (progress < min_progress) min_progress = progress;
            if (progress > max_progress) max_progress = progress;

            stage_status[i] = .{
                .name = stage_def.stage.toString(),
                .current_block = progress,
            };
        }

        const current_block = if (min_progress == std.math.maxInt(u64)) 0 else min_progress;
        const is_syncing = current_block < self.target_block;

        return SyncStatus{
            .target_block = self.target_block,
            .current_block = current_block,
            .highest_block = max_progress,
            .is_syncing = is_syncing,
            .stages = stage_status[0..stage_count],
        };
    }

    /// Get sync progress percentage
    pub fn getSyncProgress(self: *StagedSync) f64 {
        if (self.target_block == 0) return 100.0;

        var total_progress: u64 = 0;
        for (self.stages) |stage_def| {
            total_progress += self.db.getStageProgress(stage_def.stage);
        }

        const total_possible = self.target_block * self.stages.len;
        if (total_possible == 0) return 100.0;

        const progress = @as(f64, @floatFromInt(total_progress)) / @as(f64, @floatFromInt(total_possible));
        return progress * 100.0;
    }
};

pub const SyncStatus = struct {
    target_block: u64,
    current_block: u64,
    highest_block: u64,
    is_syncing: bool,
    stages: []const StageStatus,
};

pub const StageStatus = struct {
    name: []const u8,
    current_block: u64,
};

test "staged sync execution" {
    const TestStage = struct {
        fn execute(ctx: *StageContext) !StageResult {
            _ = ctx;
            return StageResult{
                .blocks_processed = 10,
                .stage_done = true,
            };
        }

        fn unwind(ctx: *StageContext, unwind_to: u64) !void {
            _ = ctx;
            _ = unwind_to;
        }
    };

    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    const stages = [_]StagedSync.StageDef{
        .{
            .stage = .headers,
            .interface = .{
                .executeFn = TestStage.execute,
                .unwindFn = TestStage.unwind,
            },
        },
    };

    var sync_engine = StagedSync.init(std.testing.allocator, &db, &stages);
    try sync_engine.run(100);

    const progress = db.getStageProgress(.headers);
    try std.testing.expectEqual(@as(u64, 10), progress);
}

test "staged sync status" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    try db.setStageProgress(.headers, 50);
    try db.setStageProgress(.execution, 30);

    const stages = [_]StagedSync.StageDef{};
    var sync_engine = StagedSync.init(std.testing.allocator, &db, &stages);
    sync_engine.target_block = 100;

    const status = sync_engine.getStatus();
    try std.testing.expectEqual(@as(u64, 100), status.target_block);
}

test "stage order verification" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    const TestStage = struct {
        fn execute(ctx: *StageContext) !StageResult {
            _ = ctx;
            return StageResult{ .blocks_processed = 0, .stage_done = true };
        }
        fn unwind(ctx: *StageContext, unwind_to: u64) !void {
            _ = ctx;
            _ = unwind_to;
        }
    };

    // Correct order
    const correct_stages = [_]StagedSync.StageDef{
        .{ .stage = .headers, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .bodies, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .senders, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .execution, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .blockhashes, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .txlookup, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .finish, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
    };

    var sync_engine = StagedSync.init(std.testing.allocator, &db, &correct_stages);
    try sync_engine.run(10);
}

test "unwind all stages" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    const TestStage = struct {
        fn execute(ctx: *StageContext) !StageResult {
            _ = ctx;
            return StageResult{ .blocks_processed = 10, .stage_done = true };
        }
        fn unwind(ctx: *StageContext, unwind_to: u64) !void {
            _ = ctx;
            _ = unwind_to;
        }
    };

    // Setup: Set all stages to block 100
    try db.setStageProgress(.headers, 100);
    try db.setStageProgress(.bodies, 100);
    try db.setStageProgress(.senders, 100);
    try db.setStageProgress(.execution, 100);
    try db.setStageProgress(.blockhashes, 100);
    try db.setStageProgress(.txlookup, 100);
    try db.setStageProgress(.finish, 100);

    const stages = [_]StagedSync.StageDef{
        .{ .stage = .headers, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .bodies, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .senders, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .execution, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .blockhashes, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .txlookup, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .finish, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
    };

    var sync_engine = StagedSync.init(std.testing.allocator, &db, &stages);
    try sync_engine.unwind(50);

    // Verify all stages unwound
    try std.testing.expectEqual(@as(u64, 50), db.getStageProgress(.headers));
    try std.testing.expectEqual(@as(u64, 50), db.getStageProgress(.bodies));
    try std.testing.expectEqual(@as(u64, 50), db.getStageProgress(.execution));
    try std.testing.expectEqual(@as(u64, 50), db.getStageProgress(.finish));
}

test "sync progress calculation" {
    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    const TestStage = struct {
        fn execute(ctx: *StageContext) !StageResult {
            _ = ctx;
            return StageResult{ .blocks_processed = 0, .stage_done = true };
        }
        fn unwind(ctx: *StageContext, unwind_to: u64) !void {
            _ = ctx;
            _ = unwind_to;
        }
    };

    const stages = [_]StagedSync.StageDef{
        .{ .stage = .headers, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .bodies, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .senders, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .execution, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .blockhashes, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .txlookup, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
        .{ .stage = .finish, .interface = .{ .executeFn = TestStage.execute, .unwindFn = TestStage.unwind } },
    };

    var sync_engine = StagedSync.init(std.testing.allocator, &db, &stages);
    sync_engine.target_block = 100;

    // All stages at 0
    try std.testing.expectEqual(@as(f64, 0.0), sync_engine.getSyncProgress());

    // All stages at 50 (halfway)
    try db.setStageProgress(.headers, 50);
    try db.setStageProgress(.bodies, 50);
    try db.setStageProgress(.senders, 50);
    try db.setStageProgress(.execution, 50);
    try db.setStageProgress(.blockhashes, 50);
    try db.setStageProgress(.txlookup, 50);
    try db.setStageProgress(.finish, 50);

    const progress = sync_engine.getSyncProgress();
    try std.testing.expect(progress > 49.0 and progress < 51.0);
}

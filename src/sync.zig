//! Staged sync engine - Erigon's core innovation
//! Each stage runs to completion before the next stage begins

const std = @import("std");
const database = @import("database.zig");

pub const SyncError = error{
    StageExecutionFailed,
    UnwindFailed,
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
        };
    }

    /// Run all stages to sync to target block
    pub fn run(self: *StagedSync, target_block: u64) !void {
        self.target_block = target_block;

        for (self.stages) |stage_def| {
            try self.runStage(stage_def);
        }
    }

    fn runStage(self: *StagedSync, stage_def: StageDef) !void {
        const progress = self.db.getStageProgress(stage_def.stage);

        if (progress >= self.target_block) {
            // Stage already synced
            return;
        }

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
            try self.db.setStageProgress(stage_def.stage, progress + result.blocks_processed);
            std.log.info("Stage {s}: processed {} blocks, now at block {}", .{
                stage_def.stage.toString(),
                result.blocks_processed,
                progress + result.blocks_processed,
            });
        }
    }

    /// Unwind stages to handle chain reorganization
    pub fn unwind(self: *StagedSync, unwind_to: u64) !void {
        // Unwind in reverse order
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
    }

    /// Get current sync status
    pub fn getStatus(self: *StagedSync) SyncStatus {
        // Calculate how many stages we have
        const stage_count = @min(self.stages.len, 16);
        var stage_status: [16]StageStatus = undefined;

        for (self.stages, 0..) |stage_def, i| {
            if (i >= stage_count) break;
            const progress = self.db.getStageProgress(stage_def.stage);
            stage_status[i] = .{
                .name = stage_def.stage.toString(),
                .current_block = progress,
            };
        }

        return SyncStatus{
            .target_block = self.target_block,
            .stages = stage_status[0..stage_count],
        };
    }
};

pub const SyncStatus = struct {
    target_block: u64,
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

//! Finish stage: Finalize sync and update chain head
//! This is the final stage that commits all changes and updates the canonical chain

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const database = @import("../database.zig");

pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
    std.log.info("Finish stage: finalizing sync to block {}", .{ctx.to_block});

    // Get latest header to set as chain head
    const latest_header = ctx.db.getHeader(ctx.to_block);

    if (latest_header) |header| {
        // Update chain head
        std.log.info("Setting chain head to block {} (hash: {})", .{
            header.number,
            std.fmt.fmtSliceHexLower(&(try header.hash(ctx.allocator))[0..8]),
        });

        // In production: update head block hash, head header hash, etc.
        // For minimal implementation: just log completion
    }

    // Mark all stages as complete
    try ctx.db.setStageProgress(.finish, ctx.to_block);

    return sync.StageResult{
        .blocks_processed = 0,
        .stage_done = true,
    };
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("Finish stage: unwinding to block {}", .{unwind_to});

    // Revert chain head
    try ctx.db.setStageProgress(.finish, unwind_to);
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
};

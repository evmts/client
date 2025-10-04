//! Example: Custom Stage Implementation
//!
//! This example shows how to implement a custom sync stage and integrate it
//! into the staged sync pipeline.
//!
//! Usage:
//!   zig build-exe custom_stage.zig
//!   ./custom_stage

const std = @import("std");
const sync = @import("../sync.zig");
const database = @import("../database.zig");

/// Custom stage that validates block timestamps
pub const TimestampValidation = struct {
    pub const interface = sync.StageInterface{
        .executeFn = execute,
        .unwindFn = unwind,
    };

    /// Execute the timestamp validation stage
    pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
        std.log.info("=== Timestamp Validation Stage ===", .{});
        std.log.info("Validating blocks {} to {}", .{ ctx.from_block, ctx.to_block });

        var blocks_processed: u64 = 0;
        var blocks_invalid: u64 = 0;

        var block_num = ctx.from_block + 1;
        while (block_num <= ctx.to_block) : (block_num += 1) {
            // Get header
            const header = ctx.db.getHeader(block_num) orelse {
                std.log.warn("Block {} not found, skipping", .{block_num});
                continue;
            };

            // Validate timestamp
            if (block_num > 1) {
                const parent = ctx.db.getHeader(block_num - 1) orelse {
                    std.log.warn("Parent block {} not found", .{block_num - 1});
                    continue;
                };

                if (header.timestamp <= parent.timestamp) {
                    std.log.err("Block {} has invalid timestamp: {} <= parent {}", .{
                        block_num,
                        header.timestamp,
                        parent.timestamp,
                    });
                    blocks_invalid += 1;
                }
            }

            // Check timestamp is not too far in future
            const current_time = @as(u64, @intCast(std.time.timestamp()));
            const max_future_time = 15; // 15 seconds allowed drift

            if (header.timestamp > current_time + max_future_time) {
                std.log.warn("Block {} timestamp {} is {} seconds in the future", .{
                    block_num,
                    header.timestamp,
                    header.timestamp - current_time,
                });
            }

            blocks_processed += 1;

            // Progress logging every 100 blocks
            if (blocks_processed % 100 == 0) {
                std.log.info("Validated {} blocks, {} invalid timestamps", .{
                    blocks_processed,
                    blocks_invalid,
                });
            }
        }

        std.log.info("Timestamp validation complete:", .{});
        std.log.info("  Blocks processed: {}", .{blocks_processed});
        std.log.info("  Invalid timestamps: {}", .{blocks_invalid});

        return sync.StageResult{
            .blocks_processed = blocks_processed,
            .stage_done = true,
        };
    }

    /// Unwind the stage (nothing to do for validation)
    pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
        std.log.info("Unwinding timestamp validation to block {}", .{unwind_to});
        _ = ctx;
        // Validation stage doesn't store data, so nothing to unwind
    }
};

/// Custom stage that calculates statistics
pub const BlockStatistics = struct {
    pub const interface = sync.StageInterface{
        .executeFn = execute,
        .unwindFn = unwind,
    };

    pub fn execute(ctx: *sync.StageContext) !sync.StageResult {
        std.log.info("=== Block Statistics Stage ===", .{});

        var total_gas_used: u64 = 0;
        var total_transactions: u64 = 0;
        var blocks_processed: u64 = 0;

        var block_num = ctx.from_block + 1;
        while (block_num <= ctx.to_block) : (block_num += 1) {
            const header = ctx.db.getHeader(block_num) orelse continue;
            const body = ctx.db.getBody(block_num) orelse continue;

            total_gas_used += header.gas_used;
            total_transactions += body.transactions.len;
            blocks_processed += 1;
        }

        const avg_gas = if (blocks_processed > 0)
            total_gas_used / blocks_processed
        else
            0;

        const avg_txs = if (blocks_processed > 0)
            @as(f64, @floatFromInt(total_transactions)) / @as(f64, @floatFromInt(blocks_processed))
        else
            0.0;

        std.log.info("Statistics:", .{});
        std.log.info("  Blocks: {}", .{blocks_processed});
        std.log.info("  Total gas used: {}", .{total_gas_used});
        std.log.info("  Total transactions: {}", .{total_transactions});
        std.log.info("  Avg gas per block: {}", .{avg_gas});
        std.log.info("  Avg txs per block: {d:.2}", .{avg_txs});

        return sync.StageResult{
            .blocks_processed = blocks_processed,
            .stage_done = true,
        };
    }

    pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
        _ = ctx;
        _ = unwind_to;
        // Statistics are ephemeral, nothing to unwind
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Custom Stage Example ===", .{});

    // Setup database and populate with test data
    var db = database.Database.init(allocator);
    defer db.deinit();

    std.log.info("\nPopulating test data...", .{});
    // In a real scenario, this would be populated by the Headers and Bodies stages
    // For this example, we'll create some test blocks

    // Create test blocks
    var i: u64 = 1;
    while (i <= 100) : (i += 1) {
        const header = @import("../chain.zig").BlockHeader{
            .parent_hash = [_]u8{0} ** 32,
            .uncle_hash = [_]u8{0} ** 32,
            .coinbase = [_]u8{0} ** 20,
            .state_root = [_]u8{0} ** 32,
            .transactions_root = [_]u8{0} ** 32,
            .receipts_root = [_]u8{0} ** 32,
            .logs_bloom = [_]u8{0} ** 256,
            .difficulty = 1000,
            .number = i,
            .gas_limit = 10000000,
            .gas_used = 5000000 + (i * 1000), // Increasing gas usage
            .timestamp = 1234567890 + (i * 15), // 15 second blocks
            .extra_data = &[_]u8{},
            .mix_hash = [_]u8{0} ** 32,
            .nonce = 0,
            .base_fee_per_gas = null,
            .withdrawals_root = null,
            .blob_gas_used = null,
            .excess_blob_gas = null,
            .parent_beacon_block_root = null,
        };

        try db.putHeader(i, header);

        const body = @import("../chain.zig").BlockBody{
            .transactions = &[_]@import("../chain.zig").Transaction{},
            .uncles = &[_]@import("../chain.zig").BlockHeader{},
        };

        try db.putBody(i, body);
    }

    std.log.info("Created 100 test blocks", .{});

    // Create staged sync with custom stages
    std.log.info("\nSetting up staged sync with custom stages...", .{});

    const stages = [_]sync.StagedSync.StageDef{
        // First, run timestamp validation
        .{
            .stage = .headers, // Reuse stage enum, or extend it
            .interface = TimestampValidation.interface,
        },
        // Then, run statistics
        .{
            .stage = .bodies,
            .interface = BlockStatistics.interface,
        },
    };

    var sync_engine = sync.StagedSync.init(allocator, &db, &stages);

    // Run sync
    std.log.info("\nRunning staged sync...", .{});
    try sync_engine.run(100);

    std.log.info("\n=== Sync Complete ===", .{});

    // Show how to add custom stages to full pipeline
    std.log.info("\n=== Integration with Full Pipeline ===", .{});
    std.log.info("To integrate custom stages into a full node:", .{});
    std.log.info("", .{});
    std.log.info("const stages = [_]sync.StagedSync.StageDef{{", .{});
    std.log.info("    // Standard stages", .{});
    std.log.info("    .{{ .stage = .headers, .interface = headers_stage.interface }},", .{});
    std.log.info("    .{{ .stage = .bodies, .interface = bodies_stage.interface }},", .{});
    std.log.info("    .{{ .stage = .senders, .interface = senders_stage.interface }},", .{});
    std.log.info("    .{{ .stage = .execution, .interface = execution_stage.interface }},", .{});
    std.log.info("    ", .{});
    std.log.info("    // Custom validation stage", .{});
    std.log.info("    .{{ .stage = .custom1, .interface = TimestampValidation.interface }},", .{});
    std.log.info("    ", .{});
    std.log.info("    // More standard stages", .{});
    std.log.info("    .{{ .stage = .txlookup, .interface = txlookup_stage.interface }},", .{});
    std.log.info("    ", .{});
    std.log.info("    // Custom statistics stage", .{});
    std.log.info("    .{{ .stage = .custom2, .interface = BlockStatistics.interface }},", .{});
    std.log.info("    ", .{});
    std.log.info("    .{{ .stage = .finish, .interface = finish_stage.interface }},", .{});
    std.log.info("}};", .{});

    std.log.info("\nExample complete!", .{});
}

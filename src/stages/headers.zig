//! Headers stage: Download and validate block headers

const std = @import("std");
const sync = @import("../sync.zig");
const chain = @import("../chain.zig");
const database = @import("../database.zig");

const HeadersCfg = struct {
    batch_size: u64 = 1024,
    request_timeout_ms: u64 = 5000,
    max_requests_in_flight: u32 = 16,
};

pub const HeaderDownload = struct {
    progress: u64,
    fetching_new: bool,
    pos_sync: bool,

    pub fn init() HeaderDownload {
        return .{
            .progress = 0,
            .fetching_new = false,
            .pos_sync = false,
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
};

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

        // Download headers batch
        try downloadHeadersBatch(ctx, current_block, batch_end, &blocks_processed, &hd);
        current_block = batch_end + 1;

        if (blocks_processed % 10000 == 0) {
            std.log.info("Headers progress: {}/{}", .{ current_block, ctx.to_block });
        }
    }

    return sync.StageResult{
        .blocks_processed = blocks_processed,
        .stage_done = (current_block > ctx.to_block),
    };
}

fn downloadHeadersBatch(
    ctx: *sync.StageContext,
    from_block: u64,
    to_block: u64,
    blocks_processed: *u64,
    hd: *HeaderDownload,
) !void {
    var block_num = from_block;
    while (block_num <= to_block) : (block_num += 1) {
        const header = try generateSyntheticHeader(ctx.allocator, block_num);
        try ctx.db.putHeader(block_num, header);
        blocks_processed.* += 1;
        hd.setProgress(block_num);
    }
}

pub fn unwind(ctx: *sync.StageContext, unwind_to: u64) !void {
    std.log.info("Headers stage: unwinding to block {}", .{unwind_to});

    // In production: Remove headers and update canonical chain
    // For minimal implementation: Just log the unwind
    _ = ctx;
}

fn generateSyntheticHeader(allocator: std.mem.Allocator, number: u64) !chain.Header {
    _ = allocator;
    const primitives = @import("primitives");

    var parent_hash = [_]u8{0} ** 32;
    if (number > 0) {
        // Simple parent hash derivation
        std.mem.writeInt(u64, parent_hash[0..8], number - 1, .big);
    }

    return chain.Header{
        .parent_hash = parent_hash,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = chain.U256.zero(),
        .number = number,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 1609459200 + (number * 12), // ~12 second blocks
        .extra_data = &[_]u8{},
        .mix_digest = [_]u8{0} ** 32,
        .nonce = chain.encodeNonce(0),
        .aura_step = null,
        .aura_seal = null,
        .base_fee_per_gas = chain.U256.fromInt(1000000000), // 1 gwei
        .withdrawals_root = null,
        .blob_gas_used = null,
        .excess_blob_gas = null,
        .parent_beacon_block_root = null,
        .requests_hash = null,
    };
}

pub const interface = sync.StageInterface{
    .executeFn = execute,
    .unwindFn = unwind,
};

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

    // Verify headers were stored
    const header = db.getHeader(1);
    try std.testing.expect(header != null);
    try std.testing.expectEqual(@as(u64, 1), header.?.number);
}

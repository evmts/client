//! Node orchestration - coordinates all components

const std = @import("std");
const database = @import("database.zig");
const sync = @import("sync.zig");
const chain = @import("chain.zig");

// Import stages
const headers_stage = @import("stages/headers.zig");
const bodies_stage = @import("stages/bodies.zig");
const execution_stage = @import("stages/execution.zig");

pub const NodeConfig = struct {
    data_dir: []const u8,
    chain_id: u64,
    network_id: u64,
    max_peers: u32,
    sync_target: u64,

    pub fn default() NodeConfig {
        return .{
            .data_dir = "./data",
            .chain_id = 1, // Mainnet
            .network_id = 1,
            .max_peers = 50,
            .sync_target = 1000, // Sync to block 1000 for testing
        };
    }
};

pub const NodeError = error{
    InitializationFailed,
    SyncFailed,
    OutOfMemory,
};

/// Ethereum node
pub const Node = struct {
    allocator: std.mem.Allocator,
    config: NodeConfig,
    db: database.Database,
    sync_engine: sync.StagedSync,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, config: NodeConfig) !Node {
        var db = database.Database.init(allocator);
        errdefer db.deinit();

        // Configure stages
        const stages = [_]sync.StagedSync.StageDef{
            .{
                .stage = .headers,
                .interface = headers_stage.interface,
            },
            .{
                .stage = .bodies,
                .interface = bodies_stage.interface,
            },
            .{
                .stage = .execution,
                .interface = execution_stage.interface,
            },
        };

        const sync_engine = sync.StagedSync.init(allocator, &db, &stages);

        return .{
            .allocator = allocator,
            .config = config,
            .db = db,
            .sync_engine = sync_engine,
            .running = false,
        };
    }

    pub fn deinit(self: *Node) void {
        self.db.deinit();
    }

    /// Start the node
    pub fn start(self: *Node) !void {
        std.log.info("Starting Guillotine node...", .{});
        std.log.info("Chain ID: {}", .{self.config.chain_id});
        std.log.info("Data directory: {s}", .{self.config.data_dir});

        self.running = true;

        // Start sync
        std.log.info("Starting sync to block {}...", .{self.config.sync_target});
        try self.syncToTarget();

        std.log.info("Node sync complete!", .{});
    }

    /// Stop the node
    pub fn stop(self: *Node) void {
        std.log.info("Stopping node...", .{});
        self.running = false;
    }

    /// Sync to target block
    fn syncToTarget(self: *Node) !void {
        try self.sync_engine.run(self.config.sync_target);
    }

    /// Get sync status
    pub fn getSyncStatus(self: *Node) sync.SyncStatus {
        return self.sync_engine.getStatus();
    }

    /// Get latest block number
    pub fn getLatestBlock(self: *Node) ?u64 {
        const header = self.db.getLatestHeader() orelse return null;
        return header.number;
    }

    /// Get block by number
    pub fn getBlock(self: *Node, number: u64) ?chain.Block {
        const header = self.db.getHeader(number) orelse return null;
        const body = self.db.getBody(number) orelse return null;

        return chain.Block{
            .header = header,
            .transactions = body.transactions,
            .uncles = body.uncles,
        };
    }

    /// Handle chain reorganization
    pub fn handleReorg(self: *Node, new_head: u64) !void {
        std.log.warn("Chain reorganization detected! Unwinding to block {}", .{new_head});
        try self.sync_engine.unwind(new_head);
    }

    /// Print node status
    pub fn printStatus(self: *Node) void {
        const status = self.getSyncStatus();

        std.log.info("=== Node Status ===", .{});
        std.log.info("Target block: {}", .{status.target_block});
        std.log.info("Stages:", .{});

        for (status.stages) |stage_status| {
            const progress_pct = if (status.target_block > 0)
                @as(f64, @floatFromInt(stage_status.current_block)) / @as(f64, @floatFromInt(status.target_block)) * 100.0
            else
                0.0;

            std.log.info("  {s}: {} / {} ({d:.1}%)", .{
                stage_status.name,
                stage_status.current_block,
                status.target_block,
                progress_pct,
            });
        }

        if (self.getLatestBlock()) |latest| {
            std.log.info("Latest block: {}", .{latest});
        }
    }
};

test "node initialization" {
    const config = NodeConfig.default();
    var node = try Node.init(std.testing.allocator, config);
    defer node.deinit();

    try std.testing.expectEqual(@as(u64, 1), node.config.chain_id);
    try std.testing.expect(!node.running);
}

test "node sync" {
    const config = NodeConfig{
        .data_dir = "./test_data",
        .chain_id = 1,
        .network_id = 1,
        .max_peers = 10,
        .sync_target = 5,
    };

    var node = try Node.init(std.testing.allocator, config);
    defer node.deinit();

    try node.start();

    const latest = node.getLatestBlock();
    try std.testing.expect(latest != null);
    try std.testing.expect(latest.? >= 5);
}

test "node status" {
    const config = NodeConfig{
        .data_dir = "./test_data",
        .chain_id = 1,
        .network_id = 1,
        .max_peers = 10,
        .sync_target = 10,
    };

    var node = try Node.init(std.testing.allocator, config);
    defer node.deinit();

    const status = node.getSyncStatus();
    try std.testing.expectEqual(@as(u64, 0), status.target_block);
}

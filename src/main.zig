//! Guillotine Ethereum Client
//! A minimal but complete Ethereum execution client written in Zig

const std = @import("std");
const node_mod = @import("node.zig");
const rpc = @import("rpc.zig");
const p2p = @import("p2p.zig");

pub const ClientConfig = struct {
    node_config: node_mod.NodeConfig,
    rpc_port: u16,
    p2p_port: u16,
    enable_rpc: bool,
    enable_p2p: bool,

    pub fn default() ClientConfig {
        return .{
            .node_config = node_mod.NodeConfig.default(),
            .rpc_port = 8545,
            .p2p_port = 30303,
            .enable_rpc = true,
            .enable_p2p = false, // Simplified P2P not fully functional
        };
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: ClientConfig,
    node: node_mod.Node,
    rpc_server: ?rpc.RpcServer,
    network: ?p2p.NetworkManager,

    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) !Client {
        var node = try node_mod.Node.init(allocator, config.node_config);
        errdefer node.deinit();

        const rpc_server = if (config.enable_rpc)
            rpc.RpcServer.init(allocator, &node, config.rpc_port)
        else
            null;

        const network = if (config.enable_p2p) blk: {
            // TODO: Get priv_key from config or generate
            const priv_key = [_]u8{1} ** 32;
            break :blk try p2p.NetworkManager.init(allocator, config.node_config.max_peers, 30303, priv_key);
        } else null;

        return .{
            .allocator = allocator,
            .config = config,
            .node = node,
            .rpc_server = rpc_server,
            .network = network,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.network) |*network| {
            network.deinit();
        }
        self.node.deinit();
    }

    pub fn run(self: *Client) !void {
        std.log.info("╔═══════════════════════════════════════╗", .{});
        std.log.info("║   Guillotine Ethereum Client v0.1.0  ║", .{});
        std.log.info("║   Minimal Erigon-inspired Node       ║", .{});
        std.log.info("╚═══════════════════════════════════════╝", .{});

        // Start RPC server
        if (self.rpc_server) |*server| {
            try server.start();
        }

        // Start P2P network
        if (self.network) |*network| {
            try network.start(self.config.p2p_port);
        }

        // Start node sync
        try self.node.start();

        // Print final status
        self.node.printStatus();
    }

    pub fn stop(self: *Client) void {
        if (self.rpc_server) |*server| {
            server.stop();
        }

        if (self.network) |*network| {
            network.stop();
        }

        self.node.stop();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = ClientConfig.default();
    config.node_config.sync_target = 100; // Sync to block 100

    var client = try Client.init(allocator, config);
    defer client.deinit();

    try client.run();

    std.log.info("Client running. Press Ctrl+C to stop.", .{});

    // In production: Handle signals and run event loop
    // For minimal implementation: Exit after sync
}

test "client initialization" {
    const config = ClientConfig.default();
    var client = try Client.init(std.testing.allocator, config);
    defer client.deinit();

    try std.testing.expect(client.config.rpc_port == 8545);
}

// Re-export all modules for testing
pub const chain = @import("chain.zig");
pub const database = @import("database.zig");
pub const sync = @import("sync.zig");
pub const Node = node_mod.Node;
pub const stages = struct {
    pub const headers = @import("stages/headers.zig");
    pub const bodies = @import("stages/bodies.zig");
    pub const execution = @import("stages/execution.zig");
};

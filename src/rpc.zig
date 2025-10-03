//! JSON-RPC server (simplified)
//! In production: Full Ethereum JSON-RPC API implementation

const std = @import("std");
const node_mod = @import("node.zig");
const chain = @import("chain.zig");

pub const RpcError = error{
    ServerStartFailed,
    InvalidRequest,
    MethodNotFound,
};

/// RPC method handler
pub const RpcMethod = enum {
    eth_blockNumber,
    eth_getBlockByNumber,
    eth_syncing,
    net_version,
    web3_clientVersion,

    pub fn fromString(s: []const u8) ?RpcMethod {
        inline for (@typeInfo(RpcMethod).@"enum".fields) |field| {
            if (std.mem.eql(u8, s, field.name)) {
                return @as(RpcMethod, @enumFromInt(field.value));
            }
        }
        return null;
    }
};

/// RPC server
pub const RpcServer = struct {
    allocator: std.mem.Allocator,
    node: *node_mod.Node,
    port: u16,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, node: *node_mod.Node, port: u16) RpcServer {
        return .{
            .allocator = allocator,
            .node = node,
            .port = port,
            .running = false,
        };
    }

    /// Start the RPC server
    pub fn start(self: *RpcServer) !void {
        self.running = true;
        std.log.info("RPC server listening on port {}", .{self.port});
        // In production: Start HTTP server and handle requests
    }

    /// Stop the RPC server
    pub fn stop(self: *RpcServer) void {
        self.running = false;
        std.log.info("RPC server stopped", .{});
    }

    /// Handle RPC request
    pub fn handleRequest(self: *RpcServer, method: []const u8, params: []const u8) ![]const u8 {
        _ = params;

        const rpc_method = RpcMethod.fromString(method) orelse return RpcError.MethodNotFound;

        return switch (rpc_method) {
            .eth_blockNumber => try self.handleBlockNumber(),
            .eth_syncing => try self.handleSyncing(),
            .net_version => try self.handleNetVersion(),
            .web3_clientVersion => try self.handleClientVersion(),
            .eth_getBlockByNumber => try self.handleGetBlockByNumber(),
        };
    }

    fn handleBlockNumber(self: *RpcServer) ![]const u8 {
        const latest = self.node.getLatestBlock() orelse 0;
        return try std.fmt.allocPrint(self.allocator, "0x{x}", .{latest});
    }

    fn handleSyncing(self: *RpcServer) ![]const u8 {
        const status = self.node.getSyncStatus();
        if (status.stages.len == 0) {
            return "false";
        }

        // Return sync status as JSON
        return try std.fmt.allocPrint(
            self.allocator,
            "{{\"currentBlock\":\"0x{x}\",\"highestBlock\":\"0x{x}\"}}",
            .{ status.stages[0].current_block, status.target_block },
        );
    }

    fn handleNetVersion(self: *RpcServer) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "\"{}\"", .{self.node.config.network_id});
    }

    fn handleClientVersion(self: *RpcServer) ![]const u8 {
        _ = self;
        return "\"Guillotine/v0.1.0/zig\"";
    }

    fn handleGetBlockByNumber(self: *RpcServer) ![]const u8 {
        _ = self;
        // Simplified: Would parse block number from params
        return "null";
    }
};

test "rpc server initialization" {
    var db = @import("database.zig").Database.init(std.testing.allocator);
    defer db.deinit();

    const config = node_mod.NodeConfig.default();
    var node = try node_mod.Node.init(std.testing.allocator, config);
    defer node.deinit();

    var rpc = RpcServer.init(std.testing.allocator, &node, 8545);
    try rpc.start();
    try std.testing.expect(rpc.running);

    rpc.stop();
    try std.testing.expect(!rpc.running);
}

test "rpc method handling" {
    var db = @import("database.zig").Database.init(std.testing.allocator);
    defer db.deinit();

    const config = node_mod.NodeConfig.default();
    var node = try node_mod.Node.init(std.testing.allocator, config);
    defer node.deinit();

    var rpc = RpcServer.init(std.testing.allocator, &node, 8545);

    const result = try rpc.handleRequest("web3_clientVersion", "");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Guillotine") != null);
}

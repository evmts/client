//! JSON-RPC server matching Erigon's RPC implementation
//! Implements Ethereum JSON-RPC API (eth_*, net_*, web3_*)

const std = @import("std");
const node_mod = @import("node.zig");
const chain = @import("chain.zig");
const primitives = @import("primitives");

pub const RpcError = error{
    ServerStartFailed,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
};

/// RPC method handler matching Erigon's supported methods
pub const RpcMethod = enum {
    // eth namespace
    eth_blockNumber,
    eth_getBlockByNumber,
    eth_getBlockByHash,
    eth_getTransactionByHash,
    eth_getTransactionReceipt,
    eth_getBalance,
    eth_getCode,
    eth_getStorageAt,
    eth_call,
    eth_estimateGas,
    eth_sendRawTransaction,
    eth_syncing,
    eth_chainId,
    eth_gasPrice,
    eth_feeHistory,

    // net namespace
    net_version,
    net_peerCount,
    net_listening,

    // web3 namespace
    web3_clientVersion,
    web3_sha3,

    // debug namespace (Erigon-specific)
    debug_traceTransaction,
    debug_traceBlockByNumber,

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
    server_thread: ?std.Thread,
    shutdown_requested: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, node: *node_mod.Node, port: u16) RpcServer {
        return .{
            .allocator = allocator,
            .node = node,
            .port = port,
            .running = false,
            .server_thread = null,
            .shutdown_requested = std.atomic.Value(bool).init(false),
        };
    }

    /// Start the RPC server
    pub fn start(self: *RpcServer) !void {
        self.running = true;
        std.log.info("RPC server listening on port {}", .{self.port});

        // In production: Start HTTP server and handle requests
        // Create TCP listener on the specified port
        const address = try std.net.Address.parseIp("0.0.0.0", self.port);
        var listener = try address.listen(.{
            .reuse_address = true,
        });
        errdefer listener.deinit();

        std.log.info("HTTP server started on http://0.0.0.0:{d}", .{self.port});

        // Spawn thread to handle connections
        self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{ self, listener });
    }

    /// Server event loop - accepts connections and handles HTTP requests
    fn serverLoop(self: *RpcServer, listener_: std.net.Server) void {
        var listener = listener_;
        defer listener.deinit();

        while (!self.shutdown_requested.load(.acquire)) {
            // Accept connection with timeout to allow checking shutdown flag
            const connection = listener.accept() catch |err| {
                if (self.shutdown_requested.load(.acquire)) break;
                std.log.warn("Failed to accept connection: {}", .{err});
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            };

            // Handle request in the same thread (simplified - production would use thread pool)
            self.handleConnection(connection) catch |err| {
                std.log.warn("Error handling connection: {}", .{err});
            };
        }
    }

    /// Handle a single HTTP connection
    fn handleConnection(self: *RpcServer, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        var buffer: [8192]u8 = undefined;
        const bytes_read = try connection.stream.read(&buffer);
        if (bytes_read == 0) return;

        // Parse HTTP request headers (simplified)
        const request_data = buffer[0..bytes_read];

        // Find the JSON-RPC request body (after headers)
        const body_start = std.mem.indexOf(u8, request_data, "\r\n\r\n") orelse return error.InvalidRequest;
        const body = request_data[body_start + 4 ..];

        // Parse JSON-RPC request
        const parsed = std.json.parseFromSlice(
            JsonRpcRequest,
            self.allocator,
            body,
            .{ .ignore_unknown_fields = true },
        ) catch {
            return self.sendErrorResponse(connection.stream, null, -32700, "Parse error");
        };
        defer parsed.deinit();

        const req = parsed.value;

        // Validate JSON-RPC version
        if (!std.mem.eql(u8, req.jsonrpc, "2.0")) {
            return self.sendErrorResponse(connection.stream, req.id, -32600, "Invalid Request");
        }

        // Handle the RPC method
        const result = self.handleRequest(req.method, req.params) catch |err| {
            std.log.warn("Error handling method {s}: {}", .{ req.method, err });
            return self.sendErrorResponse(connection.stream, req.id, -32603, "Internal error");
        };
        defer if (result.len > 0) self.allocator.free(result);

        // Send JSON-RPC response
        try self.sendSuccessResponse(connection.stream, req.id, result);
    }

    /// Send JSON-RPC success response
    fn sendSuccessResponse(self: *RpcServer, stream: std.net.Stream, id: ?std.json.Value, result: []const u8) !void {
        const id_str = if (id) |i| blk: {
            if (i == .integer) {
                break :blk try std.fmt.allocPrint(self.allocator, "{d}", .{i.integer});
            } else if (i == .string) {
                break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{i.string});
            } else {
                break :blk try self.allocator.dupe(u8, "null");
            }
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(id_str);

        const response = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
            .{ id_str, result },
        );
        defer self.allocator.free(response);

        _ = try stream.writeAll(response);
    }

    /// Send JSON-RPC error response
    fn sendErrorResponse(self: *RpcServer, stream: std.net.Stream, id: ?std.json.Value, code: i32, message: []const u8) !void {
        const id_str = if (id) |i| blk: {
            if (i == .integer) {
                break :blk try std.fmt.allocPrint(self.allocator, "{d}", .{i.integer});
            } else if (i == .string) {
                break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{i.string});
            } else {
                break :blk try self.allocator.dupe(u8, "null");
            }
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(id_str);

        const response = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
            .{ id_str, code, message },
        );
        defer self.allocator.free(response);

        _ = try stream.writeAll(response);
    }

    /// JSON-RPC request structure
    const JsonRpcRequest = struct {
        jsonrpc: []const u8,
        method: []const u8,
        params: []const u8,
        id: ?std.json.Value = null,
    };

    /// Stop the RPC server
    pub fn stop(self: *RpcServer) void {
        self.running = false;
        self.shutdown_requested.store(true, .release);

        // Wait for server thread to finish
        if (self.server_thread) |thread| {
            thread.join();
            self.server_thread = null;
        }

        std.log.info("RPC server stopped", .{});
    }

    /// Handle RPC request matching Erigon's API
    pub fn handleRequest(self: *RpcServer, method: []const u8, params: []const u8) ![]const u8 {
        _ = params;

        const rpc_method = RpcMethod.fromString(method) orelse return RpcError.MethodNotFound;

        return switch (rpc_method) {
            // eth namespace
            .eth_blockNumber => try self.handleBlockNumber(),
            .eth_getBlockByNumber => try self.handleGetBlockByNumber(),
            .eth_getBlockByHash => try self.handleGetBlockByHash(),
            .eth_getTransactionByHash => try self.handleGetTransactionByHash(),
            .eth_getTransactionReceipt => try self.handleGetTransactionReceipt(),
            .eth_getBalance => try self.handleGetBalance(),
            .eth_getCode => try self.handleGetCode(),
            .eth_getStorageAt => try self.handleGetStorageAt(),
            .eth_call => try self.handleCall(),
            .eth_estimateGas => try self.handleEstimateGas(),
            .eth_sendRawTransaction => try self.handleSendRawTransaction(),
            .eth_syncing => try self.handleSyncing(),
            .eth_chainId => try self.handleChainId(),
            .eth_gasPrice => try self.handleGasPrice(),
            .eth_feeHistory => try self.handleFeeHistory(),

            // net namespace
            .net_version => try self.handleNetVersion(),
            .net_peerCount => try self.handlePeerCount(),
            .net_listening => try self.handleListening(),

            // web3 namespace
            .web3_clientVersion => try self.handleClientVersion(),
            .web3_sha3 => try self.handleSha3(),

            // debug namespace
            .debug_traceTransaction => try self.handleTraceTransaction(),
            .debug_traceBlockByNumber => try self.handleTraceBlockByNumber(),
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
        // TODO: Parse block number from params and return block
        return "null";
    }

    fn handleGetBlockByHash(self: *RpcServer) ![]const u8 {
        _ = self;
        return "null";
    }

    fn handleGetTransactionByHash(self: *RpcServer) ![]const u8 {
        _ = self;
        return "null";
    }

    fn handleGetTransactionReceipt(self: *RpcServer) ![]const u8 {
        _ = self;
        return "null";
    }

    fn handleGetBalance(self: *RpcServer) ![]const u8 {
        _ = self;
        return "\"0x0\"";
    }

    fn handleGetCode(self: *RpcServer) ![]const u8 {
        _ = self;
        return "\"0x\"";
    }

    fn handleGetStorageAt(self: *RpcServer) ![]const u8 {
        _ = self;
        return "\"0x0000000000000000000000000000000000000000000000000000000000000000\"";
    }

    fn handleCall(self: *RpcServer) ![]const u8 {
        _ = self;
        return "\"0x\"";
    }

    fn handleEstimateGas(self: *RpcServer) ![]const u8 {
        _ = self;
        return "\"0x5208\""; // 21000 gas (minimum for transfer)
    }

    fn handleSendRawTransaction(self: *RpcServer) ![]const u8 {
        _ = self;
        // TODO: Parse and broadcast transaction
        return "\"0x0000000000000000000000000000000000000000000000000000000000000000\"";
    }

    fn handleChainId(self: *RpcServer) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "\"0x{x}\"", .{self.node.config.network_id});
    }

    fn handleGasPrice(self: *RpcServer) ![]const u8 {
        _ = self;
        return "\"0x3b9aca00\""; // 1 gwei
    }

    fn handleFeeHistory(self: *RpcServer) ![]const u8 {
        _ = self;
        return "{}";
    }

    fn handlePeerCount(self: *RpcServer) ![]const u8 {
        // TODO: Access network manager from node context
        const count: usize = 0; // Placeholder
        return try std.fmt.allocPrint(self.allocator, "\"0x{x}\"", .{count});
    }

    fn handleListening(_: *RpcServer) ![]const u8 {
        // TODO: Access network manager from node context
        return "false"; // Placeholder
    }

    fn handleSha3(self: *RpcServer) ![]const u8 {
        _ = self;
        // TODO: Hash data from params
        return "\"0x0000000000000000000000000000000000000000000000000000000000000000\"";
    }

    fn handleTraceTransaction(self: *RpcServer) ![]const u8 {
        _ = self;
        // TODO: Return transaction trace
        return "{}";
    }

    fn handleTraceBlockByNumber(self: *RpcServer) ![]const u8 {
        _ = self;
        // TODO: Return block trace
        return "[]";
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

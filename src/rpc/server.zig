//! HTTP JSON-RPC 2.0 Server for Ethereum Client
//! Based on erigon/rpc server architecture
//! Spec: https://www.jsonrpc.org/specification

const std = @import("std");
const eth_api = @import("eth_api.zig");
const kv = @import("../kv/kv.zig");

/// JSON-RPC 2.0 error codes
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    server_error = -32000,

    pub fn message(self: ErrorCode) []const u8 {
        return switch (self) {
            .parse_error => "Parse error",
            .invalid_request => "Invalid Request",
            .method_not_found => "Method not found",
            .invalid_params => "Invalid params",
            .internal_error => "Internal error",
            .server_error => "Server error",
        };
    }
};

/// JSON-RPC 2.0 Request structure
pub const JsonRpcRequest = struct {
    jsonrpc: []const u8,
    method: []const u8,
    params: std.json.Value = .null,
    id: ?std.json.Value = null,
};

/// JSON-RPC 2.0 Error structure
pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// HTTP JSON-RPC 2.0 Server
pub const Server = struct {
    allocator: std.mem.Allocator,
    db: kv.Database,
    chain_id: u64,
    port: u16,
    eth_api: eth_api.EthApi,
    server_thread: ?std.Thread = null,
    listener: ?std.net.Server = null,
    shutdown_requested: std.atomic.Value(bool),
    running: bool,

    pub fn init(allocator: std.mem.Allocator, db: kv.Database, chain_id: u64, port: u16) Server {
        return .{
            .allocator = allocator,
            .db = db,
            .chain_id = chain_id,
            .port = port,
            .eth_api = eth_api.EthApi.init(allocator, db, chain_id),
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .running = false,
        };
    }

    /// Start HTTP server in background thread
    pub fn start(self: *Server) !void {
        if (self.running) return error.AlreadyRunning;

        // Create TCP listener
        const address = try std.net.Address.parseIp("0.0.0.0", self.port);
        self.listener = try address.listen(.{
            .reuse_address = true,
            .reuse_port = false,
        });

        std.log.info("JSON-RPC server listening on http://0.0.0.0:{d}", .{self.port});

        // Start server thread
        self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});
        self.running = true;
    }

    /// Graceful shutdown
    pub fn stop(self: *Server) void {
        if (!self.running) return;

        self.shutdown_requested.store(true, .release);

        // Wait for server thread to finish
        if (self.server_thread) |thread| {
            thread.join();
            self.server_thread = null;
        }

        // Close listener
        if (self.listener) |*listener| {
            listener.deinit();
            self.listener = null;
        }

        self.running = false;
        std.log.info("JSON-RPC server stopped", .{});
    }

    /// Server event loop
    fn serverLoop(self: *Server) void {
        while (!self.shutdown_requested.load(.acquire)) {
            if (self.listener) |*listener| {
                // Accept connection with timeout
                const connection = listener.accept() catch |err| {
                    if (self.shutdown_requested.load(.acquire)) break;
                    std.log.warn("Failed to accept connection: {}", .{err});
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                    continue;
                };

                // Handle request (in production, use thread pool)
                self.handleConnection(connection) catch |err| {
                    std.log.warn("Error handling connection: {}", .{err});
                };
            } else {
                break;
            }
        }
    }

    /// Handle single HTTP connection
    fn handleConnection(self: *Server, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        // Read request with buffer
        var buffer: [16384]u8 = undefined;
        const bytes_read = try connection.stream.read(&buffer);
        if (bytes_read == 0) return;

        const request_data = buffer[0..bytes_read];

        // Parse HTTP request to extract body
        const body = try self.parseHttpRequest(request_data);

        // Check if batch request (starts with '[')
        if (std.mem.startsWith(u8, body, "[")) {
            try self.handleBatchRequest(connection.stream, body);
        } else {
            try self.handleSingleRequest(connection.stream, body);
        }
    }

    /// Parse HTTP request headers and extract JSON body
    fn parseHttpRequest(self: *Server, request_data: []const u8) ![]const u8 {
        _ = self;

        // Find end of headers
        const header_end = std.mem.indexOf(u8, request_data, "\r\n\r\n") orelse
            return error.InvalidRequest;

        // Extract body
        const body_start = header_end + 4;
        if (body_start >= request_data.len) return error.InvalidRequest;

        return request_data[body_start..];
    }

    /// Handle single JSON-RPC request
    fn handleSingleRequest(self: *Server, stream: std.net.Stream, body: []const u8) !void {
        // Parse JSON-RPC request
        const parsed = std.json.parseFromSlice(
            JsonRpcRequest,
            self.allocator,
            body,
            .{ .ignore_unknown_fields = true },
        ) catch {
            return self.sendErrorResponse(stream, null, .parse_error, null);
        };
        defer parsed.deinit();

        const request = parsed.value;

        // Validate JSON-RPC version
        if (!std.mem.eql(u8, request.jsonrpc, "2.0")) {
            return self.sendErrorResponse(stream, request.id, .invalid_request, null);
        }

        // Handle request and get result
        const result = self.handleRequest(request) catch |err| {
            std.log.warn("Error handling method {s}: {}", .{ request.method, err });
            return self.sendErrorResponse(stream, request.id, .internal_error, null);
        };
        defer if (result.len > 0) self.allocator.free(result);

        // Send success response
        try self.sendSuccessResponse(stream, request.id, result);
    }

    /// Handle batch JSON-RPC requests
    fn handleBatchRequest(self: *Server, stream: std.net.Stream, body: []const u8) !void {
        // Parse batch request
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            body,
            .{},
        ) catch {
            return self.sendErrorResponse(stream, null, .parse_error, null);
        };
        defer parsed.deinit();

        const batch = parsed.value.array;
        if (batch.items.len == 0) {
            return self.sendErrorResponse(stream, null, .invalid_request, null);
        }

        // Process each request in batch
        var responses = std.ArrayList(u8).init(self.allocator);
        defer responses.deinit();
        const writer = responses.writer();

        try writer.writeAll("[");

        for (batch.items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(",");

            // Parse individual request
            var item_str = std.ArrayList(u8).init(self.allocator);
            defer item_str.deinit();

            try std.json.stringify(item, .{}, item_str.writer());

            const req_parsed = std.json.parseFromSlice(
                JsonRpcRequest,
                self.allocator,
                item_str.items,
                .{ .ignore_unknown_fields = true },
            ) catch {
                try self.writeErrorJson(writer, null, .invalid_request);
                continue;
            };
            defer req_parsed.deinit();

            const request = req_parsed.value;

            // Validate and handle
            if (!std.mem.eql(u8, request.jsonrpc, "2.0")) {
                try self.writeErrorJson(writer, request.id, .invalid_request);
                continue;
            }

            const result = self.handleRequest(request) catch {
                try self.writeErrorJson(writer, request.id, .internal_error);
                continue;
            };
            defer if (result.len > 0) self.allocator.free(result);

            try self.writeSuccessJson(writer, request.id, result);
        }

        try writer.writeAll("]");

        // Send HTTP response
        const http_response = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ responses.items.len, responses.items },
        );
        defer self.allocator.free(http_response);

        _ = try stream.writeAll(http_response);
    }

    /// Process single request and route to appropriate handler
    pub fn handleRequest(self: *Server, request: JsonRpcRequest) ![]const u8 {
        // Check for notification (id is null)
        const is_notification = request.id == null or request.id.? == .null;

        // Route to appropriate namespace handler
        if (std.mem.startsWith(u8, request.method, "eth_")) {
            return try self.handleEthMethod(request.method, request.params);
        } else if (std.mem.startsWith(u8, request.method, "net_")) {
            return try self.handleNetMethod(request.method);
        } else if (std.mem.startsWith(u8, request.method, "web3_")) {
            return try self.handleWeb3Method(request.method, request.params);
        } else if (std.mem.startsWith(u8, request.method, "debug_")) {
            return try self.handleDebugMethod(request.method, request.params);
        } else {
            _ = is_notification;
            return error.MethodNotFound;
        }
    }

    /// Handle eth namespace methods
    fn handleEthMethod(self: *Server, method: []const u8, params: std.json.Value) ![]const u8 {
        if (std.mem.eql(u8, method, "eth_blockNumber")) {
            const block_num = try self.eth_api.blockNumber();
            return try std.fmt.allocPrint(self.allocator, "\"0x{x}\"", .{block_num});
        } else if (std.mem.eql(u8, method, "eth_chainId")) {
            const chain_id = try self.eth_api.chainId();
            return try std.fmt.allocPrint(self.allocator, "\"0x{x}\"", .{chain_id});
        } else if (std.mem.eql(u8, method, "eth_syncing")) {
            const sync_status = try self.eth_api.syncing();
            if (sync_status) |status| {
                return try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"startingBlock\":\"0x{x}\",\"currentBlock\":\"0x{x}\",\"highestBlock\":\"0x{x}\"}}",
                    .{ status.starting_block, status.current_block, status.highest_block },
                );
            } else {
                return try self.allocator.dupe(u8, "false");
            }
        } else if (std.mem.eql(u8, method, "eth_gasPrice")) {
            return try self.eth_api.gasPrice();
        } else if (std.mem.eql(u8, method, "eth_maxPriorityFeePerGas")) {
            return try self.eth_api.maxPriorityFeePerGas();
        } else if (std.mem.eql(u8, method, "eth_getBlockByNumber")) {
            return try self.handleGetBlockByNumber(params);
        } else if (std.mem.eql(u8, method, "eth_getBlockByHash")) {
            return try self.handleGetBlockByHash(params);
        } else if (std.mem.eql(u8, method, "eth_getTransactionByHash")) {
            return try self.handleGetTransactionByHash(params);
        } else if (std.mem.eql(u8, method, "eth_getTransactionReceipt")) {
            return try self.handleGetTransactionReceipt(params);
        } else if (std.mem.eql(u8, method, "eth_getBalance")) {
            return try self.handleGetBalance(params);
        } else if (std.mem.eql(u8, method, "eth_getCode")) {
            return try self.handleGetCode(params);
        } else if (std.mem.eql(u8, method, "eth_getStorageAt")) {
            return try self.handleGetStorageAt(params);
        } else if (std.mem.eql(u8, method, "eth_getTransactionCount")) {
            return try self.handleGetTransactionCount(params);
        } else if (std.mem.eql(u8, method, "eth_call")) {
            return try self.handleCall(params);
        } else if (std.mem.eql(u8, method, "eth_estimateGas")) {
            return try self.handleEstimateGas(params);
        } else if (std.mem.eql(u8, method, "eth_sendRawTransaction")) {
            return try self.handleSendRawTransaction(params);
        } else if (std.mem.eql(u8, method, "eth_feeHistory")) {
            return try self.handleFeeHistory(params);
        } else if (std.mem.eql(u8, method, "eth_newFilter")) {
            return try self.handleNewFilter(params);
        } else if (std.mem.eql(u8, method, "eth_newBlockFilter")) {
            const filter_id = try self.eth_api.newBlockFilter();
            return try std.fmt.allocPrint(self.allocator, "\"0x{x}\"", .{filter_id});
        } else if (std.mem.eql(u8, method, "eth_getFilterChanges")) {
            return try self.handleGetFilterChanges(params);
        } else {
            return error.MethodNotFound;
        }
    }

    /// Handle net namespace methods
    fn handleNetMethod(self: *Server, method: []const u8) ![]const u8 {
        if (std.mem.eql(u8, method, "net_version")) {
            return try std.fmt.allocPrint(self.allocator, "\"{}\"", .{self.chain_id});
        } else if (std.mem.eql(u8, method, "net_listening")) {
            return try self.allocator.dupe(u8, "true");
        } else if (std.mem.eql(u8, method, "net_peerCount")) {
            return try self.allocator.dupe(u8, "\"0x0\"");
        } else {
            return error.MethodNotFound;
        }
    }

    /// Handle web3 namespace methods
    fn handleWeb3Method(self: *Server, method: []const u8, params: std.json.Value) ![]const u8 {
        if (std.mem.eql(u8, method, "web3_clientVersion")) {
            return try self.allocator.dupe(u8, "\"Guillotine/v0.1.0/zig\"");
        } else if (std.mem.eql(u8, method, "web3_sha3")) {
            return try self.handleSha3(params);
        } else {
            return error.MethodNotFound;
        }
    }

    /// Handle debug namespace methods
    fn handleDebugMethod(self: *Server, method: []const u8, params: std.json.Value) ![]const u8 {
        _ = params;
        if (std.mem.eql(u8, method, "debug_traceTransaction")) {
            return try self.allocator.dupe(u8, "{}");
        } else if (std.mem.eql(u8, method, "debug_traceBlockByNumber")) {
            return try self.allocator.dupe(u8, "[]");
        } else {
            return error.MethodNotFound;
        }
    }

    // ========================================
    // Parameter Parsing Helpers
    // ========================================

    fn handleGetBlockByNumber(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 2) return error.InvalidParams;

        const block_param = try self.parseBlockParameter(params_array.items[0]);
        const full_tx = params_array.items[1].bool;

        const result = try self.eth_api.getBlockByNumber(block_param, full_tx);
        if (result) |block_json| {
            return block_json;
        } else {
            return try self.allocator.dupe(u8, "null");
        }
    }

    fn handleGetBlockByHash(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 2) return error.InvalidParams;

        const hash = try self.parseHash32(params_array.items[0].string);
        const full_tx = params_array.items[1].bool;

        const result = try self.eth_api.getBlockByHash(hash, full_tx);
        if (result) |block_json| {
            return block_json;
        } else {
            return try self.allocator.dupe(u8, "null");
        }
    }

    fn handleGetTransactionByHash(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 1) return error.InvalidParams;

        const hash = try self.parseHash32(params_array.items[0].string);
        const result = try self.eth_api.getTransactionByHash(hash);

        if (result) |tx_json| {
            return tx_json;
        } else {
            return try self.allocator.dupe(u8, "null");
        }
    }

    fn handleGetTransactionReceipt(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 1) return error.InvalidParams;

        const hash = try self.parseHash32(params_array.items[0].string);
        const result = try self.eth_api.getTransactionReceipt(hash);

        if (result) |receipt_json| {
            return receipt_json;
        } else {
            return try self.allocator.dupe(u8, "null");
        }
    }

    fn handleGetBalance(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 2) return error.InvalidParams;

        const address = try self.parseAddress(params_array.items[0].string);
        const block_param = try self.parseBlockParameter(params_array.items[1]);

        return try self.eth_api.getBalance(address, block_param);
    }

    fn handleGetCode(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 2) return error.InvalidParams;

        const address = try self.parseAddress(params_array.items[0].string);
        const block_param = try self.parseBlockParameter(params_array.items[1]);

        return try self.eth_api.getCode(address, block_param);
    }

    fn handleGetStorageAt(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 3) return error.InvalidParams;

        const address = try self.parseAddress(params_array.items[0].string);
        const position = try self.parseHash32(params_array.items[1].string);
        const block_param = try self.parseBlockParameter(params_array.items[2]);

        return try self.eth_api.getStorageAt(address, position, block_param);
    }

    fn handleGetTransactionCount(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 2) return error.InvalidParams;

        const address = try self.parseAddress(params_array.items[0].string);
        const block_param = try self.parseBlockParameter(params_array.items[1]);

        const nonce = try self.eth_api.getTransactionCount(address, block_param);
        return try std.fmt.allocPrint(self.allocator, "\"0x{x}\"", .{nonce});
    }

    fn handleCall(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 1) return error.InvalidParams;

        const call_msg = try self.parseCallMessage(params_array.items[0]);
        const block_param = if (params_array.items.len >= 2)
            try self.parseBlockParameter(params_array.items[1])
        else
            eth_api.BlockParameter{ .tag = .latest };

        return try self.eth_api.call(call_msg, block_param);
    }

    fn handleEstimateGas(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 1) return error.InvalidParams;

        const call_msg = try self.parseCallMessage(params_array.items[0]);
        const gas_estimate = try self.eth_api.estimateGas(call_msg);

        return try std.fmt.allocPrint(self.allocator, "\"0x{x}\"", .{gas_estimate});
    }

    fn handleSendRawTransaction(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 1) return error.InvalidParams;

        const tx_hex = params_array.items[0].string;
        const tx_data = try self.parseHexData(tx_hex);
        defer self.allocator.free(tx_data);

        return try self.eth_api.sendRawTransaction(tx_data);
    }

    fn handleFeeHistory(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 2) return error.InvalidParams;

        const block_count = try self.parseQuantity(params_array.items[0]);
        const newest_block = try self.parseBlockParameter(params_array.items[1]);

        const reward_percentiles = if (params_array.items.len >= 3)
            try self.parseRewardPercentiles(params_array.items[2])
        else
            &[_]f64{};
        defer if (params_array.items.len >= 3) self.allocator.free(reward_percentiles);

        return try self.eth_api.feeHistory(block_count, newest_block, reward_percentiles);
    }

    fn handleNewFilter(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 1) return error.InvalidParams;

        const filter_options = try self.parseFilterOptions(params_array.items[0]);
        const filter_id = try self.eth_api.newFilter(filter_options);

        return try std.fmt.allocPrint(self.allocator, "\"0x{x}\"", .{filter_id});
    }

    fn handleGetFilterChanges(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 1) return error.InvalidParams;

        const filter_id = try self.parseQuantity(params_array.items[0]);
        return try self.eth_api.getFilterChanges(filter_id);
    }

    fn handleSha3(self: *Server, params: std.json.Value) ![]const u8 {
        const params_array = params.array;
        if (params_array.items.len < 1) return error.InvalidParams;

        const data = try self.parseHexData(params_array.items[0].string);
        defer self.allocator.free(data);

        const crypto = std.crypto;
        var hash: [32]u8 = undefined;
        crypto.hash.sha3.Keccak256.hash(data, &hash, .{});

        return try std.fmt.allocPrint(self.allocator, "\"0x{s}\"", .{std.fmt.fmtSliceHexLower(&hash)});
    }

    // ========================================
    // Response Helpers
    // ========================================

    fn sendSuccessResponse(self: *Server, stream: std.net.Stream, id: ?std.json.Value, result: []const u8) !void {
        var response = std.ArrayList(u8).init(self.allocator);
        defer response.deinit();
        const writer = response.writer();

        try self.writeSuccessJson(writer, id, result);

        const http_response = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ response.items.len, response.items },
        );
        defer self.allocator.free(http_response);

        _ = try stream.writeAll(http_response);
    }

    fn sendErrorResponse(
        self: *Server,
        stream: std.net.Stream,
        id: ?std.json.Value,
        error_code: ErrorCode,
        data: ?std.json.Value,
    ) !void {
        var response = std.ArrayList(u8).init(self.allocator);
        defer response.deinit();
        const writer = response.writer();

        try self.writeErrorJsonWithData(writer, id, error_code, data);

        const http_response = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ response.items.len, response.items },
        );
        defer self.allocator.free(http_response);

        _ = try stream.writeAll(http_response);
    }

    fn writeSuccessJson(self: *Server, writer: anytype, id: ?std.json.Value, result: []const u8) !void {
        _ = self;
        try writer.writeAll("{\"jsonrpc\":\"2.0\",");

        // Write id
        try writer.writeAll("\"id\":");
        if (id) |id_val| {
            try std.json.stringify(id_val, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",");

        // Write result
        try writer.writeAll("\"result\":");
        try writer.writeAll(result);
        try writer.writeAll("}");
    }

    fn writeErrorJson(self: *Server, writer: anytype, id: ?std.json.Value, error_code: ErrorCode) !void {
        try self.writeErrorJsonWithData(writer, id, error_code, null);
    }

    fn writeErrorJsonWithData(
        self: *Server,
        writer: anytype,
        id: ?std.json.Value,
        error_code: ErrorCode,
        data: ?std.json.Value,
    ) !void {
        _ = self;
        try writer.writeAll("{\"jsonrpc\":\"2.0\",");

        // Write id
        try writer.writeAll("\"id\":");
        if (id) |id_val| {
            try std.json.stringify(id_val, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",");

        // Write error
        try writer.print("\"error\":{{\"code\":{d},\"message\":\"{s}\"", .{
            @intFromEnum(error_code),
            error_code.message(),
        });

        if (data) |data_val| {
            try writer.writeAll(",\"data\":");
            try std.json.stringify(data_val, .{}, writer);
        }

        try writer.writeAll("}}");
    }

    // ========================================
    // Parameter Parsing
    // ========================================

    fn parseBlockParameter(self: *Server, value: std.json.Value) !eth_api.BlockParameter {
        return switch (value) {
            .string => |s| blk: {
                if (std.mem.eql(u8, s, "latest")) {
                    break :blk eth_api.BlockParameter{ .tag = .latest };
                } else if (std.mem.eql(u8, s, "earliest")) {
                    break :blk eth_api.BlockParameter{ .tag = .earliest };
                } else if (std.mem.eql(u8, s, "pending")) {
                    break :blk eth_api.BlockParameter{ .tag = .pending };
                } else if (std.mem.eql(u8, s, "safe")) {
                    break :blk eth_api.BlockParameter{ .tag = .safe };
                } else if (std.mem.eql(u8, s, "finalized")) {
                    break :blk eth_api.BlockParameter{ .tag = .finalized };
                } else if (std.mem.startsWith(u8, s, "0x")) {
                    // Could be number or hash
                    if (s.len == 66) {
                        // 32-byte hash
                        const hash = try self.parseHash32(s);
                        break :blk eth_api.BlockParameter{ .hash = hash };
                    } else {
                        // Block number
                        const num = try self.parseQuantity(value);
                        break :blk eth_api.BlockParameter{ .number = num };
                    }
                } else {
                    return error.InvalidParams;
                }
            },
            .integer => |n| eth_api.BlockParameter{ .number = @intCast(n) },
            else => error.InvalidParams,
        };
    }

    fn parseAddress(self: *Server, hex: []const u8) ![20]u8 {
        _ = self;
        var address: [20]u8 = undefined;
        const stripped = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;

        if (stripped.len != 40) return error.InvalidParams;

        _ = std.fmt.hexToBytes(&address, stripped) catch return error.InvalidParams;
        return address;
    }

    fn parseHash32(self: *Server, hex: []const u8) ![32]u8 {
        _ = self;
        var hash: [32]u8 = undefined;
        const stripped = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;

        if (stripped.len != 64) return error.InvalidParams;

        _ = std.fmt.hexToBytes(&hash, stripped) catch return error.InvalidParams;
        return hash;
    }

    fn parseHexData(self: *Server, hex: []const u8) ![]u8 {
        const stripped = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;
        if (stripped.len % 2 != 0) return error.InvalidParams;

        const data = try self.allocator.alloc(u8, stripped.len / 2);
        errdefer self.allocator.free(data);

        _ = std.fmt.hexToBytes(data, stripped) catch return error.InvalidParams;
        return data;
    }

    fn parseQuantity(self: *Server, value: std.json.Value) !u64 {
        _ = self;
        return switch (value) {
            .string => |s| blk: {
                const stripped = if (std.mem.startsWith(u8, s, "0x")) s[2..] else s;
                break :blk std.fmt.parseInt(u64, stripped, 16) catch return error.InvalidParams;
            },
            .integer => |n| @intCast(n),
            else => error.InvalidParams,
        };
    }

    fn parseCallMessage(self: *Server, value: std.json.Value) !eth_api.CallMessage {
        const obj = value.object;

        const from = if (obj.get("from")) |v|
            try self.parseAddress(v.string)
        else
            null;

        const to = if (obj.get("to")) |v|
            try self.parseAddress(v.string)
        else
            null;

        const gas = if (obj.get("gas")) |v|
            try self.parseQuantity(v)
        else
            null;

        const gas_price = if (obj.get("gasPrice")) |v|
            try self.parseU256(v)
        else
            null;

        const value_amount = if (obj.get("value")) |v|
            try self.parseU256(v)
        else
            null;

        const data = if (obj.get("data")) |v| blk: {
            const parsed_data = try self.parseHexData(v.string);
            break :blk parsed_data;
        } else null;

        return eth_api.CallMessage{
            .from = from,
            .to = to,
            .gas = gas,
            .gas_price = gas_price,
            .value = value_amount,
            .data = data,
        };
    }

    fn parseU256(self: *Server, value: std.json.Value) !u256 {
        _ = self;
        return switch (value) {
            .string => |s| blk: {
                const stripped = if (std.mem.startsWith(u8, s, "0x")) s[2..] else s;
                break :blk std.fmt.parseInt(u256, stripped, 16) catch return error.InvalidParams;
            },
            .integer => |n| @intCast(n),
            else => error.InvalidParams,
        };
    }

    fn parseRewardPercentiles(self: *Server, value: std.json.Value) ![]f64 {
        const array = value.array;
        const percentiles = try self.allocator.alloc(f64, array.items.len);
        errdefer self.allocator.free(percentiles);

        for (array.items, 0..) |item, i| {
            percentiles[i] = switch (item) {
                .float => |f| f,
                .integer => |n| @floatFromInt(n),
                else => return error.InvalidParams,
            };
        }

        return percentiles;
    }

    fn parseFilterOptions(self: *Server, value: std.json.Value) !eth_api.FilterOptions {
        const obj = value.object;

        const from_block = if (obj.get("fromBlock")) |v|
            try self.parseBlockParameter(v)
        else
            null;

        const to_block = if (obj.get("toBlock")) |v|
            try self.parseBlockParameter(v)
        else
            null;

        const address = if (obj.get("address")) |v|
            try self.parseAddress(v.string)
        else
            null;

        const topics = if (obj.get("topics")) |v| blk: {
            const topics_array = v.array;
            const parsed_topics = try self.allocator.alloc(?[32]u8, topics_array.items.len);
            for (topics_array.items, 0..) |topic, i| {
                parsed_topics[i] = if (topic == .null)
                    null
                else
                    try self.parseHash32(topic.string);
            }
            break :blk parsed_topics;
        } else null;

        return eth_api.FilterOptions{
            .from_block = from_block,
            .to_block = to_block,
            .address = address,
            .topics = topics,
        };
    }
};

// ========================================
// Tests
// ========================================

test "server initialization" {
    const memdb = @import("../kv/memdb.zig");
    const db_impl = try memdb.MemDb.init(std.testing.allocator);
    defer db_impl.deinit();

    const server = Server.init(std.testing.allocator, db_impl.asDatabase(), 1, 8545);
    try std.testing.expectEqual(@as(u16, 8545), server.port);
    try std.testing.expectEqual(@as(u64, 1), server.chain_id);
    try std.testing.expectEqual(false, server.running);
}

test "parse block parameter" {
    const memdb = @import("../kv/memdb.zig");
    const db_impl = try memdb.MemDb.init(std.testing.allocator);
    defer db_impl.deinit();

    const server = Server.init(std.testing.allocator, db_impl.asDatabase(), 1, 8545);

    // Test tag parsing
    const latest = try server.parseBlockParameter(.{ .string = "latest" });
    try std.testing.expectEqual(eth_api.BlockParameter.BlockTag.latest, latest.tag);

    const earliest = try server.parseBlockParameter(.{ .string = "earliest" });
    try std.testing.expectEqual(eth_api.BlockParameter.BlockTag.earliest, earliest.tag);

    // Test number parsing
    const num = try server.parseBlockParameter(.{ .integer = 12345 });
    try std.testing.expectEqual(@as(u64, 12345), num.number);
}

test "parse address" {
    const memdb = @import("../kv/memdb.zig");
    const db_impl = try memdb.MemDb.init(std.testing.allocator);
    defer db_impl.deinit();

    const server = Server.init(std.testing.allocator, db_impl.asDatabase(), 1, 8545);

    const address = try server.parseAddress("0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0");
    try std.testing.expectEqual(@as(u8, 0x74), address[0]);
    try std.testing.expectEqual(@as(u8, 0x2d), address[1]);
}

test "parse hex data" {
    const memdb = @import("../kv/memdb.zig");
    const db_impl = try memdb.MemDb.init(std.testing.allocator);
    defer db_impl.deinit();

    const server = Server.init(std.testing.allocator, db_impl.asDatabase(), 1, 8545);

    const data = try server.parseHexData("0x1234abcd");
    defer std.testing.allocator.free(data);

    try std.testing.expectEqual(@as(usize, 4), data.len);
    try std.testing.expectEqual(@as(u8, 0x12), data[0]);
    try std.testing.expectEqual(@as(u8, 0x34), data[1]);
    try std.testing.expectEqual(@as(u8, 0xab), data[2]);
    try std.testing.expectEqual(@as(u8, 0xcd), data[3]);
}

test "json-rpc request handling" {
    const memdb = @import("../kv/memdb.zig");
    const db_impl = try memdb.MemDb.init(std.testing.allocator);
    defer db_impl.deinit();

    const server = Server.init(std.testing.allocator, db_impl.asDatabase(), 1, 8545);

    const request = JsonRpcRequest{
        .jsonrpc = "2.0",
        .method = "eth_chainId",
        .params = .null,
        .id = .{ .integer = 1 },
    };

    const result = try server.handleRequest(request);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "0x1") != null);
}

//! DevP2P protocol implementation
//! Based on erigon/p2p
//! Spec: https://github.com/ethereum/devp2p

const std = @import("std");
const chain = @import("../chain.zig");

/// DevP2P protocol versions
pub const ProtocolVersion = enum(u8) {
    eth66 = 66,
    eth67 = 67,
    eth68 = 68,

    pub fn toString(self: ProtocolVersion) []const u8 {
        return switch (self) {
            .eth66 => "eth/66",
            .eth67 => "eth/67",
            .eth68 => "eth/68",
        };
    }
};

/// Base devp2p message types (before protocol-specific)
pub const BaseMessageType = enum(u8) {
    hello = 0x00,
    disconnect = 0x01,
    ping = 0x02,
    pong = 0x03,
};

/// Disconnect reasons
pub const DisconnectReason = enum(u8) {
    requested = 0x00,
    tcp_error = 0x01,
    breach_of_protocol = 0x02,
    useless_peer = 0x03,
    too_many_peers = 0x04,
    already_connected = 0x05,
    incompatible_version = 0x06,
    invalid_identity = 0x07,
    client_quitting = 0x08,
    unexpected_identity = 0x09,
    same_identity = 0x0a,
    timeout = 0x0b,
    subprotocol_error = 0x10,
};

/// Hello message
pub const Hello = struct {
    protocol_version: u8 = 5,
    client_id: []const u8,
    capabilities: []Capability,
    listen_port: u16 = 30303,
    node_id: [64]u8 = [_]u8{0} ** 64,

    pub const Capability = struct {
        name: []const u8,
        version: u8,
    };

    pub fn init(allocator: std.mem.Allocator, client_id: []const u8, protocols: []const @import("server.zig").Protocol) !Hello {
        var caps = try allocator.alloc(Capability, protocols.len);
        for (protocols, 0..) |proto, i| {
            caps[i] = .{
                .name = proto.name,
                .version = @intCast(proto.version),
            };
        }

        return .{
            .client_id = client_id,
            .capabilities = caps,
        };
    }

    pub fn deinit(self: *const Hello, allocator: std.mem.Allocator) void {
        allocator.free(self.capabilities);
    }

    pub fn encode(self: *const Hello, allocator: std.mem.Allocator) ![]u8 {
        const rlp = @import("guillotine_primitives").Rlp;
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();
        try encoder.writeInt(self.protocol_version);
        try encoder.writeBytes(self.client_id);

        try encoder.startList();
        for (self.capabilities) |cap| {
            try encoder.startList();
            try encoder.writeBytes(cap.name);
            try encoder.writeInt(cap.version);
            try encoder.endList();
        }
        try encoder.endList();

        try encoder.writeInt(self.listen_port);
        try encoder.writeBytes(&self.node_id);
        try encoder.endList();

        return encoder.toOwnedSlice();
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Hello {
        const rlp = @import("guillotine_primitives").Rlp;
        var decoder = rlp.Decoder.init(data);
        var list = try decoder.enterList();

        const protocol_version: u8 = @intCast(try list.decodeInt());
        const client_id = try allocator.dupe(u8, try list.decodeBytesView());

        var caps = std.ArrayList(Capability){};
        var caps_list = try list.enterList();
        while (!caps_list.isEmpty()) {
            var cap_list = try caps_list.enterList();
            const name = try allocator.dupe(u8, try cap_list.decodeBytesView());
            const version: u8 = @intCast(try cap_list.decodeInt());
            try caps.append(allocator, .{ .name = name, .version = version });
        }

        const listen_port: u16 = @intCast(try list.decodeInt());
        const node_id_bytes = try list.decodeBytesView();
        var node_id: [64]u8 = undefined;
        @memcpy(&node_id, node_id_bytes[0..@min(64, node_id_bytes.len)]);

        return .{
            .protocol_version = protocol_version,
            .client_id = client_id,
            .capabilities = try caps.toOwnedSlice(allocator),
            .listen_port = listen_port,
            .node_id = node_id,
        };
    }
};

/// Disconnect message
pub const Disconnect = struct {
    reason: DisconnectReason,

    pub fn encode(self: *const Disconnect, allocator: std.mem.Allocator) ![]u8 {
        const rlp = @import("guillotine_primitives").Rlp;
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();
        try encoder.writeInt(@intFromEnum(self.reason));
        try encoder.endList();

        return encoder.toOwnedSlice();
    }
};

/// Network message types (eth/68)
pub const MessageType = enum(u8) {
    // Status exchange
    Status = 0x00,

    // Block propagation
    NewBlockHashes = 0x01,
    Transactions = 0x02,
    GetBlockHeaders = 0x03,
    BlockHeaders = 0x04,
    GetBlockBodies = 0x05,
    BlockBodies = 0x06,
    NewBlock = 0x07,
    NewPooledTransactionHashes = 0x08,
    GetPooledTransactions = 0x09,
    PooledTransactions = 0x0a,

    // State synchronization
    GetNodeData = 0x0d,
    NodeData = 0x0e,
    GetReceipts = 0x0f,
    Receipts = 0x10,

    pub fn toString(self: MessageType) []const u8 {
        return @tagName(self);
    }
};

/// Network status message
pub const StatusMessage = struct {
    protocol_version: u8,
    network_id: u64,
    total_difficulty: [32]u8,
    best_hash: [32]u8,
    genesis_hash: [32]u8,
    fork_id: ForkId,

    pub const ForkId = struct {
        hash: [4]u8,
        next: u64,
    };

    pub fn encode(self: *const StatusMessage, allocator: std.mem.Allocator) ![]u8 {
        const rlp = @import("guillotine_primitives").Rlp;
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        // Status message structure: [protocol_version, network_id, total_difficulty, best_hash, genesis_hash, fork_id]
        try encoder.startList();
        try encoder.writeInt(self.protocol_version);
        try encoder.writeInt(self.network_id);
        try encoder.writeBytes(&self.total_difficulty);
        try encoder.writeBytes(&self.best_hash);
        try encoder.writeBytes(&self.genesis_hash);

        // ForkId is a list: [hash, next]
        try encoder.startList();
        try encoder.writeBytes(&self.fork_id.hash);
        try encoder.writeInt(self.fork_id.next);
        try encoder.endList();

        try encoder.endList();

        return encoder.toOwnedSlice();
    }

    pub fn decode(data: []const u8, allocator: std.mem.Allocator) !StatusMessage {
        const rlp = @import("guillotine_primitives").Rlp;
        var decoder = rlp.Decoder.init(data);
        var list = try decoder.enterList();

        const protocol_version: u8 = @intCast(try list.decodeInt());
        const network_id = try list.decodeInt();

        // Total difficulty (32 bytes)
        const td_bytes = try list.decodeBytesView();
        var total_difficulty: [32]u8 = [_]u8{0} ** 32;
        if (td_bytes.len <= 32) {
            // Right-align the bytes (big-endian)
            const offset = 32 - td_bytes.len;
            @memcpy(total_difficulty[offset..], td_bytes);
        } else {
            return error.InvalidTotalDifficulty;
        }

        // Best hash (32 bytes)
        const best_hash_bytes = try list.decodeBytesView();
        if (best_hash_bytes.len != 32) return error.InvalidBestHash;
        var best_hash: [32]u8 = undefined;
        @memcpy(&best_hash, best_hash_bytes);

        // Genesis hash (32 bytes)
        const genesis_hash_bytes = try list.decodeBytesView();
        if (genesis_hash_bytes.len != 32) return error.InvalidGenesisHash;
        var genesis_hash: [32]u8 = undefined;
        @memcpy(&genesis_hash, genesis_hash_bytes);

        // ForkId: [hash, next]
        var fork_list = try list.enterList();
        const fork_hash_bytes = try fork_list.decodeBytesView();
        if (fork_hash_bytes.len != 4) return error.InvalidForkIdHash;
        var fork_hash: [4]u8 = undefined;
        @memcpy(&fork_hash, fork_hash_bytes);
        const fork_next = try fork_list.decodeInt();

        _ = allocator; // For future use if needed

        return StatusMessage{
            .protocol_version = protocol_version,
            .network_id = network_id,
            .total_difficulty = total_difficulty,
            .best_hash = best_hash,
            .genesis_hash = genesis_hash,
            .fork_id = .{
                .hash = fork_hash,
                .next = fork_next,
            },
        };
    }
};

/// GetBlockHeaders request
pub const GetBlockHeadersRequest = struct {
    request_id: u64,
    /// Starting block (number or hash)
    origin: union(enum) {
        number: u64,
        hash: [32]u8,
    },
    /// Maximum headers to return
    amount: u64,
    /// Number of blocks to skip
    skip: u64,
    /// Direction (false = ascending, true = descending)
    reverse: bool,
};

/// BlockHeaders response
pub const BlockHeadersResponse = struct {
    request_id: u64,
    headers: []const chain.Header,
};

/// GetBlockBodies request
pub const GetBlockBodiesRequest = struct {
    request_id: u64,
    hashes: []const [32]u8,
};

/// BlockBodies response
pub const BlockBodiesResponse = struct {
    request_id: u64,
    bodies: []const BlockBody,

    pub const BlockBody = struct {
        transactions: []const chain.Transaction,
        uncles: []const chain.Header,
    };
};

/// NewBlockHashes announcement
pub const NewBlockHashesMessage = struct {
    hashes: []const BlockHashAnnouncement,

    pub const BlockHashAnnouncement = struct {
        hash: [32]u8,
        number: u64,
    };
};

/// NewBlock announcement
pub const NewBlockMessage = struct {
    block: chain.Block,
    total_difficulty: [32]u8,
};

/// Peer connection (legacy - use server.zig Peer instead)
pub const Peer = struct {
    id: [32]u8,
    address: std.net.Address,
    protocol_version: ProtocolVersion,
    network_id: u64,
    total_difficulty: [32]u8,
    best_hash: [32]u8,
    connected: bool,
    last_seen: u64,
    rlpx_conn: ?*@import("rlpx.zig").Conn = null, // Optional RLPx connection

    pub fn handshake(self: *Peer, status: StatusMessage) !void {
        self.protocol_version = @enumFromInt(status.protocol_version);
        self.network_id = status.network_id;
        self.total_difficulty = status.total_difficulty;
        self.best_hash = status.best_hash;
        self.connected = true;
        self.last_seen = @as(u64, @intCast(std.time.timestamp()));

        std.log.info("Peer handshake completed: protocol={s} network={}", .{
            self.protocol_version.toString(),
            status.network_id,
        });
    }

    pub fn sendMessage(self: *Peer, msg_type: MessageType, data: []const u8) !void {
        if (!self.connected) return error.PeerDisconnected;

        std.log.debug("Sending {} to peer ({} bytes)", .{
            msg_type.toString(),
            data.len,
        });

        // Send via RLPx connection if available
        if (self.rlpx_conn) |conn| {
            // Message code offset: base messages (0x00-0x0F) + protocol messages (0x10+)
            const code = @intFromEnum(msg_type) + 0x10; // Protocol messages start at 0x10
            _ = try conn.writeMsg(code, data);
        } else {
            return error.NoRLPxConnection;
        }
    }

    pub fn disconnect(self: *Peer, reason: []const u8) void {
        std.log.info("Peer disconnected: {s}", .{reason});
        self.connected = false;
    }
};

/// P2P network manager
pub const NetworkManager = struct {
    allocator: std.mem.Allocator,
    peers: std.ArrayList(*Peer),
    max_peers: usize,
    protocol_version: ProtocolVersion,
    network_id: u64,
    genesis_hash: [32]u8,
    best_hash: [32]u8,
    total_difficulty: [32]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        network_id: u64,
        max_peers: usize,
    ) NetworkManager {
        return .{
            .allocator = allocator,
            .peers = std.ArrayList(*Peer).empty,
            .max_peers = max_peers,
            .protocol_version = .eth68,
            .network_id = network_id,
            .genesis_hash = [_]u8{0} ** 32,
            .best_hash = [_]u8{0} ** 32,
            .total_difficulty = [_]u8{0} ** 32,
        };
    }

    pub fn deinit(self: *NetworkManager) void {
        for (self.peers.items) |peer| {
            self.allocator.destroy(peer);
        }
        self.peers.deinit(self.allocator);
    }

    /// Start listening for connections
    pub fn start(_: *NetworkManager, port: u16) !void {
        std.log.info("Starting P2P network on port {}", .{port});

        // P2P Network Startup Process (based on erigon/p2p/server.go):
        //
        // 1. TCP Server Setup:
        //    - Bind to 0.0.0.0:port (IPv4) or [::]:port (IPv6)
        //    - Start accept loop in separate thread
        //    - Each accepted connection goes through:
        //      a. RLPx handshake (encryption setup)
        //      b. devp2p Hello message exchange
        //      c. Protocol capability negotiation
        //      d. Add to peers list
        //
        // 2. Discovery Protocol (UDP):
        //    - Bind to same port for discovery
        //    - Start discv4 or discv5 protocol
        //    - Send/receive Ping, Pong, FindNode, Neighbors messages
        //    - Maintain Kademlia routing table
        //    - Bootstrap from known nodes
        //
        // 3. Dial Scheduler:
        //    - Maintain static and dynamic peer lists
        //    - Continuously attempt outbound connections
        //    - Respect max peer limits
        //    - Implement exponential backoff for failed dials
        //
        // 4. Peer Management:
        //    - Track peer states (connecting, handshaking, connected)
        //    - Monitor peer health (timeouts, errors)
        //    - Enforce protocol rules
        //    - Handle peer disconnections gracefully
        //
        // Implementation approach:
        // - Use std.net.StreamServer for TCP
        // - Implement discovery protocol separately
        // - Use thread pool for concurrent connection handling
        // - Implement event loop for peer management
        //
        // Key components needed:
        // - Server struct with StreamServer
        // - Discovery struct (discv4/discv5)
        // - DialScheduler for outbound connections
        // - Peer pool with connection lifecycle management

        // TODO: Full TCP server and discovery implementation
        // This requires significant networking infrastructure including:
        // - Thread-safe peer management
        // - Connection pooling
        // - Discovery protocol state machine
        // - Event loop for message routing
    }

    /// Connect to a peer
    pub fn connectPeer(self: *NetworkManager, address: std.net.Address) !*Peer {
        if (self.peers.items.len >= self.max_peers) {
            return error.MaxPeersReached;
        }

        const peer = try self.allocator.create(Peer);
        errdefer self.allocator.destroy(peer);

        peer.* = .{
            .id = [_]u8{0} ** 32,
            .address = address,
            .protocol_version = .eth68,
            .network_id = 0,
            .total_difficulty = [_]u8{0} ** 32,
            .best_hash = [_]u8{0} ** 32,
            .connected = false,
            .last_seen = 0,
        };

        // Send status message
        const status = StatusMessage{
            .protocol_version = @intFromEnum(self.protocol_version),
            .network_id = self.network_id,
            .total_difficulty = self.total_difficulty,
            .best_hash = self.best_hash,
            .genesis_hash = self.genesis_hash,
            .fork_id = .{
                .hash = [_]u8{0} ** 4,
                .next = 0,
            },
        };

        // Network message sending for Status exchange:
        //
        // 1. Encode Status message to RLP
        const status_data = try status.encode(self.allocator);
        defer self.allocator.free(status_data);

        // 2. Send via RLPx connection (production implementation):
        //    - peer.rlpx_conn.writeMsg(@intFromEnum(MessageType.Status), status_data)
        //    - RLPx layer handles:
        //      a. RLP encoding of [code, payload]
        //      b. Snappy compression (if negotiated)
        //      c. AES-CTR encryption
        //      d. MAC computation (egress MAC)
        //      e. Frame construction: [header(32)][data(encrypted)][mac(16)]
        //
        // 3. Wait for Status response:
        //    - peer.rlpx_conn.readMsg()
        //    - Verify message code is Status (0x00)
        //    - Decode Status message
        //    - Validate compatibility (network_id, genesis_hash, fork_id)
        //    - Call peer.handshake(status_response)
        //
        // 4. Error handling:
        //    - Network errors: disconnect peer
        //    - Protocol errors: send Disconnect message with reason
        //    - Timeout: configurable (usually 5-10 seconds)
        //
        // Note: The actual sending happens through the RLPx connection
        // which is stored in the Peer struct. This stub shows the flow
        // but doesn't implement the full networking stack.

        try self.peers.append(self.allocator, peer);
        std.log.info("Connected to peer at {}", .{address});

        return peer;
    }

    /// Request block headers from peers
    pub fn requestHeaders(
        self: *NetworkManager,
        from_block: u64,
        max_headers: u64,
    ) !void {
        if (self.peers.items.len == 0) {
            return error.NoPeers;
        }

        // Pick random peer
        const peer_idx = std.crypto.random.intRangeAtMost(usize, 0, self.peers.items.len - 1);
        const peer = self.peers.items[peer_idx];

        const request = GetBlockHeadersRequest{
            .request_id = std.crypto.random.int(u64),
            .origin = .{ .number = from_block },
            .amount = max_headers,
            .skip = 0,
            .reverse = false,
        };

        std.log.debug("Requesting {} headers from block {}", .{
            max_headers,
            from_block,
        });

        // Encode GetBlockHeaders request (eth/66+ format):
        //
        // Message structure: [request_id, [origin, amount, skip, reverse]]
        // where origin is either block_number (uint64) or block_hash ([32]u8)
        //
        // Implementation:
        const rlp = @import("guillotine_primitives").Rlp;
        var encoder = rlp.Encoder.init(self.allocator);
        defer encoder.deinit();

        // Outer list: [request_id, request_data]
        try encoder.startList();
        try encoder.writeInt(request.request_id);

        // Inner list: [origin, amount, skip, reverse]
        try encoder.startList();

        // Origin: block number or hash
        switch (request.origin) {
            .number => |num| try encoder.writeInt(num),
            .hash => |hash| try encoder.writeBytes(&hash),
        }

        try encoder.writeInt(request.amount);
        try encoder.writeInt(request.skip);
        try encoder.writeInt(if (request.reverse) @as(u8, 1) else @as(u8, 0));
        try encoder.endList();

        try encoder.endList();

        const encoded = try encoder.toOwnedSlice();
        defer self.allocator.free(encoded);

        try peer.sendMessage(.GetBlockHeaders, encoded);
    }

    /// Broadcast new block to peers
    pub fn broadcastBlock(self: *NetworkManager, block: *const chain.Block) !void {
        std.log.info("Broadcasting block {} to {} peers", .{
            block.number(),
            self.peers.items.len,
        });

        for (self.peers.items) |peer| {
            if (!peer.connected) continue;

            // Encode NewBlockHashes announcement:
            //
            // Message structure: [[hash, number], [hash, number], ...]
            // Each block announcement contains:
            // - hash: 32-byte block hash
            // - number: block number
            //
            // For a single block announcement:
            const rlp = @import("guillotine_primitives").Rlp;
            var encoder = rlp.Encoder.init(self.allocator);
            defer encoder.deinit();

            // Outer list containing block announcements
            try encoder.startList();

            // Single block announcement: [hash, number]
            try encoder.startList();
            const block_hash = block.hash();
            try encoder.writeBytes(&block_hash);
            try encoder.writeInt(block.number());
            try encoder.endList();

            try encoder.endList();

            const encoded = try encoder.toOwnedSlice();
            defer self.allocator.free(encoded);

            try peer.sendMessage(.NewBlockHashes, encoded);
        }
    }

    /// Get connected peer count
    pub fn getPeerCount(self: *NetworkManager) usize {
        var count: usize = 0;
        for (self.peers.items) |peer| {
            if (peer.connected) count += 1;
        }
        return count;
    }
};

test "network manager initialization" {
    var network = NetworkManager.init(std.testing.allocator, 1, 50);
    defer network.deinit();

    try std.testing.expectEqual(@as(usize, 0), network.getPeerCount());
}

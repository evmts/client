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
        _ = self;
        _ = allocator;
        // In production: RLP encode
        return &[_]u8{};
    }

    pub fn decode(data: []const u8, allocator: std.mem.Allocator) !StatusMessage {
        _ = data;
        _ = allocator;
        // In production: RLP decode
        return StatusMessage{
            .protocol_version = 68,
            .network_id = 1,
            .total_difficulty = [_]u8{0} ** 32,
            .best_hash = [_]u8{0} ** 32,
            .genesis_hash = [_]u8{0} ** 32,
            .fork_id = .{
                .hash = [_]u8{0} ** 4,
                .next = 0,
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

/// Peer connection
pub const Peer = struct {
    id: [32]u8,
    address: std.net.Address,
    protocol_version: ProtocolVersion,
    network_id: u64,
    total_difficulty: [32]u8,
    best_hash: [32]u8,
    connected: bool,
    last_seen: u64,

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

        std.log.debug("Sending {} to peer ({}  bytes)", .{
            msg_type.toString(),
            data.len,
        });

        // In production: Encode message with RLPx framing
        _ = data;
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
    pub fn start(self: *NetworkManager, port: u16) !void {
        std.log.info("Starting P2P network on port {}", .{port});

        // In production: Start TCP server, discovery protocol, etc.
        _ = self;
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

        // In production: Actually send over network
        const status_data = try status.encode(self.allocator);
        defer self.allocator.free(status_data);

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

        // In production: Encode and send
        _ = request;
        try peer.sendMessage(.GetBlockHeaders, &[_]u8{});
    }

    /// Broadcast new block to peers
    pub fn broadcastBlock(self: *NetworkManager, block: *const chain.Block) !void {
        std.log.info("Broadcasting block {} to {} peers", .{
            block.number(),
            self.peers.items.len,
        });

        for (self.peers.items) |peer| {
            if (!peer.connected) continue;

            // Send NewBlockHashes for announcement
            // In production: RLP encode
            try peer.sendMessage(.NewBlockHashes, &[_]u8{});
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

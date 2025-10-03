//! P2P networking layer (simplified)
//! In production: Implements DevP2P, discovery, block propagation

const std = @import("std");
const chain = @import("chain.zig");

pub const P2PError = error{
    ConnectionFailed,
    PeerNotFound,
    NetworkTimeout,
};

/// Peer connection
pub const Peer = struct {
    id: [32]u8,
    address: std.net.Address,
    protocol_version: u32,
    connected: bool,

    pub fn disconnect(self: *Peer) void {
        self.connected = false;
    }
};

/// P2P network manager
pub const NetworkManager = struct {
    allocator: std.mem.Allocator,
    peers: std.ArrayList(Peer),
    max_peers: u32,
    listening: bool,

    pub fn init(allocator: std.mem.Allocator, max_peers: u32) NetworkManager {
        return .{
            .allocator = allocator,
            .peers = std.ArrayList(Peer).empty,
            .max_peers = max_peers,
            .listening = false,
        };
    }

    pub fn deinit(self: *NetworkManager) void {
        self.peers.deinit(self.allocator);
    }

    /// Start listening for peer connections
    pub fn start(self: *NetworkManager, port: u16) !void {
        _ = port;
        self.listening = true;
        std.log.info("P2P network started (simplified mode)", .{});
    }

    /// Stop the network
    pub fn stop(self: *NetworkManager) void {
        self.listening = false;
        for (self.peers.items) |*peer| {
            peer.disconnect();
        }
    }

    /// Connect to a peer
    pub fn connectPeer(self: *NetworkManager, address: std.net.Address) !void {
        if (self.peers.items.len >= self.max_peers) {
            return P2PError.PeerNotFound;
        }

        const peer = Peer{
            .id = [_]u8{0} ** 32,
            .address = address,
            .protocol_version = 68, // eth/68
            .connected = true,
        };

        try self.peers.append(self.allocator, peer);
        std.log.info("Connected to peer (count: {})", .{self.peers.items.len});
    }

    /// Broadcast block to peers
    pub fn broadcastBlock(self: *NetworkManager, block: *const chain.Block) !void {
        if (self.peers.items.len == 0) {
            return; // No peers to broadcast to
        }
        std.log.debug("Broadcasting block {} to {} peers", .{ block.number(), self.peers.items.len });
    }

    /// Request headers from peers
    pub fn requestHeaders(self: *NetworkManager, from: u64, to: u64) ![]chain.Header {
        _ = self;
        _ = from;
        _ = to;
        // In production: Send GetBlockHeaders message to peers
        // For minimal implementation: return empty
        return &[_]chain.Header{};
    }

    /// Get peer count
    pub fn getPeerCount(self: *NetworkManager) u32 {
        return @as(u32, @intCast(self.peers.items.len));
    }
};

test "network manager initialization" {
    var network = NetworkManager.init(std.testing.allocator, 50);
    defer network.deinit();

    try network.start(30303);
    try std.testing.expect(network.listening);

    network.stop();
    try std.testing.expect(!network.listening);
}

test "peer connection" {
    var network = NetworkManager.init(std.testing.allocator, 10);
    defer network.deinit();

    const addr = try std.net.Address.parseIp("127.0.0.1", 30303);
    try network.connectPeer(addr);

    try std.testing.expectEqual(@as(u32, 1), network.getPeerCount());
}

//! P2P networking layer - Full implementation with RLPx and Discovery
//!
//! This module provides the complete P2P networking stack:
//! - RLPx protocol for encrypted transport
//! - Discovery v4 for node finding (Kademlia DHT)
//! - DevP2P for Ethereum protocol messaging
//! - Peer connection management
//!
//! Matches Erigon's architecture from p2p/rlpx, p2p/discover, p2p/server

const std = @import("std");

// Re-export submodules
pub const rlpx = @import("p2p/rlpx.zig");
pub const discovery = @import("p2p/discovery.zig");
pub const devp2p = @import("p2p/devp2p.zig");
pub const server = @import("p2p/server.zig");

// Re-export key types for convenience
pub const Server = server.Server;
pub const Protocol = server.Protocol;
pub const Peer = server.Peer;
pub const Node = discovery.Node;
pub const UDPv4 = discovery.UDPv4;
pub const Conn = rlpx.Conn;

pub const P2PError = error{
    ConnectionFailed,
    PeerNotFound,
    NetworkTimeout,
    HandshakeFailed,
    ProtocolError,
    InvalidMessage,
    NoSession,
    InvalidMAC,
    TooManyPeers,
};

/// Simplified network manager (legacy compatibility)
pub const NetworkManager = struct {
    server: *Server,

    pub fn init(allocator: std.mem.Allocator, max_peers: u32, listen_port: u16, priv_key: [32]u8) !NetworkManager {
        const config = server.Config{
            .max_peers = max_peers,
            .listen_addr = try std.net.Address.parseIp4("0.0.0.0", listen_port),
            .discovery_port = listen_port,
            .priv_key = priv_key,
            .bootnodes = &[_]Node{},
            .protocols = &[_]Protocol{},
        };

        const srv = try Server.init(allocator, config);
        return .{ .server = srv };
    }

    pub fn deinit(self: *NetworkManager) void {
        self.server.deinit();
    }

    /// Start listening for peer connections
    pub fn start(self: *NetworkManager) !void {
        try self.server.start();
    }

    pub fn stop(self: *NetworkManager) void {
        self.server.stop();
    }

    pub fn peerCount(self: *NetworkManager) u32 {
        return self.server.peerCount();
    }
};

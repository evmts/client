//! P2P Server - manages peer connections
//! Based on Erigon's p2p/server.go

const std = @import("std");
const rlp = @import("../rlp.zig");
const rlpx = @import("rlpx.zig");
const discovery = @import("discovery.zig");
const devp2p = @import("devp2p.zig");

/// P2P server configuration
pub const Config = struct {
    /// Maximum number of peers
    max_peers: u32 = 50,

    /// Maximum number of pending connections
    max_pending_peers: u32 = 50,

    /// Dial ratio (1:3 means 1 dialed peer for every 3 inbound)
    dial_ratio: u32 = 3,

    /// Listen address for TCP
    listen_addr: std.net.Address,

    /// UDP port for discovery
    discovery_port: u16,

    /// Private key
    priv_key: [32]u8,

    /// Bootnodes for initial discovery
    bootnodes: []discovery.Node,

    /// Node name/client version
    name: []const u8 = "Erigon/Zig/v0.1.0",

    /// Supported protocols
    protocols: []Protocol,
};

/// Protocol definition
pub const Protocol = struct {
    name: []const u8,
    version: u32,
    length: u32, // Number of message codes
    handler: *const fn (*Peer, u64, []const u8) anyerror!void,
};

/// P2P Server
pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    running: bool,

    /// TCP listener for incoming connections
    listener: ?std.net.Server,

    /// Discovery protocol handler
    discovery: ?*discovery.UDPv4,

    /// Connected peers
    peers: std.ArrayList(*Peer),
    peers_mutex: std.Thread.Mutex,

    /// Pending dials
    pending_dials: std.ArrayList(*Peer),

    /// Dialer thread
    dialer_thread: ?std.Thread,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        const self = try allocator.create(Self);

        self.* = .{
            .allocator = allocator,
            .config = config,
            .running = false,
            .listener = null,
            .discovery = null,
            .peers = std.ArrayList(*Peer).init(allocator),
            .peers_mutex = .{},
            .pending_dials = std.ArrayList(*Peer).init(allocator),
            .dialer_thread = null,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        for (self.peers.items) |peer| {
            peer.deinit();
        }
        self.peers.deinit();
        self.pending_dials.deinit();

        self.allocator.destroy(self);
    }

    /// Start the P2P server
    pub fn start(self: *Self) !void {
        if (self.running) return error.AlreadyRunning;
        self.running = true;

        // Start discovery
        self.discovery = try discovery.UDPv4.init(
            self.allocator,
            try std.net.Address.parseIp4("0.0.0.0", self.config.discovery_port),
            self.config.priv_key,
        );

        // Add bootnodes
        for (self.config.bootnodes) |bootnode| {
            try self.discovery.?.routing_table.addNode(bootnode);
            try self.discovery.?.ping(&bootnode);
        }

        // Start discovery in separate thread
        const discovery_thread = try std.Thread.spawn(.{}, discoveryLoop, .{self});
        discovery_thread.detach();

        // Start TCP listener
        self.listener = try self.config.listen_addr.listen(.{
            .reuse_address = true,
        });

        std.log.info("P2P server listening on {}", .{self.config.listen_addr});

        // Start listening for connections in separate thread
        const listen_thread = try std.Thread.spawn(.{}, listenLoop, .{self});
        listen_thread.detach();

        // Start dialer thread
        self.dialer_thread = try std.Thread.spawn(.{}, dialerLoop, .{self});
    }

    /// Stop the P2P server
    pub fn stop(self: *Self) void {
        if (!self.running) return;
        self.running = false;

        // Close listener
        if (self.listener) |*listener| {
            listener.deinit();
            self.listener = null;
        }

        // Stop discovery
        if (self.discovery) |disc| {
            disc.deinit();
            self.discovery = null;
        }

        // Close all peer connections
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();

        for (self.peers.items) |peer| {
            peer.disconnect(.requested);
        }
    }

    /// Get peer count
    pub fn peerCount(self: *Self) u32 {
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();
        return @intCast(self.peers.items.len);
    }

    /// Add a peer connection
    fn addPeer(self: *Self, peer: *Peer) !void {
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();

        if (self.peers.items.len >= self.config.max_peers) {
            return error.TooManyPeers;
        }

        try self.peers.append(peer);
        std.log.info("Added peer: {s}", .{peer.name});
    }

    /// Remove a peer
    fn removePeer(self: *Self, peer: *Peer) void {
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();

        for (self.peers.items, 0..) |p, i| {
            if (p == peer) {
                _ = self.peers.swapRemove(i);
                std.log.info("Removed peer: {s}", .{peer.name});
                break;
            }
        }
    }

    /// Discovery loop
    fn discoveryLoop(self: *Self) !void {
        if (self.discovery) |disc| {
            try disc.start();
        }
    }

    /// Listen loop for incoming connections
    fn listenLoop(self: *Self) !void {
        if (self.listener == null) return;

        while (self.running) {
            const conn = self.listener.?.accept() catch |err| {
                std.log.err("Accept error: {}", .{err});
                continue;
            };

            // Handle connection in separate thread
            const handle_thread = std.Thread.spawn(.{}, handleIncoming, .{ self, conn.stream }) catch |err| {
                std.log.err("Failed to spawn handler: {}", .{err});
                conn.stream.close();
                continue;
            };
            handle_thread.detach();
        }
    }

    /// Handle incoming connection
    fn handleIncoming(self: *Self, stream: std.net.Stream) !void {
        // Create RLPx connection (receiver side, no dial dest)
        var rlpx_conn = rlpx.Conn.init(self.allocator, stream, null);
        defer rlpx_conn.deinit();

        // Perform RLPx handshake
        try rlpx_conn.handshake(&self.config.priv_key);

        // Create peer
        const peer = try Peer.init(
            self.allocator,
            rlpx_conn,
            .inbound,
            self.config.protocols,
        );

        // Perform devp2p handshake
        try peer.doHandshake(self.config.name, self.config.priv_key);

        // Add to peer list
        try self.addPeer(peer);
        defer self.removePeer(peer);

        // Run peer message loop
        try peer.run();
    }

    /// Dialer loop
    fn dialerLoop(self: *Self) !void {
        while (self.running) {
            std.time.sleep(5 * std.time.ns_per_s); // Check every 5 seconds

            self.peers_mutex.lock();
            const current_peers = self.peers.items.len;
            self.peers_mutex.unlock();

            if (current_peers >= self.config.max_peers) {
                continue;
            }

            // Get nodes from discovery
            if (self.discovery) |disc| {
                var target: [32]u8 = undefined;
                try std.crypto.random.bytes(&target);

                const nodes = try disc.routing_table.findClosest(target, 16);
                defer self.allocator.free(nodes);

                // Try to dial some nodes
                for (nodes) |node| {
                    if (current_peers >= self.config.max_peers) break;

                    self.dialNode(node) catch |err| {
                        std.log.err("Failed to dial node: {}", .{err});
                    };
                }
            }
        }
    }

    /// Dial a node with retry logic
    fn dialNode(self: *Self, node: discovery.Node) !void {
        const max_retries = 3;
        var retry_count: u32 = 0;
        var backoff_ms: u64 = 100; // Start with 100ms backoff

        while (retry_count < max_retries) : (retry_count += 1) {
            const result = self.attemptDial(node);

            if (result) |_| {
                return; // Success
            } else |err| {
                std.log.warn("Dial attempt {} failed: {}", .{ retry_count + 1, err });

                if (retry_count < max_retries - 1) {
                    std.time.sleep(backoff_ms * std.time.ns_per_ms);
                    backoff_ms *= 2; // Exponential backoff
                }
            }
        }

        return error.DialFailed;
    }

    /// Attempt to dial a node once
    fn attemptDial(self: *Self, node: discovery.Node) !void {
        // Create TCP connection with timeout
        const stream = std.net.tcpConnectToAddress(node.ip) catch |err| {
            std.log.debug("TCP connection failed: {}", .{err});
            return err;
        };
        errdefer stream.close();

        // Create RLPx connection (initiator side)
        const remote_pub = node.id[0..]; // TODO: Proper public key derivation
        var rlpx_conn = rlpx.Conn.init(self.allocator, stream, remote_pub);

        // Perform RLPx handshake
        rlpx_conn.handshake(&self.config.priv_key) catch |err| {
            std.log.debug("RLPx handshake failed: {}", .{err});
            stream.close();
            return err;
        };

        // Create peer
        const peer = try Peer.init(
            self.allocator,
            rlpx_conn,
            .outbound,
            self.config.protocols,
        );
        errdefer peer.deinit();

        // Perform devp2p handshake
        peer.doHandshake(self.config.name, self.config.priv_key) catch |err| {
            std.log.debug("DevP2P handshake failed: {}", .{err});
            peer.deinit();
            return err;
        };

        // Add to peer list
        try self.addPeer(peer);

        // Run peer in separate thread
        const peer_thread = try std.Thread.spawn(.{}, runPeerThread, .{ self, peer });
        peer_thread.detach();

        std.log.info("Successfully connected to peer", .{});
    }

    fn runPeerThread(self: *Self, peer: *Peer) !void {
        defer self.removePeer(peer);
        try peer.run();
    }
};

/// Peer connection state
pub const PeerState = enum {
    handshaking,
    active,
    disconnecting,
    disconnected,
};

/// Peer connection
pub const Peer = struct {
    allocator: std.mem.Allocator,
    conn: rlpx.Conn,
    direction: Direction,
    protocols: []Protocol,
    name: []const u8,
    running: bool,
    state: PeerState,
    last_ping: i64,
    last_pong: i64,
    connected_at: i64,
    disconnect_reason: ?devp2p.DisconnectReason,

    pub const Direction = enum {
        inbound,
        outbound,
    };

    const Self = @This();
    const PING_INTERVAL = 15; // Send ping every 15 seconds
    const PONG_TIMEOUT = 30; // Disconnect if no pong in 30 seconds
    const HANDSHAKE_TIMEOUT = 10; // Handshake must complete in 10 seconds

    pub fn init(allocator: std.mem.Allocator, conn: rlpx.Conn, direction: Direction, protocols: []Protocol) !*Self {
        const self = try allocator.create(Self);
        const now = std.time.timestamp();

        self.* = .{
            .allocator = allocator,
            .conn = conn,
            .direction = direction,
            .protocols = protocols,
            .name = "unknown",
            .running = false,
            .state = .handshaking,
            .last_ping = now,
            .last_pong = now,
            .connected_at = now,
            .disconnect_reason = null,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.running = false;
        self.conn.deinit();
        self.allocator.destroy(self);
    }

    /// Perform devp2p handshake with timeout
    pub fn doHandshake(self: *Self, client_name: []const u8, priv_key: [32]u8) !void {
        _ = priv_key;

        const start_time = std.time.timestamp();
        self.state = .handshaking;

        if (self.direction == .outbound) {
            // Send Hello message
            const hello = try devp2p.Hello.init(self.allocator, client_name, self.protocols);
            defer hello.deinit(self.allocator);

            const hello_payload = try hello.encode(self.allocator);
            defer self.allocator.free(hello_payload);

            try self.conn.writeMsg(@intFromEnum(devp2p.BaseMessageType.hello), hello_payload);
        }

        // Receive Hello with timeout
        const msg = try self.conn.readMsg();
        defer self.allocator.free(msg.payload);

        // Check timeout
        const elapsed = std.time.timestamp() - start_time;
        if (elapsed > HANDSHAKE_TIMEOUT) {
            self.state = .disconnected;
            return error.HandshakeTimeout;
        }

        if (msg.code != @intFromEnum(devp2p.BaseMessageType.hello)) {
            self.state = .disconnected;
            return error.ExpectedHello;
        }

        const hello = try devp2p.Hello.decode(self.allocator, msg.payload);
        defer hello.deinit(self.allocator);

        self.name = try self.allocator.dupe(u8, hello.client_id);

        if (self.direction == .inbound) {
            // Send our Hello response
            const our_hello = try devp2p.Hello.init(self.allocator, client_name, self.protocols);
            defer our_hello.deinit(self.allocator);

            const hello_payload = try our_hello.encode(self.allocator);
            defer self.allocator.free(hello_payload);

            try self.conn.writeMsg(@intFromEnum(devp2p.BaseMessageType.hello), hello_payload);
        }

        // Enable snappy compression if both sides support it
        self.conn.setSnappy(true);
        self.state = .active;

        std.log.info("Handshake completed with peer: {s}", .{self.name});
    }

    /// Run peer message loop with keepalive
    pub fn run(self: *Self) !void {
        self.running = true;
        var last_keepalive_check = std.time.timestamp();

        while (self.running and self.state == .active) {
            // Check if we need to send keepalive ping
            const now = std.time.timestamp();
            if (now - last_keepalive_check > PING_INTERVAL) {
                try self.sendPing();
                last_keepalive_check = now;
            }

            // Check for pong timeout
            if (now - self.last_pong > PONG_TIMEOUT) {
                std.log.warn("Peer timeout: no pong received", .{});
                self.disconnect(.timeout);
                break;
            }

            const msg = self.conn.readMsg() catch |err| {
                if (err == error.WouldBlock) {
                    std.time.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                std.log.err("Peer read error: {}", .{err});
                self.disconnect(.tcp_error);
                break;
            };
            defer self.allocator.free(msg.payload);

            // Handle base protocol messages
            if (msg.code <= 0x03) {
                try self.handleBaseMessage(msg.code, msg.payload);
            } else {
                // Dispatch to protocol handler
                try self.handleMessage(msg.code, msg.payload);
            }
        }
    }

    /// Send keepalive ping
    fn sendPing(self: *Self) !void {
        // Empty ping message
        try self.conn.writeMsg(@intFromEnum(devp2p.BaseMessageType.ping), &[_]u8{});
        self.last_ping = std.time.timestamp();
        std.log.debug("Sent keepalive ping to peer", .{});
    }

    /// Send pong response
    fn sendPong(self: *Self) !void {
        try self.conn.writeMsg(@intFromEnum(devp2p.BaseMessageType.pong), &[_]u8{});
        std.log.debug("Sent pong to peer", .{});
    }

    /// Handle base devp2p messages (ping/pong/disconnect)
    fn handleBaseMessage(self: *Self, code: u64, payload: []const u8) !void {
        const base_type: devp2p.BaseMessageType = @enumFromInt(code);

        switch (base_type) {
            .hello => {
                // Hello should only arrive during handshake
                std.log.warn("Unexpected Hello message", .{});
            },
            .disconnect => {
                var decoder = rlp.Decoder.init(payload);
                var list = try decoder.enterList();
                const reason_code: u8 = @intCast(try list.decodeInt());
                const reason: devp2p.DisconnectReason = @enumFromInt(reason_code);

                std.log.info("Peer disconnected: {}", .{reason});
                self.disconnect_reason = reason;
                self.running = false;
            },
            .ping => {
                // Respond with pong
                try self.sendPong();
            },
            .pong => {
                // Update last pong time
                self.last_pong = std.time.timestamp();
                std.log.debug("Received pong from peer", .{});
            },
        }
    }

    fn handleMessage(self: *Self, code: u64, payload: []const u8) !void {
        // Find matching protocol
        for (self.protocols) |proto| {
            if (code >= 0x10 and code < 0x10 + proto.length) {
                // Dispatch to protocol handler
                try proto.handler(self, code - 0x10, payload);
                return;
            }
        }

        std.log.warn("Unknown message code: {}", .{code});
    }

    /// Gracefully disconnect from peer
    pub fn disconnect(self: *Self, reason: devp2p.DisconnectReason) void {
        if (self.state == .disconnecting or self.state == .disconnected) {
            return;
        }

        self.state = .disconnecting;
        self.disconnect_reason = reason;

        std.log.info("Disconnecting peer {s}: {}", .{ self.name, reason });

        // Send disconnect message
        const disconnect_msg = devp2p.Disconnect{ .reason = reason };
        const payload = disconnect_msg.encode(self.allocator) catch {
            self.state = .disconnected;
            self.running = false;
            return;
        };
        defer self.allocator.free(payload);

        self.conn.writeMsg(@intFromEnum(devp2p.BaseMessageType.disconnect), payload) catch {};

        // Allow some time for message to be sent
        std.time.sleep(100 * std.time.ns_per_ms);

        self.state = .disconnected;
        self.running = false;
    }
};

test "server initialization" {
    const allocator = std.testing.allocator;

    var priv_key: [32]u8 = undefined;
    try std.crypto.random.bytes(&priv_key);

    const config = Config{
        .listen_addr = try std.net.Address.parseIp4("127.0.0.1", 30303),
        .discovery_port = 30301,
        .priv_key = priv_key,
        .bootnodes = &[_]discovery.Node{},
        .protocols = &[_]Protocol{},
    };

    const server = try Server.init(allocator, config);
    defer server.deinit();
}

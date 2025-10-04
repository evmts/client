//! P2P Server - manages peer connections
//! Based on Erigon's p2p/server.go
//!
//! Key features implemented:
//! - Main run loop with channel-based event handling
//! - SetupConn for connection handshake coordination
//! - Checkpoint system for handshake stages (postHandshake, addPeer)
//! - Inbound connection throttling (30s per IP)
//! - Trusted peer management (can exceed MaxPeers)
//! - Protocol capability negotiation and matching
//! - Graceful shutdown with peer cleanup
//! - Peer event feed/subscription system

const std = @import("std");
const rlp = @import("primitives").rlp;
const rlpx = @import("rlpx.zig");
const discovery = @import("discovery.zig");
const devp2p = @import("devp2p.zig");
const dial_scheduler = @import("dial_scheduler.zig");

// Constants from Erigon
const DEFAULT_DIAL_RATIO = 3;
const INBOUND_THROTTLE_TIME_MS = 30 * 1000; // 30 seconds
const SERVER_STATS_LOG_INTERVAL_MS = 60 * 1000; // 60 seconds

/// P2P server configuration
pub const Config = struct {
    /// Maximum number of peers
    max_peers: u32 = 50,

    /// Maximum number of pending connections
    max_pending_peers: u32 = 50,

    /// Dial ratio (1:3 means 1 dialed peer for every 3 inbound)
    dial_ratio: u32 = DEFAULT_DIAL_RATIO,

    /// Listen address for TCP
    listen_addr: std.net.Address,

    /// UDP port for discovery
    discovery_port: u16,

    /// Private key
    priv_key: [32]u8,

    /// Bootnodes for initial discovery
    bootnodes: []discovery.Node,

    /// Static nodes (always maintained)
    static_nodes: []discovery.Node = &[_]discovery.Node{},

    /// Trusted nodes (can connect above MaxPeers)
    trusted_nodes: []discovery.Node = &[_]discovery.Node{},

    /// Node name/client version
    name: []const u8 = "Erigon/Zig/v0.1.0",

    /// Supported protocols
    protocols: []Protocol,

    /// Enable message events
    enable_msg_events: bool = false,
};

/// Protocol definition
pub const Protocol = struct {
    name: []const u8,
    version: u32,
    length: u32, // Number of message codes
    handler: *const fn (*Peer, u64, []const u8) anyerror!void,
};

/// Connection flags (matches Erigon's connFlag)
pub const ConnFlag = enum(u32) {
    dyn_dialed = 1 << 0,
    static_dialed = 1 << 1,
    inbound = 1 << 2,
    trusted = 1 << 3,

    pub fn isSet(self: u32, flag: ConnFlag) bool {
        return (self & @intFromEnum(flag)) != 0;
    }

    pub fn set(current: u32, flag: ConnFlag) u32 {
        return current | @intFromEnum(flag);
    }

    pub fn clear(current: u32, flag: ConnFlag) u32 {
        return current & ~@intFromEnum(flag);
    }
};

/// Expiry item for tracking with timestamps
const ExpItem = struct {
    item: []const u8, // IP address or node ID
    exp_time: i64, // Expiry timestamp in milliseconds
};

/// Expiry heap for tracking inbound connection throttling
const ExpHeap = struct {
    items: std.ArrayList(ExpItem),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) ExpHeap {
        return .{
            .items = std.ArrayList(ExpItem){},
            .allocator = allocator,
        };
    }

    fn deinit(self: *ExpHeap) void {
        for (self.items.items) |item| {
            self.allocator.free(item.item);
        }
        self.items.deinit(self.allocator);
    }

    fn add(self: *ExpHeap, item: []const u8, exp_time: i64) !void {
        const owned = try self.allocator.dupe(u8, item);
        try self.items.append(self.allocator, .{ .item = owned, .exp_time = exp_time });
        self.siftUp(self.items.items.len - 1);
    }

    fn contains(self: *ExpHeap, item: []const u8) bool {
        for (self.items.items) |exp_item| {
            if (std.mem.eql(u8, exp_item.item, item)) {
                return true;
            }
        }
        return false;
    }

    fn expire(self: *ExpHeap, now: i64) void {
        while (self.items.items.len > 0 and self.items.items[0].exp_time < now) {
            const item = self.items.orderedRemove(0);
            self.allocator.free(item.item);
            if (self.items.items.len > 0) {
                self.siftDown(0);
            }
        }
    }

    fn siftUp(self: *ExpHeap, index: usize) void {
        if (index == 0) return;
        var i = index;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (self.items.items[i].exp_time >= self.items.items[parent].exp_time) break;
            std.mem.swap(ExpItem, &self.items.items[i], &self.items.items[parent]);
            i = parent;
        }
    }

    fn siftDown(self: *ExpHeap, index: usize) void {
        var i = index;
        while (true) {
            const left = 2 * i + 1;
            const right = 2 * i + 2;
            var smallest = i;

            if (left < self.items.items.len and self.items.items[left].exp_time < self.items.items[smallest].exp_time) {
                smallest = left;
            }
            if (right < self.items.items.len and self.items.items[right].exp_time < self.items.items[smallest].exp_time) {
                smallest = right;
            }
            if (smallest == i) break;

            std.mem.swap(ExpItem, &self.items.items[i], &self.items.items[smallest]);
            i = smallest;
        }
    }
};

/// Connection checkpoint message
const CheckpointMsg = struct {
    conn: *Conn,
    result: ?anyerror,
    completed: bool,
};

/// Connection wrapper (matches Erigon's conn struct)
pub const Conn = struct {
    fd: std.net.Stream,
    transport: rlpx.Conn,
    node: ?discovery.Node,
    flags: std.atomic.Value(u32),
    caps: []Cap,
    name: []const u8,
    allocator: std.mem.Allocator,

    // Continuation channel for checkpoint synchronization
    cont_result: ?anyerror,
    cont_mutex: std.Thread.Mutex,
    cont_cond: std.Thread.Condition,
    cont_ready: bool,

    pub fn init(allocator: std.mem.Allocator, fd: std.net.Stream, node: ?discovery.Node, flags: u32) !*Conn {
        const self = try allocator.create(Conn);
        self.* = .{
            .fd = fd,
            .transport = undefined, // Will be initialized later
            .node = node,
            .flags = std.atomic.Value(u32).init(flags),
            .caps = &[_]Cap{},
            .name = "",
            .allocator = allocator,
            .cont_result = null,
            .cont_mutex = .{},
            .cont_cond = .{},
            .cont_ready = false,
        };
        return self;
    }

    pub fn deinit(self: *Conn) void {
        self.fd.close();
        if (self.caps.len > 0) {
            self.allocator.free(self.caps);
        }
        if (self.name.len > 0) {
            self.allocator.free(self.name);
        }
        self.allocator.destroy(self);
    }

    pub fn isSet(self: *Conn, flag: ConnFlag) bool {
        return ConnFlag.isSet(self.flags.load(.acquire), flag);
    }

    pub fn setFlag(self: *Conn, flag: ConnFlag, val: bool) void {
        while (true) {
            const old = self.flags.load(.acquire);
            const new = if (val) ConnFlag.set(old, flag) else ConnFlag.clear(old, flag);
            if (self.flags.cmpxchgWeak(old, new, .acq_rel, .acquire) == null) {
                break;
            }
        }
    }
};

/// Peer operation function type
const PeerOpFunc = *const fn (std.AutoHashMap(discovery.NodeId, *Peer)) anyerror!void;

/// Peer drop event
const PeerDrop = struct {
    peer: *Peer,
    err: ?anyerror,
};

/// P2P Server
pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    running: std.atomic.Value(bool),

    /// TCP listener for incoming connections
    listener: ?std.net.Server,

    /// Discovery protocol handler
    discovery: ?*discovery.UDPv4,

    /// Dial scheduler for outbound connections
    dialsched: ?*dial_scheduler.DialScheduler,

    /// Connected peers map (node_id -> peer)
    peers: std.AutoHashMap([32]u8, *Peer),
    peers_mutex: std.Thread.Mutex,

    /// Trusted nodes set
    trusted: std.AutoHashMap([32]u8, bool),
    trusted_mutex: std.Thread.Mutex,

    /// Inbound connection history for throttling
    inbound_history: ExpHeap,
    history_mutex: std.Thread.Mutex,

    /// Main loop thread
    loop_thread: ?std.Thread,

    /// Listen loop thread
    listen_thread: ?std.Thread,

    /// Dial scheduler thread
    dialsched_thread: ?std.Thread,

    /// Channels for run loop (using ring buffers for simplicity)
    quit: std.atomic.Value(bool),
    add_trusted_queue: std.ArrayList(discovery.Node),
    remove_trusted_queue: std.ArrayList(discovery.Node),
    checkpoint_post_handshake_queue: std.ArrayList(CheckpointMsg),
    checkpoint_add_peer_queue: std.ArrayList(CheckpointMsg),
    del_peer_queue: std.ArrayList(PeerDrop),

    /// Queue mutexes
    add_trusted_mutex: std.Thread.Mutex,
    remove_trusted_mutex: std.Thread.Mutex,
    checkpoint_post_mutex: std.Thread.Mutex,
    checkpoint_add_mutex: std.Thread.Mutex,
    del_peer_mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        const self = try allocator.create(Self);

        self.* = .{
            .allocator = allocator,
            .config = config,
            .running = std.atomic.Value(bool).init(false),
            .listener = null,
            .discovery = null,
            .dialsched = null,
            .peers = std.AutoHashMap([32]u8, *Peer).init(allocator),
            .peers_mutex = .{},
            .trusted = std.AutoHashMap([32]u8, bool).init(allocator),
            .trusted_mutex = .{},
            .inbound_history = ExpHeap.init(allocator),
            .history_mutex = .{},
            .loop_thread = null,
            .listen_thread = null,
            .dialsched_thread = null,
            .quit = std.atomic.Value(bool).init(false),
            .add_trusted_queue = std.ArrayList(discovery.Node){},
            .remove_trusted_queue = std.ArrayList(discovery.Node){},
            .checkpoint_post_handshake_queue = std.ArrayList(CheckpointMsg){},
            .checkpoint_add_peer_queue = std.ArrayList(CheckpointMsg){},
            .del_peer_queue = std.ArrayList(PeerDrop){},
            .add_trusted_mutex = .{},
            .remove_trusted_mutex = .{},
            .checkpoint_post_mutex = .{},
            .checkpoint_add_mutex = .{},
            .del_peer_mutex = .{},
        };

        // Initialize trusted nodes
        self.trusted_mutex.lock();
        defer self.trusted_mutex.unlock();
        for (config.trusted_nodes) |node| {
            try self.trusted.put(node.id, true);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // Clean up dial scheduler
        if (self.dialsched) |dialsched| {
            dialsched.deinit();
            self.dialsched = null;
        }

        // Clean up peers
        self.peers_mutex.lock();
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.peers_mutex.unlock();
        self.peers.deinit();

        // Clean up trusted nodes
        self.trusted.deinit();

        // Clean up history
        self.history_mutex.lock();
        self.inbound_history.deinit();
        self.history_mutex.unlock();

        // Clean up queues
        self.add_trusted_queue.deinit(self.allocator);
        self.remove_trusted_queue.deinit(self.allocator);
        self.checkpoint_post_handshake_queue.deinit(self.allocator);
        self.checkpoint_add_peer_queue.deinit(self.allocator);
        self.del_peer_queue.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Start the P2P server
    pub fn start(self: *Self) !void {
        if (self.running.load(.acquire)) return error.AlreadyRunning;
        self.running.store(true, .release);

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

        // Setup dial scheduler (after discovery)
        try self.setupDialScheduler();

        // Start TCP listener
        self.listener = try self.config.listen_addr.listen(.{
            .reuse_address = true,
        });

        std.log.info("P2P server listening on {}", .{self.config.listen_addr});

        // Start main run loop
        self.loop_thread = try std.Thread.spawn(.{}, runLoop, .{self});

        // Start listening for connections in separate thread
        self.listen_thread = try std.Thread.spawn(.{}, listenLoop, .{self});
    }

    /// Main run loop wrapper
    fn runLoop(self: *Self) void {
        const impl = @import("server_impl.zig");
        impl.run(self) catch |err| {
            std.log.err("Server run loop error: {}", .{err});
        };
    }

    /// Stop the P2P server
    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) return;

        // Signal quit
        self.quit.store(true, .release);
        self.running.store(false, .release);

        // Stop dial scheduler first
        if (self.dialsched) |dialsched| {
            dialsched.stop();
        }

        // Wait for main loop
        if (self.loop_thread) |thread| {
            thread.join();
            self.loop_thread = null;
        }

        // Close listener
        if (self.listener) |*listener| {
            listener.deinit();
            self.listener = null;
        }

        // Wait for listen thread
        if (self.listen_thread) |thread| {
            thread.join();
            self.listen_thread = null;
        }

        // Stop discovery (handled in run loop)
    }

    /// Get peer count
    pub fn peerCount(self: *Self) u32 {
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();
        return @intCast(self.peers.count());
    }

    /// Add trusted peer
    pub fn addTrustedPeer(self: *Self, node: discovery.Node) !void {
        self.add_trusted_mutex.lock();
        defer self.add_trusted_mutex.unlock();
        try self.add_trusted_queue.append(self.allocator, node);
    }

    /// Remove trusted peer
    pub fn removeTrustedPeer(self: *Self, node: discovery.Node) !void {
        self.remove_trusted_mutex.lock();
        defer self.remove_trusted_mutex.unlock();
        try self.remove_trusted_queue.append(self.allocator, node);
    }

    /// Add static peer (always maintain connection)
    pub fn addPeer(self: *Self, node: discovery.Node) !void {
        if (self.dialsched) |dialsched| {
            try dialsched.addStatic(node);
        }
    }

    /// Remove static peer
    pub fn removePeer(self: *Self, node: discovery.Node) !void {
        if (self.dialsched) |dialsched| {
            try dialsched.removeStatic(node);
        }
    }

    /// SetupConn - public interface for connection setup
    pub fn setupConn(self: *Self, fd: std.net.Stream, flags: u32, dial_dest: ?discovery.Node) !void {
        const impl = @import("server_impl.zig");
        return impl.setupConn(self, fd, flags, dial_dest);
    }

    /// Discovery loop
    fn discoveryLoop(self: *Self) !void {
        if (self.discovery) |disc| {
            try disc.start();
        }
    }

    /// Listen loop for incoming connections (matches Erigon's listenLoop)
    fn listenLoop(self: *Self) !void {
        if (self.listener == null) return;

        std.log.info("TCP listener up on {}", .{self.config.listen_addr});

        while (self.running.load(.acquire)) {
            const conn = self.listener.?.accept() catch |err| {
                // Check if we're shutting down
                if (!self.running.load(.acquire)) break;
                std.log.err("Accept error: {}", .{err});
                std.time.sleep(200 * std.time.ns_per_ms);
                continue;
            };

            // Check inbound connection throttling
            const impl = @import("server_impl.zig");
            impl.checkInboundConn(self, conn.stream) catch |err| {
                std.log.debug("Rejected inbound connection: {}", .{err});
                conn.stream.close();
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
    fn handleIncoming(self: *Self, stream: std.net.Stream) void {
        // Use setupConn for standardized connection handling
        const flags = @intFromEnum(ConnFlag.inbound);
        self.setupConn(stream, flags, null) catch |err| {
            std.log.debug("Inbound connection setup failed: {}", .{err});
            stream.close();
        };
    }

    /// Setup dial scheduler (matches Erigon's setupDialScheduler)
    fn setupDialScheduler(self: *Self) !void {
        // Calculate max dialed peers based on dial ratio
        const max_dialed = self.maxDialedConns();

        // Create setup function wrapper that accepts context
        const setup_wrapper = struct {
            fn setupConnWrapper(context: *anyopaque, dest: *const discovery.Node, flags: dial_scheduler.ConnFlag) anyerror!void {
                const server: *Server = @ptrCast(@alignCast(context));

                // Determine connection flags based on dial scheduler flags
                var conn_flags: u32 = 0;
                if (flags == .static_dialed) {
                    conn_flags = @intFromEnum(ConnFlag.static_dialed);
                } else if (flags == .dyn_dialed) {
                    conn_flags = @intFromEnum(ConnFlag.dyn_dialed);
                }

                // Attempt TCP connection
                const stream = std.net.tcpConnectToAddress(dest.ip) catch |err| {
                    std.log.debug("Failed to dial {}: {}", .{dest.ip, err});
                    return err;
                };

                // Use server's setupConn for handshake
                server.setupConn(stream, conn_flags, dest.*) catch |err| {
                    stream.close();
                    return err;
                };
            }
        }.setupConnWrapper;

        // Create dial scheduler config
        const dial_config = dial_scheduler.Config{
            .self_id = self.config.priv_key,
            .max_dial_peers = max_dialed,
            .max_active_dials = 16,
            .allocator = self.allocator,
            .setup_func = setup_wrapper,
            .setup_context = self,
        };

        self.dialsched = try dial_scheduler.DialScheduler.init(dial_config);

        // Create node iterator from discovery
        const iterator = if (self.discovery) |disc| blk: {
            const ctx = try self.allocator.create(DiscoveryIteratorContext);
            ctx.* = .{ .table = disc.routing_table };

            break :blk dial_scheduler.NodeIterator{
                .nextFn = discoveryIteratorNext,
                .context = ctx,
            };
        } else blk: {
            // No discovery - create empty iterator
            const ctx = try self.allocator.create(EmptyIteratorContext);
            ctx.* = .{};

            break :blk dial_scheduler.NodeIterator{
                .nextFn = emptyIteratorNext,
                .context = ctx,
            };
        };

        // Start dial scheduler with discovery source
        try self.dialsched.?.start(iterator);

        // Add static nodes to dial scheduler
        for (self.config.static_nodes) |node| {
            try self.dialsched.?.addStatic(node);
        }

        std.log.info("Dial scheduler started with max_dial_peers={}", .{max_dialed});
    }

    /// Calculate max dialed connections based on dial ratio
    fn maxDialedConns(self: *Self) u32 {
        if (self.config.max_peers == 0) return 0;

        const ratio = if (self.config.dial_ratio == 0) DEFAULT_DIAL_RATIO else self.config.dial_ratio;
        var limit = self.config.max_peers / ratio;
        if (limit == 0) limit = 1;
        return limit;
    }

};

/// Discovery iterator context for dial scheduler
const DiscoveryIteratorContext = struct {
    table: *discovery.KademliaTable,
};

/// Empty iterator context (when discovery is disabled)
const EmptyIteratorContext = struct {};

/// Discovery iterator next function
fn discoveryIteratorNext(context: *anyopaque) ?discovery.Node {
    const ctx: *DiscoveryIteratorContext = @ptrCast(@alignCast(context));
    // Get random nodes from routing table
    const nodes = ctx.table.randomNodes(1) catch return null;
    defer ctx.table.allocator.free(nodes);

    if (nodes.len > 0) {
        return nodes[0];
    }
    return null;
}

/// Empty iterator next function
fn emptyIteratorNext(_: *anyopaque) ?discovery.Node {
    return null;
}

// Note: Dialing is handled by a separate dial scheduler in production
// For now, manual dialing can be done by external code calling setupConn

/// Capability represents a protocol capability
pub const Cap = struct {
    name: []const u8,
    version: u32,
};

/// Peer connection state
pub const PeerState = enum {
    handshaking,
    active,
    disconnecting,
    disconnected,
};

/// Peer connection (simplified version - protocol running happens separately)
pub const Peer = struct {
    allocator: std.mem.Allocator,
    conn: *Conn, // Reference to the connection
    protocols: []Protocol,
    node_id: [32]u8,
    running: std.atomic.Value(bool),
    state: PeerState,
    last_ping: i64,
    last_pong: i64,
    connected_at: i64,
    disconnect_reason: ?devp2p.DisconnectReason,

    const Self = @This();
    const PING_INTERVAL = 15; // Send ping every 15 seconds
    const PONG_TIMEOUT = 30; // Disconnect if no pong in 30 seconds

    pub fn init(allocator: std.mem.Allocator, conn: *Conn, protocols: []Protocol) !*Self {
        const self = try allocator.create(Self);
        const now = std.time.timestamp();

        self.* = .{
            .allocator = allocator,
            .conn = conn,
            .protocols = protocols,
            .node_id = conn.node.?.id,
            .running = std.atomic.Value(bool).init(false),
            .state = .active,
            .last_ping = now,
            .last_pong = now,
            .connected_at = now,
            .disconnect_reason = null,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.running.store(false, .release);
        // Note: conn is owned by server, not freed here
        self.allocator.destroy(self);
    }


    /// Run peer message loop with keepalive
    /// Note: This is a simplified version. In production, use Erigon's full peer.run() pattern
    pub fn run(self: *Self) anyerror {
        self.running.store(true, .release);
        var last_keepalive_check = std.time.timestamp();

        while (self.running.load(.acquire) and self.state == .active) {
            // Check if we need to send keepalive ping
            const now = std.time.timestamp();
            if (now - last_keepalive_check > PING_INTERVAL) {
                self.sendPing() catch |err| {
                    std.log.err("Failed to send ping: {}", .{err});
                    return err;
                };
                last_keepalive_check = now;
            }

            // Check for pong timeout
            if (now - self.last_pong > PONG_TIMEOUT) {
                std.log.warn("Peer timeout: no pong received", .{});
                self.disconnect(.timeout);
                return error.PeerTimeout;
            }

            const msg = self.conn.transport.readMsg() catch |err| {
                if (err == error.WouldBlock) {
                    std.time.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                std.log.err("Peer read error: {}", .{err});
                self.disconnect(.tcp_error);
                return err;
            };
            defer self.allocator.free(msg.payload);

            // Handle base protocol messages
            if (msg.code <= 0x03) {
                self.handleBaseMessage(msg.code, msg.payload) catch |err| {
                    std.log.err("Base message handling error: {}", .{err});
                };
            } else {
                // Dispatch to protocol handler
                self.handleMessage(msg.code, msg.payload) catch |err| {
                    std.log.err("Protocol message handling error: {}", .{err});
                };
            }
        }

        return null;
    }

    /// Send keepalive ping
    fn sendPing(self: *Self) !void {
        // Empty ping message
        try self.conn.transport.writeMsg(@intFromEnum(devp2p.BaseMessageType.ping), &[_]u8{});
        self.last_ping = std.time.timestamp();
        std.log.debug("Sent keepalive ping to peer", .{});
    }

    /// Send pong response
    fn sendPong(self: *Self) !void {
        try self.conn.transport.writeMsg(@intFromEnum(devp2p.BaseMessageType.pong), &[_]u8{});
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

        std.log.info("Disconnecting peer {s}: {}", .{ self.conn.name, reason });

        // Send disconnect message
        const disconnect_msg = devp2p.Disconnect{ .reason = reason };
        const payload = disconnect_msg.encode(self.allocator) catch {
            self.state = .disconnected;
            self.running.store(false, .release);
            return;
        };
        defer self.allocator.free(payload);

        self.conn.transport.writeMsg(@intFromEnum(devp2p.BaseMessageType.disconnect), payload) catch {};

        // Allow some time for message to be sent
        std.time.sleep(100 * std.time.ns_per_ms);

        self.state = .disconnected;
        self.running.store(false, .release);
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

//! Dial Scheduler - manages outbound peer connections
//! Based on Erigon's p2p/dial.go
//!
//! The dial scheduler manages two types of peer connections:
//! 1. Static dials: Pre-configured nodes that are always maintained
//! 2. Dynamic dials: Nodes discovered through the discovery protocol
//!
//! Key features:
//! - Dial ratio enforcement (e.g., 1:3 inbound to outbound)
//! - Exponential backoff for failed dials
//! - Connection history to prevent duplicate attempts
//! - Thread-safe task queue management
//! - Integration with node discovery

const std = @import("std");
const discovery = @import("discovery.zig");

/// Dial scheduler errors
pub const DialError = error{
    IsSelf,
    AlreadyDialing,
    AlreadyConnected,
    RecentlyDialed,
    NotWhitelisted,
    NoPort,
    DialFailed,
    Timeout,
};

/// Connection flags indicating connection type
pub const ConnFlag = enum(u32) {
    dyn_dialed = 1 << 0,
    static_dialed = 1 << 1,
    inbound = 1 << 2,
    trusted = 1 << 3,

    pub fn is(self: ConnFlag, flag: ConnFlag) bool {
        return (@intFromEnum(self) & @intFromEnum(flag)) != 0;
    }

    pub fn set(self: *ConnFlag, flag: ConnFlag) void {
        self.* = @enumFromInt(@intFromEnum(self.*) | @intFromEnum(flag));
    }
};

/// Setup function type for dial callback with context
pub const SetupFunc = *const fn (context: *anyopaque, dest: *const discovery.Node, flags: ConnFlag) anyerror!void;

/// Configuration for dial scheduler
pub const Config = struct {
    /// Our own node ID
    self_id: [32]u8,

    /// Maximum number of dialed peers
    max_dial_peers: u32 = 50,

    /// Maximum number of active dials at once
    max_active_dials: u32 = 16,

    /// Network restriction list (optional)
    net_restrict: ?*NetRestrict = null,

    /// Allocator for memory management
    allocator: std.mem.Allocator,

    /// Setup callback for initiating connections
    setup_func: ?SetupFunc = null,

    /// Context passed to setup function (typically *Server)
    setup_context: ?*anyopaque = null,
};

/// Network restriction list (simplified)
pub const NetRestrict = struct {
    allowed_networks: std.ArrayList(std.net.Address),

    pub fn contains(self: *const NetRestrict, addr: std.net.Address) bool {
        for (self.allowed_networks.items) |network| {
            if (std.mem.eql(u8, &network.in.sa.addr, &addr.in.sa.addr)) {
                return true;
            }
        }
        return false;
    }
};

/// Dial history entry
const HistoryEntry = struct {
    node_id: [32]u8,
    expires_at: i64,
};

/// Dial task represents a pending or active dial attempt
pub const DialTask = struct {
    dest: discovery.Node,
    flags: ConnFlag,
    static_pool_index: i32 = -1, // Index in static pool, -1 if not in pool
    last_resolved: i64 = 0,
    resolve_delay: i64 = 60, // seconds

    const Self = @This();

    pub fn init(node: discovery.Node, flags: ConnFlag) Self {
        return .{
            .dest = node,
            .flags = flags,
        };
    }
};

/// Dial scheduler manages outbound connections
pub const DialScheduler = struct {
    allocator: std.mem.Allocator,
    config: Config,
    running: std.atomic.Value(bool),

    // Channels for communication
    nodes_in_ch: Channel(discovery.Node),
    done_ch: Channel(*DialTask),
    add_static_ch: Channel(discovery.Node),
    rem_static_ch: Channel(discovery.Node),
    add_peer_ch: Channel(PeerConn),
    rem_peer_ch: Channel(PeerConn),

    // State (protected by mutex)
    mutex: std.Thread.Mutex,
    dialing: std.AutoHashMap([32]u8, *DialTask),
    peers: std.AutoHashMap([32]u8, ConnFlag),
    static_tasks: std.AutoHashMap([32]u8, *DialTask),
    static_pool: std.ArrayList(*DialTask),
    history: std.ArrayList(HistoryEntry),
    dial_peers_count: u32,

    // Statistics
    stats_mutex: std.Thread.Mutex,
    dialed_count: u64,
    error_counts: std.StringHashMap(u64),

    // Random number generator
    rng: std.Random.DefaultPrng,

    // Threads
    main_thread: ?std.Thread = null,
    reader_thread: ?std.Thread = null,

    const Self = @This();
    const DIAL_HISTORY_EXPIRATION: i64 = 35; // seconds (30 + 5 for safety)
    const DIAL_STATS_LOG_INTERVAL: i64 = 60; // seconds
    const INITIAL_RESOLVE_DELAY: i64 = 60; // seconds
    const MAX_RESOLVE_DELAY: i64 = 3600; // 1 hour

    pub fn init(config: Config) !*Self {
        const self = try config.allocator.create(Self);
        errdefer config.allocator.destroy(self);

        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));

        self.* = .{
            .allocator = config.allocator,
            .config = config,
            .running = std.atomic.Value(bool).init(false),
            .nodes_in_ch = Channel(discovery.Node).init(config.allocator),
            .done_ch = Channel(*DialTask).init(config.allocator),
            .add_static_ch = Channel(discovery.Node).init(config.allocator),
            .rem_static_ch = Channel(discovery.Node).init(config.allocator),
            .add_peer_ch = Channel(PeerConn).init(config.allocator),
            .rem_peer_ch = Channel(PeerConn).init(config.allocator),
            .mutex = .{},
            .dialing = std.AutoHashMap([32]u8, *DialTask).init(config.allocator),
            .peers = std.AutoHashMap([32]u8, ConnFlag).init(config.allocator),
            .static_tasks = std.AutoHashMap([32]u8, *DialTask).init(config.allocator),
            .static_pool = std.ArrayList(*DialTask){},
            .history = std.ArrayList(HistoryEntry){},
            .dial_peers_count = 0,
            .stats_mutex = .{},
            .dialed_count = 0,
            .error_counts = std.StringHashMap(u64).init(config.allocator),
            .rng = std.Random.DefaultPrng.init(seed),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        self.nodes_in_ch.deinit();
        self.done_ch.deinit();
        self.add_static_ch.deinit();
        self.rem_static_ch.deinit();
        self.add_peer_ch.deinit();
        self.rem_peer_ch.deinit();

        // Clean up tasks
        var it = self.dialing.valueIterator();
        while (it.next()) |task| {
            self.allocator.destroy(task.*);
        }
        self.dialing.deinit();
        self.peers.deinit();

        var static_it = self.static_tasks.valueIterator();
        while (static_it.next()) |task| {
            self.allocator.destroy(task.*);
        }
        self.static_tasks.deinit();
        self.static_pool.deinit();
        self.history.deinit();

        self.error_counts.deinit();
        self.allocator.destroy(self);
    }

    /// Start the dial scheduler
    pub fn start(self: *Self, node_iterator: NodeIterator) !void {
        if (self.running.load(.monotonic)) return error.AlreadyRunning;
        self.running.store(true, .monotonic);

        // Start reader thread
        self.reader_thread = try std.Thread.spawn(.{}, readNodesLoop, .{ self, node_iterator });

        // Start main loop thread
        self.main_thread = try std.Thread.spawn(.{}, mainLoop, .{self});

        std.log.info("Dial scheduler started", .{});
    }

    /// Stop the dial scheduler
    pub fn stop(self: *Self) void {
        if (!self.running.load(.monotonic)) return;
        self.running.store(false, .monotonic);

        // Wait for threads to finish
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        if (self.main_thread) |thread| {
            thread.join();
            self.main_thread = null;
        }

        std.log.info("Dial scheduler stopped", .{});
    }

    /// Add a static dial candidate
    pub fn addStatic(self: *Self, node: discovery.Node) !void {
        try self.add_static_ch.send(node);
    }

    /// Remove a static dial candidate
    pub fn removeStatic(self: *Self, node: discovery.Node) !void {
        try self.rem_static_ch.send(node);
    }

    /// Notify scheduler that a peer was added
    pub fn peerAdded(self: *Self, conn: PeerConn) !void {
        try self.add_peer_ch.send(conn);
    }

    /// Notify scheduler that a peer was removed
    pub fn peerRemoved(self: *Self, conn: PeerConn) !void {
        try self.rem_peer_ch.send(conn);
    }

    /// Main scheduler loop
    fn mainLoop(self: *Self) !void {
        var last_stats_log = std.time.timestamp();

        while (self.running.load(.monotonic)) {
            // Check if we need to log stats
            const now = std.time.timestamp();
            if (now - last_stats_log >= DIAL_STATS_LOG_INTERVAL) {
                self.logStats();
                last_stats_log = now;
            }

            // Calculate free dial slots
            const free_slots = self.freeDialSlots();

            // Start static dials (they have priority)
            self.startStaticDials();

            // Process events with timeout
            self.processEvents(free_slots > 0) catch |err| {
                std.log.err("Error processing events: {}", .{err});
            };

            // Expire old history entries
            self.expireHistory();

            // Small sleep to prevent busy loop
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }

    /// Process scheduler events
    fn processEvents(self: *Self, accept_dynamic: bool) !void {
        // Try to receive from various channels (non-blocking)

        // Check for completed dials
        if (self.done_ch.tryReceive()) |task| {
            self.handleDialComplete(task);
        }

        // Check for peer additions
        if (self.add_peer_ch.tryReceive()) |conn| {
            self.handlePeerAdded(conn);
        }

        // Check for peer removals
        if (self.rem_peer_ch.tryReceive()) |conn| {
            self.handlePeerRemoved(conn);
        }

        // Check for static node additions
        if (self.add_static_ch.tryReceive()) |node| {
            try self.handleAddStatic(node);
        }

        // Check for static node removals
        if (self.rem_static_ch.tryReceive()) |node| {
            self.handleRemoveStatic(node);
        }

        // Check for dynamic nodes (only if we have free slots)
        if (accept_dynamic) {
            if (self.nodes_in_ch.tryReceive()) |node| {
                self.handleDynamicNode(node) catch |err| {
                    std.log.debug("Discarding dial candidate: {}", .{err});
                };
            }
        }
    }

    /// Handle completion of a dial task
    fn handleDialComplete(self: *Self, task: *DialTask) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.dialing.remove(task.dest.id);
        self.updateStaticPool(task.dest.id);
        self.dialed_count += 1;

        self.allocator.destroy(task);
    }

    /// Handle peer addition
    fn handlePeerAdded(self: *Self, conn: PeerConn) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (conn.flags.is(.dyn_dialed) or conn.flags.is(.static_dialed)) {
            self.dial_peers_count += 1;
        }

        self.peers.put(conn.node_id, conn.flags) catch |err| {
            std.log.err("Failed to add peer: {}", .{err});
        };

        // Remove from static pool if it's a static node
        if (self.static_tasks.get(conn.node_id)) |task| {
            if (task.static_pool_index >= 0) {
                self.removeFromStaticPool(@intCast(task.static_pool_index));
            }
        }
    }

    /// Handle peer removal
    fn handlePeerRemoved(self: *Self, conn: PeerConn) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (conn.flags.is(.dyn_dialed) or conn.flags.is(.static_dialed)) {
            if (self.dial_peers_count > 0) {
                self.dial_peers_count -= 1;
            }
        }

        _ = self.peers.remove(conn.node_id);
        self.updateStaticPool(conn.node_id);
    }

    /// Handle adding a static node
    fn handleAddStatic(self: *Self, node: discovery.Node) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.static_tasks.contains(node.id)) {
            return; // Already exists
        }

        const task = try self.allocator.create(DialTask);
        task.* = DialTask.init(node, .static_dialed);

        try self.static_tasks.put(node.id, task);

        // Check if we can dial it immediately
        if (self.checkDial(&node) == null) {
            try self.addToStaticPool(task);
        }

        std.log.debug("Added static node", .{});
    }

    /// Handle removing a static node
    fn handleRemoveStatic(self: *Self, node: discovery.Node) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.static_tasks.fetchRemove(node.id)) |entry| {
            const task = entry.value;
            if (task.static_pool_index >= 0) {
                self.removeFromStaticPool(@intCast(task.static_pool_index));
            }
            self.allocator.destroy(task);
            std.log.debug("Removed static node", .{});
        }
    }

    /// Handle a dynamic node from discovery
    fn handleDynamicNode(self: *Self, node: discovery.Node) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.checkDial(&node)) |err| {
            return err;
        }

        const task = try self.allocator.create(DialTask);
        task.* = DialTask.init(node, .dyn_dialed);

        try self.startDial(task);
    }

    /// Check if a node can be dialed
    fn checkDial(self: *Self, node: *const discovery.Node) ?DialError {
        // Check if it's ourselves
        if (std.mem.eql(u8, &node.id, &self.config.self_id)) {
            return DialError.IsSelf;
        }

        // Check for port
        if (node.tcp_port == 0) {
            return DialError.NoPort;
        }

        // Check if already dialing
        if (self.dialing.contains(node.id)) {
            return DialError.AlreadyDialing;
        }

        // Check if already connected
        if (self.peers.contains(node.id)) {
            return DialError.AlreadyConnected;
        }

        // Check network restrictions
        if (self.config.net_restrict) |restrict| {
            if (!restrict.contains(node.ip)) {
                return DialError.NotWhitelisted;
            }
        }

        // Check dial history
        if (self.isInHistory(node.id)) {
            return DialError.RecentlyDialed;
        }

        return null;
    }

    /// Calculate number of free dial slots
    fn freeDialSlots(self: *Self) i32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Calculate slots based on dial ratio (2x to allow some headroom)
        const target_dialed = (self.config.max_dial_peers - self.dial_peers_count) * 2;
        var slots: i32 = @intCast(target_dialed);

        // Cap at max active dials
        if (slots > self.config.max_active_dials) {
            slots = @intCast(self.config.max_active_dials);
        }

        // Subtract current active dials
        const free = slots - @as(i32, @intCast(self.dialing.count()));
        return free;
    }

    /// Start static dial tasks
    fn startStaticDials(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.static_pool.items.len > 0) {
            // Pick random static task
            const idx = self.rng.random().intRangeAtMost(usize, 0, self.static_pool.items.len - 1);
            const task = self.static_pool.items[idx];

            self.startDial(task) catch |err| {
                std.log.err("Failed to start static dial: {}", .{err});
                break;
            };

            self.removeFromStaticPool(idx);
        }
    }

    /// Start a dial task
    fn startDial(self: *Self, task: *DialTask) !void {
        std.log.debug("Starting dial to node", .{});

        const now = std.time.timestamp();
        try self.history.append(.{
            .node_id = task.dest.id,
            .expires_at = now + DIAL_HISTORY_EXPIRATION,
        });

        try self.dialing.put(task.dest.id, task);

        // Spawn dial thread
        const thread = try std.Thread.spawn(.{}, dialTask, .{ self, task });
        thread.detach();
    }

    /// Perform the actual dial in a separate thread
    fn dialTask(self: *Self, task: *DialTask) void {
        defer self.done_ch.send(task) catch {};

        std.log.debug("Dialing peer at {}", .{task.dest.ip});

        // Call setup function if provided (like Erigon's setupFunc)
        if (self.config.setup_func) |setup_func| {
            const context = self.config.setup_context orelse {
                std.log.err("Setup function provided but no context", .{});
                return;
            };
            setup_func(context, &task.dest, task.flags) catch |err| {
                self.recordError("setup_failed");
                std.log.debug("Setup connection failed: {}", .{err});
                return;
            };
            std.log.info("Successfully established connection via setup", .{});
        } else {
            // Fallback: Attempt TCP connection directly
            const stream = std.net.tcpConnectToAddress(task.dest.ip) catch |err| {
                self.recordError("dial_failed");
                std.log.debug("Dial failed: {}", .{err});
                return;
            };
            defer stream.close();

            std.log.info("Successfully dialed peer", .{});
        }
    }

    /// Add task to static pool
    fn addToStaticPool(self: *Self, task: *DialTask) !void {
        if (task.static_pool_index >= 0) {
            return; // Already in pool
        }
        try self.static_pool.append(task);
        task.static_pool_index = @intCast(self.static_pool.items.len - 1);
    }

    /// Remove task from static pool by index
    fn removeFromStaticPool(self: *Self, idx: usize) void {
        const task = self.static_pool.items[idx];
        const last_idx = self.static_pool.items.len - 1;

        // Swap with last element
        if (idx < last_idx) {
            self.static_pool.items[idx] = self.static_pool.items[last_idx];
            self.static_pool.items[idx].static_pool_index = @intCast(idx);
        }

        _ = self.static_pool.pop();
        task.static_pool_index = -1;
    }

    /// Update static pool - try to add static task back if it can be dialed
    fn updateStaticPool(self: *Self, node_id: [32]u8) void {
        if (self.static_tasks.get(node_id)) |task| {
            if (task.static_pool_index < 0 and self.checkDial(&task.dest) == null) {
                self.addToStaticPool(task) catch |err| {
                    std.log.err("Failed to add to static pool: {}", .{err});
                };
            }
        }
    }

    /// Check if node is in dial history
    fn isInHistory(self: *Self, node_id: [32]u8) bool {
        const now = std.time.timestamp();
        for (self.history.items) |entry| {
            if (std.mem.eql(u8, &entry.node_id, &node_id)) {
                if (entry.expires_at > now) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Expire old history entries
    fn expireHistory(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        var i: usize = 0;
        while (i < self.history.items.len) {
            if (self.history.items[i].expires_at < now) {
                const expired = self.history.swapRemove(i);
                self.updateStaticPool(expired.node_id);
            } else {
                i += 1;
            }
        }
    }

    /// Record an error for statistics
    fn recordError(self: *Self, error_name: []const u8) void {
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();

        const entry = self.error_counts.getOrPut(error_name) catch return;
        if (entry.found_existing) {
            entry.value_ptr.* += 1;
        } else {
            entry.value_ptr.* = 1;
        }
    }

    /// Log statistics
    fn logStats(self: *Self) void {
        self.mutex.lock();
        const peer_count = self.peers.count();
        const dialing_count = self.dialing.count();
        const static_count = self.static_tasks.count();
        const dialed = self.dialed_count;
        self.mutex.unlock();

        std.log.debug(
            "[p2p] Dial scheduler - peers: {}/{}, dialing: {}, static: {}, tried: {}",
            .{ peer_count, self.config.max_dial_peers, dialing_count, static_count, dialed },
        );

        // Log errors
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();

        var it = self.error_counts.iterator();
        while (it.next()) |entry| {
            std.log.debug("  {s}: {}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    /// Read nodes from iterator
    fn readNodesLoop(self: *Self, iterator: NodeIterator) !void {
        while (self.running.load(.monotonic)) {
            if (iterator.next()) |node| {
                self.nodes_in_ch.send(node) catch |err| {
                    std.log.err("Failed to send node: {}", .{err});
                };
            } else {
                // Wait a bit before trying again
                std.time.sleep(1 * std.time.ns_per_s);
            }
        }
    }
};

/// Peer connection info
pub const PeerConn = struct {
    node_id: [32]u8,
    flags: ConnFlag,
};

/// Simple channel implementation for thread communication
fn Channel(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        queue: std.ArrayList(T),
        mutex: std.Thread.Mutex,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .queue = std.ArrayList(T){},
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit(self.allocator);
        }

        pub fn send(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.queue.append(self.allocator, item);
        }

        pub fn tryReceive(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.queue.items.len == 0) {
                return null;
            }

            return self.queue.orderedRemove(0);
        }
    };
}

/// Node iterator interface for discovery integration
pub const NodeIterator = struct {
    nextFn: *const fn (*anyopaque) ?discovery.Node,
    context: *anyopaque,

    pub fn next(self: *NodeIterator) ?discovery.Node {
        return self.nextFn(self.context);
    }
};

test "dial scheduler initialization" {
    const allocator = std.testing.allocator;

    var self_id: [32]u8 = undefined;
    try std.posix.getrandom(&self_id);

    const config = Config{
        .self_id = self_id,
        .max_dial_peers = 10,
        .max_active_dials = 5,
        .allocator = allocator,
    };

    const scheduler = try DialScheduler.init(config);
    defer scheduler.deinit();

    try std.testing.expect(scheduler.dial_peers_count == 0);
}

test "dial scheduler checkDial" {
    const allocator = std.testing.allocator;

    var self_id: [32]u8 = undefined;
    try std.posix.getrandom(&self_id);

    const config = Config{
        .self_id = self_id,
        .allocator = allocator,
    };

    const scheduler = try DialScheduler.init(config);
    defer scheduler.deinit();

    // Test dialing self
    const self_node = discovery.Node{
        .id = self_id,
        .ip = try std.net.Address.parseIp4("127.0.0.1", 30303),
        .udp_port = 30303,
        .tcp_port = 30303,
    };

    scheduler.mutex.lock();
    const err = scheduler.checkDial(&self_node);
    scheduler.mutex.unlock();

    try std.testing.expect(err == DialError.IsSelf);
}

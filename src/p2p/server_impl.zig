//! P2P Server Implementation - Core methods
//! This file contains the main run loop, SetupConn, and checkpoint system

const std = @import("std");
const net = std.net;
const Server = @import("server.zig").Server;
const Conn = @import("server.zig").Conn;
const ConnFlag = @import("server.zig").ConnFlag;
const Peer = @import("server.zig").Peer;
const CheckpointMsg = @import("server.zig").CheckpointMsg;
const discovery = @import("discovery.zig");
const rlpx = @import("rlpx.zig");
const devp2p = @import("devp2p.zig");
const dial_scheduler = @import("dial_scheduler.zig");

/// Main run loop (matches Erigon's Server.run())
pub fn run(self: *Server) !void {
    defer {
        // Cleanup on exit
        if (self.discovery) |disc| {
            disc.deinit();
        }
    }

    std.log.info("Started P2P networking, self={s}, name={s}", .{ "node_id", self.config.name });

    var stats_timer = std.time.milliTimestamp();
    var inbound_count: u32 = 0;

    while (!self.quit.load(.acquire)) {
        // Process queues (non-blocking)
        try self.processAddTrusted();
        try self.processRemoveTrusted();
        try self.processCheckpointPostHandshake();
        try self.processCheckpointAddPeer(&inbound_count);
        try self.processDelPeer(&inbound_count);

        // Log stats periodically
        const now = std.time.milliTimestamp();
        if (now - stats_timer > SERVER_STATS_LOG_INTERVAL_MS) {
            self.logStats(inbound_count);
            stats_timer = now;
        }

        // Sleep briefly to avoid busy-waiting
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Shutdown: disconnect all peers
    std.log.info("P2P networking is spinning down", .{});
    self.peers_mutex.lock();
    var it = self.peers.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.disconnect(.requested);
    }
    self.peers_mutex.unlock();

    // Wait for all peers to disconnect
    while (true) {
        self.peers_mutex.lock();
        const count = self.peers.count();
        self.peers_mutex.unlock();
        if (count == 0) break;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

/// Process add trusted queue
fn processAddTrusted(self: *Server) !void {
    self.add_trusted_mutex.lock();
    defer self.add_trusted_mutex.unlock();

    while (self.add_trusted_queue.items.len > 0) {
        const node = self.add_trusted_queue.orderedRemove(0);

        self.trusted_mutex.lock();
        try self.trusted.put(node.id, true);
        self.trusted_mutex.unlock();

        // Mark existing peer as trusted
        self.peers_mutex.lock();
        if (self.peers.get(node.id)) |peer| {
            peer.conn.setFlag(.trusted, true);
        }
        self.peers_mutex.unlock();

        std.log.debug("Added trusted node", .{});
    }
}

/// Process remove trusted queue
fn processRemoveTrusted(self: *Server) !void {
    self.remove_trusted_mutex.lock();
    defer self.remove_trusted_mutex.unlock();

    while (self.remove_trusted_queue.items.len > 0) {
        const node = self.remove_trusted_queue.orderedRemove(0);

        self.trusted_mutex.lock();
        _ = self.trusted.remove(node.id);
        self.trusted_mutex.unlock();

        // Unmark existing peer
        self.peers_mutex.lock();
        if (self.peers.get(node.id)) |peer| {
            peer.conn.setFlag(.trusted, false);
        }
        self.peers_mutex.unlock();

        std.log.debug("Removed trusted node", .{});
    }
}

/// Process checkpoint post-handshake queue
fn processCheckpointPostHandshake(self: *Server) !void {
    self.checkpoint_post_mutex.lock();
    defer self.checkpoint_post_mutex.unlock();

    while (self.checkpoint_post_handshake_queue.items.len > 0) {
        var msg = &self.checkpoint_post_handshake_queue.items[0];

        // Check if node is trusted
        self.trusted_mutex.lock();
        const is_trusted = self.trusted.contains(msg.conn.node.?.id);
        self.trusted_mutex.unlock();

        if (is_trusted) {
            msg.conn.setFlag(.trusted, true);
        }

        // Signal completion
        msg.conn.cont_mutex.lock();
        msg.conn.cont_result = null; // No error
        msg.conn.cont_ready = true;
        msg.conn.cont_cond.signal();
        msg.conn.cont_mutex.unlock();

        _ = self.checkpoint_post_handshake_queue.orderedRemove(0);
    }
}

/// Process checkpoint add peer queue
fn processCheckpointAddPeer(self: *Server, inbound_count: *u32) !void {
    self.checkpoint_add_mutex.lock();
    defer self.checkpoint_add_mutex.unlock();

    while (self.checkpoint_add_peer_queue.items.len > 0) {
        var msg = &self.checkpoint_add_peer_queue.items[0];

        // Perform post-handshake checks
        const check_err = self.postHandshakeChecks(msg.conn, inbound_count.*);

        if (check_err == null) {
            // Success - add the peer
            const peer = try self.launchPeer(msg.conn);

            self.peers_mutex.lock();
            try self.peers.put(msg.conn.node.?.id, peer);
            self.peers_mutex.unlock();

            if (msg.conn.isSet(.inbound)) {
                inbound_count.* += 1;
            }

            // Notify dial scheduler about peer addition
            if (self.dialsched) |dialsched| {
                const flags: dial_scheduler.ConnFlag = if (msg.conn.isSet(.static_dialed))
                    .static_dialed
                else if (msg.conn.isSet(.dyn_dialed))
                    .dyn_dialed
                else
                    .inbound;

                dialsched.peerAdded(.{
                    .node_id = msg.conn.node.?.id,
                    .flags = flags,
                }) catch |err| {
                    std.log.err("Failed to notify dial scheduler of peer addition: {}", .{err});
                };
            }

            std.log.info("Adding p2p peer, peercount={}, name={s}", .{ self.peers.count(), msg.conn.name });
        }

        // Signal completion
        msg.conn.cont_mutex.lock();
        msg.conn.cont_result = check_err;
        msg.conn.cont_ready = true;
        msg.conn.cont_cond.signal();
        msg.conn.cont_mutex.unlock();

        _ = self.checkpoint_add_peer_queue.orderedRemove(0);
    }
}

/// Process delete peer queue
fn processDelPeer(self: *Server, inbound_count: *u32) !void {
    self.del_peer_mutex.lock();
    defer self.del_peer_mutex.unlock();

    while (self.del_peer_queue.items.len > 0) {
        const drop = self.del_peer_queue.orderedRemove(0);

        self.peers_mutex.lock();
        const was_inbound = drop.peer.conn.isSet(.inbound);
        const node_id = drop.peer.node_id;
        const was_static = drop.peer.conn.isSet(.static_dialed);
        const was_dynamic = drop.peer.conn.isSet(.dyn_dialed);
        _ = self.peers.remove(drop.peer.node_id);
        self.peers_mutex.unlock();

        if (was_inbound) {
            inbound_count.* -= 1;
        }

        // Notify dial scheduler about peer removal
        if (self.dialsched) |dialsched| {
            const flags: dial_scheduler.ConnFlag = if (was_static)
                .static_dialed
            else if (was_dynamic)
                .dyn_dialed
            else
                .inbound;

            dialsched.peerRemoved(.{
                .node_id = node_id,
                .flags = flags,
            }) catch |err| {
                std.log.err("Failed to notify dial scheduler of peer removal: {}", .{err});
            };
        }

        std.log.debug("Removing p2p peer, peercount={}", .{self.peers.count()});

        drop.peer.deinit();
    }
}

/// Post-handshake checks (matches Erigon's postHandshakeChecks)
fn postHandshakeChecks(self: *Server, conn: *Conn, inbound_count: u32) ?anyerror {
    const is_trusted = conn.isSet(.trusted);
    const is_inbound = conn.isSet(.inbound);

    self.peers_mutex.lock();
    const peer_count = self.peers.count();
    const peer_exists = self.peers.contains(conn.node.?.id);
    self.peers_mutex.unlock();

    // Check: too many peers (unless trusted)
    if (!is_trusted and peer_count >= self.config.max_peers) {
        return error.TooManyPeers;
    }

    // Check: too many inbound peers (unless trusted)
    if (!is_trusted and is_inbound) {
        const max_inbound = self.maxInboundConns();
        if (inbound_count >= max_inbound) {
            return error.TooManyPeers;
        }
    }

    // Check: already connected
    if (peer_exists) {
        return error.AlreadyConnected;
    }

    // Check: connecting to self
    // TODO: Compare with our node ID

    // Check: protocol capability match
    if (self.config.protocols.len > 0) {
        const matching = countMatchingProtocols(self.config.protocols, conn.caps);
        if (matching == 0) {
            return error.UselessPeer;
        }
    }

    return null;
}

const Cap = @import("server.zig").Cap;

/// Count matching protocols between server and connection
fn countMatchingProtocols(server_protos: []const Protocol, conn_caps: []Cap) u32 {
    var count: u32 = 0;
    for (server_protos) |proto| {
        for (conn_caps) |cap| {
            if (std.mem.eql(u8, proto.name, cap.name) and proto.version == cap.version) {
                count += 1;
                break;
            }
        }
    }
    return count;
}

/// Launch peer and start its goroutine
fn launchPeer(self: *Server, conn: *Conn) !*Peer {
    const peer = try Peer.init(self.allocator, conn, self.config.protocols);

    // Spawn peer run loop in separate thread
    const peer_thread = try std.Thread.spawn(.{}, runPeerThread, .{ self, peer });
    peer_thread.detach();

    return peer;
}

/// Run peer thread (handles peer disconnection)
fn runPeerThread(self: *Server, peer: *Peer) !void {
    // Run the peer
    const err = peer.run();

    // Add to delete queue
    self.del_peer_mutex.lock();
    try self.del_peer_queue.append(.{ .peer = peer, .err = err });
    self.del_peer_mutex.unlock();
}

/// SetupConn - coordinates connection handshakes (matches Erigon's SetupConn)
pub fn setupConn(self: *Server, fd: std.net.Stream, flags: u32, dial_dest: ?discovery.Node) !void {
    const conn = try Conn.init(self.allocator, fd, dial_dest, flags);
    errdefer conn.deinit();

    // Initialize transport
    const stream = net.Stream{ .handle = fd };
    if (dial_dest) |dest| {
        conn.transport = rlpx.Conn.init(self.allocator, stream, dest.id);
    } else {
        conn.transport = rlpx.Conn.init(self.allocator, stream, null);
    }

    // Run the handshake sequence
    try self.setupConnHandshakes(conn, dial_dest);
}

/// Setup connection handshakes
fn setupConnHandshakes(self: *Server, conn: *Conn, dial_dest: ?discovery.Node) !void {
    // Check if server is still running
    if (!self.running.load(.acquire)) {
        return error.ServerStopped;
    }

    // Perform RLPx encryption handshake
    const remote_pubkey = try conn.transport.doEncHandshake(&self.config.priv_key);
    _ = remote_pubkey;

    // Set node from dial destination or derive from pubkey
    if (dial_dest) |dest| {
        conn.node = dest;
    } else {
        // TODO: Derive node from remote_pubkey
        return error.NotImplemented;
    }

    // Checkpoint: post-handshake (check trust list, set trusted flag)
    try self.checkpoint(conn, .post_handshake);

    // Perform protocol handshake
    const our_handshake = try self.buildHandshake();
    const their_handshake = try conn.transport.doProtoHandshake(our_handshake);

    // Store capabilities and name
    conn.caps = try self.allocator.dupe(devp2p.Capability, their_handshake.caps);
    conn.name = try self.allocator.dupe(u8, their_handshake.name);

    // Checkpoint: add peer (check peer limits, add to peer map)
    try self.checkpoint(conn, .add_peer);
}

/// Checkpoint - synchronizes with main run loop
fn checkpoint(self: *Server, conn: *Conn, stage: enum { post_handshake, add_peer }) !void {
    const msg = CheckpointMsg{
        .conn = conn,
        .result = null,
        .completed = false,
    };

    // Add to appropriate queue
    switch (stage) {
        .post_handshake => {
            self.checkpoint_post_mutex.lock();
            try self.checkpoint_post_handshake_queue.append(msg);
            self.checkpoint_post_mutex.unlock();
        },
        .add_peer => {
            self.checkpoint_add_mutex.lock();
            try self.checkpoint_add_peer_queue.append(msg);
            self.checkpoint_add_mutex.unlock();
        },
    }

    // Wait for completion
    conn.cont_mutex.lock();
    while (!conn.cont_ready) {
        conn.cont_cond.wait(&conn.cont_mutex);
    }
    const result = conn.cont_result;
    conn.cont_ready = false;
    conn.cont_mutex.unlock();

    if (result) |err| {
        return err;
    }
}

/// Build our handshake message
fn buildHandshake(self: *Server) !devp2p.ProtoHandshake {
    var caps = try self.allocator.alloc(Cap, self.config.protocols.len);
    for (self.config.protocols, 0..) |proto, i| {
        caps[i] = .{
            .name = proto.name,
            .version = proto.version,
        };
    }

    return .{
        .version = 5, // baseProtocolVersion
        .name = self.config.name,
        .caps = caps,
        .listen_port = 0, // TODO: Get from config
        .id = &[_]u8{0} ** 64, // TODO: Get from private key
    };
}

/// Check inbound connection (throttling)
pub fn checkInboundConn(self: *Server, fd: std.net.Stream) !void {
    const remote_addr = fd.getRemoteAddress() catch return error.NoRemoteAddress;

    // Get IP string
    var ip_buf: [64]u8 = undefined;
    const ip_str = switch (remote_addr.any.family) {
        std.posix.AF.INET => blk: {
            const addr = remote_addr.in;
            break :blk try std.fmt.bufPrint(&ip_buf, "{}.{}.{}.{}", .{
                addr.sa.addr >> 0 & 0xFF,
                addr.sa.addr >> 8 & 0xFF,
                addr.sa.addr >> 16 & 0xFF,
                addr.sa.addr >> 24 & 0xFF,
            });
        },
        else => return, // Skip check for non-IPv4
    };

    self.history_mutex.lock();
    defer self.history_mutex.unlock();

    // Expire old entries
    const now = std.time.milliTimestamp();
    self.inbound_history.expire(now);

    // Check if IP recently attempted connection
    if (self.inbound_history.contains(ip_str)) {
        return error.TooManyAttempts;
    }

    // Add to history with expiry time
    const exp_time = now + INBOUND_THROTTLE_TIME_MS;
    try self.inbound_history.add(ip_str, exp_time);
}

/// Calculate max inbound connections
fn maxInboundConns(self: *Server) u32 {
    const max_dialed = self.maxDialedConns();
    return self.config.max_peers - max_dialed;
}

/// Calculate max dialed connections
fn maxDialedConns(self: *Server) u32 {
    if (self.config.max_peers == 0) return 0;

    const ratio = if (self.config.dial_ratio == 0) DEFAULT_DIAL_RATIO else self.config.dial_ratio;
    var limit = self.config.max_peers / ratio;
    if (limit == 0) limit = 1;
    return limit;
}

/// Log server statistics
fn logStats(self: *Server, inbound_count: u32) void {
    self.peers_mutex.lock();
    const peer_count = self.peers.count();
    self.peers_mutex.unlock();

    self.trusted_mutex.lock();
    const trusted_count = self.trusted.count();
    self.trusted_mutex.unlock();

    std.log.debug("[p2p] Server peers={} trusted={} inbound={}", .{
        peer_count, trusted_count, inbound_count
    });
}

const SERVER_STATS_LOG_INTERVAL_MS = 60 * 1000;
const DEFAULT_DIAL_RATIO = 3;
const INBOUND_THROTTLE_TIME_MS = 30 * 1000;
const Protocol = @import("server.zig").Protocol;

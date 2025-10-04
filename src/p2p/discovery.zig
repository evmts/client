//! Discovery v4 protocol implementation
//! Based on Erigon's p2p/discover/v4_udp.go
//!
//! Node Discovery Protocol v4 uses Kademlia-like DHT for peer finding.
//! Spec: https://github.com/ethereum/devp2p/blob/master/discv4.md

const std = @import("std");
const crypto = @import("../crypto.zig");
const rlp = @import("../rlp.zig");

const PROTOCOL_VERSION: u8 = 4;
const MAX_PACKET_SIZE: usize = 1280;
const MAC_SIZE: usize = 32;
const SIG_SIZE: usize = 65;
const HEAD_SIZE: usize = MAC_SIZE + SIG_SIZE; // 97 bytes
const MAX_NEIGHBORS: usize = 12; // Maximum neighbors in one packet

/// Discovery v4 packet types
/// Based on erigon/p2p/discover/v4wire/v4wire.go
pub const PacketType = enum(u8) {
    ping = 0x01,
    pong = 0x02,
    find_node = 0x03,
    neighbors = 0x04,
    enr_request = 0x05,
    enr_response = 0x06,
};

pub const DiscoveryError = error{
    PacketTooSmall,
    BadHash,
    BadSignature,
    InvalidPacketType,
    ExpiredPacket,
    InvalidEndpoint,
};

/// Node representation
pub const Node = struct {
    id: [32]u8, // Node ID (public key hash)
    ip: std.net.Address,
    udp_port: u16,
    tcp_port: u16,

    pub fn fromEndpoint(endpoint: Endpoint, id: [32]u8) Node {
        return .{
            .id = id,
            .ip = endpoint.ip,
            .udp_port = endpoint.udp_port,
            .tcp_port = endpoint.tcp_port,
        };
    }

    pub fn distance(self: *const Node, other: *const Node) u256 {
        // XOR distance for Kademlia
        var dist: u256 = 0;
        for (self.id, 0..) |byte, i| {
            const xor_byte = byte ^ other.id[i];
            dist = (dist << 8) | @as(u256, xor_byte);
        }
        return dist;
    }
};

/// Network endpoint
pub const Endpoint = struct {
    ip: std.net.Address,
    udp_port: u16,
    tcp_port: u16,

    pub fn encode(self: *const Endpoint, encoder: *rlp.Encoder) !void {
        try encoder.startList();

        // Encode IP address
        const ip_bytes = switch (self.ip.any.family) {
            std.os.AF.INET => blk: {
                const addr = self.ip.in.sa.addr;
                break :blk std.mem.asBytes(&addr);
            },
            std.os.AF.INET6 => blk: {
                const addr = self.ip.in6.sa.addr;
                break :blk std.mem.asBytes(&addr);
            },
            else => return error.UnsupportedAddressFamily,
        };
        try encoder.writeBytes(ip_bytes);

        try encoder.writeInt(self.udp_port);
        try encoder.writeInt(self.tcp_port);
        try encoder.endList();
    }
};

/// Ping packet
pub const Ping = struct {
    version: u8,
    from: Endpoint,
    to: Endpoint,
    expiration: u64,
    enr_seq: ?u64, // ENR sequence number (optional)

    pub fn encode(self: *const Ping, allocator: std.mem.Allocator) ![]u8 {
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();
        try encoder.writeInt(self.version);
        try self.from.encode(&encoder);
        try self.to.encode(&encoder);
        try encoder.writeInt(self.expiration);
        if (self.enr_seq) |seq| {
            try encoder.writeInt(seq);
        }
        try encoder.endList();

        return encoder.toOwnedSlice();
    }
};

/// Pong packet
pub const Pong = struct {
    to: Endpoint,
    ping_hash: [32]u8,
    expiration: u64,
    enr_seq: ?u64,

    pub fn encode(self: *const Pong, allocator: std.mem.Allocator) ![]u8 {
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();
        try self.to.encode(&encoder);
        try encoder.writeBytes(&self.ping_hash);
        try encoder.writeInt(self.expiration);
        if (self.enr_seq) |seq| {
            try encoder.writeInt(seq);
        }
        try encoder.endList();

        return encoder.toOwnedSlice();
    }
};

/// FindNode packet
pub const FindNode = struct {
    target: [32]u8, // Target node ID
    expiration: u64,

    pub fn encode(self: *const FindNode, allocator: std.mem.Allocator) ![]u8 {
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();
        try encoder.writeBytes(&self.target);
        try encoder.writeInt(self.expiration);
        try encoder.endList();

        return encoder.toOwnedSlice();
    }
};

/// Neighbors packet
pub const Neighbors = struct {
    nodes: []Node,
    expiration: u64,

    pub fn encode(self: *const Neighbors, allocator: std.mem.Allocator) ![]u8 {
        var encoder = rlp.Encoder.init(allocator);
        defer encoder.deinit();

        try encoder.startList();

        // Encode nodes list
        try encoder.startList();
        for (self.nodes) |node| {
            try encoder.startList();

            // Encode IP
            const ip_bytes = switch (node.ip.any.family) {
                std.os.AF.INET => blk: {
                    const addr = node.ip.in.sa.addr;
                    break :blk std.mem.asBytes(&addr);
                },
                std.os.AF.INET6 => blk: {
                    const addr = node.ip.in6.sa.addr;
                    break :blk std.mem.asBytes(&addr);
                },
                else => return error.UnsupportedAddressFamily,
            };
            try encoder.writeBytes(ip_bytes);

            try encoder.writeInt(node.udp_port);
            try encoder.writeInt(node.tcp_port);
            try encoder.writeBytes(&node.id);
            try encoder.endList();
        }
        try encoder.endList();

        try encoder.writeInt(self.expiration);
        try encoder.endList();

        return encoder.toOwnedSlice();
    }
};

/// Bootstrap state
pub const BootstrapState = enum {
    idle,
    bonding,
    discovering,
    completed,
};

/// Pending ping tracker for bond verification
pub const PendingPing = struct {
    node_id: [32]u8,
    sent_at: i64,
    ping_hash: [32]u8,
};

/// Discovery v4 protocol handler
pub const UDPv4 = struct {
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    priv_key: [32]u8,
    local_node: Node,
    routing_table: *KademliaTable,
    running: bool,
    bootstrap_state: BootstrapState,
    pending_pings: std.AutoHashMap([32]u8, PendingPing),
    bootnodes: []Node,
    last_lookup: i64,

    const Self = @This();
    const BOND_TIMEOUT = 10; // 10 seconds
    const LOOKUP_INTERVAL = 60; // 60 seconds

    pub fn init(allocator: std.mem.Allocator, bind_addr: std.net.Address, priv_key: [32]u8) !*Self {
        const self = try allocator.create(Self);

        // Create UDP socket
        const socket = try std.posix.socket(
            bind_addr.any.family,
            std.posix.SOCK.DGRAM,
            std.posix.IPPROTO.UDP,
        );
        errdefer std.posix.close(socket);

        // Bind socket
        try std.posix.bind(socket, &bind_addr.any, bind_addr.getOsSockLen());

        // Initialize local node
        const node_id = crypto.keccak256(&priv_key); // Public key hash
        const local_node = Node{
            .id = node_id,
            .ip = bind_addr,
            .udp_port = bind_addr.getPort(),
            .tcp_port = bind_addr.getPort(),
        };

        self.* = .{
            .allocator = allocator,
            .socket = socket,
            .priv_key = priv_key,
            .local_node = local_node,
            .routing_table = try KademliaTable.init(allocator, local_node.id),
            .running = false,
            .bootstrap_state = .idle,
            .pending_pings = std.AutoHashMap([32]u8, PendingPing).init(allocator),
            .bootnodes = &[_]Node{},
            .last_lookup = 0,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.running = false;
        std.posix.close(self.socket);
        self.routing_table.deinit();
        self.pending_pings.deinit();
        self.allocator.destroy(self);
    }

    /// Bootstrap discovery with provided bootnodes
    pub fn bootstrap(self: *Self, bootnodes: []const Node) !void {
        std.log.info("Starting bootstrap with {} bootnodes", .{bootnodes.len});

        self.bootnodes = try self.allocator.dupe(Node, bootnodes);
        self.bootstrap_state = .bonding;

        // Bond with all bootnodes
        for (bootnodes) |node| {
            try self.bond(&node);
        }

        // Wait for bonds to complete (simplified - should use async)
        std.time.sleep(2 * std.time.ns_per_s);

        // Start discovery lookups
        self.bootstrap_state = .discovering;
        try self.performLookups();

        self.bootstrap_state = .completed;
        std.log.info("Bootstrap completed with {} nodes in table", .{self.routing_table.len()});
    }

    /// Bond with a node (ping-pong exchange)
    pub fn bond(self: *Self, node: *const Node) !void {
        const now = std.time.timestamp();

        // Create ping packet
        const ping_packet = Ping{
            .version = PROTOCOL_VERSION,
            .from = .{
                .ip = self.local_node.ip,
                .udp_port = self.local_node.udp_port,
                .tcp_port = self.local_node.tcp_port,
            },
            .to = .{
                .ip = node.ip,
                .udp_port = node.udp_port,
                .tcp_port = node.tcp_port,
            },
            .expiration = @intCast(now + 60),
            .enr_seq = null,
        };

        const payload = try ping_packet.encode(self.allocator);
        defer self.allocator.free(payload);

        const ping_hash = crypto.keccak256(payload);

        // Track pending ping
        try self.pending_pings.put(node.id, .{
            .node_id = node.id,
            .sent_at = now,
            .ping_hash = ping_hash,
        });

        try self.sendPacket(.ping, payload, node.ip);
        std.log.debug("Sent bond ping to node", .{});
    }

    /// Perform discovery lookups to fill routing table
    fn performLookups(self: *Self) !void {
        const now = std.time.timestamp();
        self.last_lookup = now;

        // Lookup our own ID to find nearby nodes
        try self.lookup(self.local_node.id);

        // Lookup random IDs to fill distant buckets
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            var random_id: [32]u8 = undefined;
            try std.crypto.random.bytes(&random_id);
            try self.lookup(random_id);
        }
    }

    /// Perform recursive lookup for a target ID
    pub fn lookup(self: *Self, target: [32]u8) !void {
        std.log.debug("Starting lookup for target", .{});

        // Get closest known nodes
        const closest = try self.routing_table.findClosest(target, 16);
        defer self.allocator.free(closest);

        if (closest.len == 0) {
            // Use bootnodes if table is empty
            for (self.bootnodes) |bootnode| {
                try self.findNode(&bootnode, target);
            }
            return;
        }

        // Query closest nodes
        for (closest) |node| {
            try self.findNode(&node, target);
        }
    }

    /// Refresh buckets that haven't been updated recently
    pub fn refreshBuckets(self: *Self) !void {
        const buckets_to_refresh = try self.routing_table.refreshCandidates();
        defer self.allocator.free(buckets_to_refresh);

        for (buckets_to_refresh) |bucket_idx| {
            // Generate random ID in this bucket's range
            var target: [32]u8 = undefined;
            @memcpy(&target, &self.local_node.id);

            // Flip bit at bucket_idx to target that bucket
            const byte_idx = bucket_idx / 8;
            const bit_idx: u3 = @intCast(bucket_idx % 8);
            target[byte_idx] ^= (@as(u8, 1) << bit_idx);

            try self.lookup(target);
            self.routing_table.markRefreshed(bucket_idx);
        }
    }

    /// Start discovery protocol
    pub fn start(self: *Self) !void {
        self.running = true;

        // Main receive loop
        var buf: [MAX_PACKET_SIZE]u8 = undefined;
        var src_addr: std.net.Address = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        while (self.running) {
            const len = std.posix.recvfrom(
                self.socket,
                &buf,
                0,
                &src_addr.any,
                &addr_len,
            ) catch |err| {
                std.log.err("Discovery receive error: {}", .{err});
                continue;
            };

            if (len > 0) {
                self.handlePacket(buf[0..len], src_addr) catch |err| {
                    std.log.err("Failed to handle packet: {}", .{err});
                };
            }
        }
    }

    /// Send ping to a node
    pub fn ping(self: *Self, node: *const Node) !void {
        const now = std.time.timestamp();
        const ping_packet = Ping{
            .version = PROTOCOL_VERSION,
            .from = .{
                .ip = self.local_node.ip,
                .udp_port = self.local_node.udp_port,
                .tcp_port = self.local_node.tcp_port,
            },
            .to = .{
                .ip = node.ip,
                .udp_port = node.udp_port,
                .tcp_port = node.tcp_port,
            },
            .expiration = @intCast(now + 60), // 60 second expiration
            .enr_seq = null,
        };

        const payload = try ping_packet.encode(self.allocator);
        defer self.allocator.free(payload);

        try self.sendPacket(.ping, payload, node.ip);
    }

    /// Send find_node request
    pub fn findNode(self: *Self, node: *const Node, target: [32]u8) !void {
        const now = std.time.timestamp();
        const find_packet = FindNode{
            .target = target,
            .expiration = @intCast(now + 60),
        };

        const payload = try find_packet.encode(self.allocator);
        defer self.allocator.free(payload);

        try self.sendPacket(.find_node, payload, node.ip);
    }

    /// Send a packet
    fn sendPacket(self: *Self, packet_type: PacketType, payload: []const u8, dest: std.net.Address) !void {
        var packet = std.ArrayList(u8).init(self.allocator);
        defer packet.deinit();

        // Packet format: hash(32) || signature(65) || packet-type(1) || packet-data
        // Build packet data
        try packet.append(@intFromEnum(packet_type));
        try packet.appendSlice(payload);

        // Sign packet
        const hash = crypto.keccak256(packet.items);
        const signature = try crypto.signHash(&self.priv_key, &hash);

        // Build final packet
        var final_packet = std.ArrayList(u8).init(self.allocator);
        defer final_packet.deinit();

        try final_packet.appendSlice(&hash);
        try final_packet.appendSlice(&signature);
        try final_packet.appendSlice(packet.items);

        // Send UDP packet
        _ = try std.posix.sendto(
            self.socket,
            final_packet.items,
            0,
            &dest.any,
            dest.getOsSockLen(),
        );
    }

    /// Handle received packet
    fn handlePacket(self: *Self, data: []const u8, src: std.net.Address) !void {
        if (data.len < 98) return error.PacketTooSmall; // hash(32) + sig(65) + type(1)

        // Extract components
        const hash = data[0..32];
        const signature = data[32..97];
        const packet_type: PacketType = @enumFromInt(data[97]);
        const payload = data[98..];

        // Verify hash
        const computed_hash = crypto.keccak256(data[97..]);
        if (!std.mem.eql(u8, hash, &computed_hash)) {
            return error.InvalidHash;
        }

        // Verify signature and recover sender ID
        const sender_id = try crypto.recoverPublicKey(&computed_hash, signature);
        _ = sender_id; // TODO: Use for authentication

        // Dispatch based on packet type
        switch (packet_type) {
            .ping => try self.handlePing(payload, src),
            .pong => try self.handlePong(payload, src),
            .find_node => try self.handleFindNode(payload, src),
            .neighbors => try self.handleNeighbors(payload, src),
            .enr_request => {}, // TODO
            .enr_response => {}, // TODO
        }
    }

    fn handlePing(self: *Self, payload: []const u8, src: std.net.Address) !void {
        var decoder = rlp.Decoder.init(payload);
        var list_decoder = try decoder.enterList();

        const version = try list_decoder.decodeInt();
        _ = version; // Verify version matches

        // Decode endpoints (simplified)
        _ = try list_decoder.enterList(); // from
        _ = try list_decoder.enterList(); // to
        const expiration = try list_decoder.decodeInt();

        // Check expiration
        const now: u64 = @intCast(std.time.timestamp());
        if (expiration < now) return error.ExpiredPacket;

        // Send pong response
        const pong_packet = Pong{
            .to = .{
                .ip = src,
                .udp_port = src.getPort(),
                .tcp_port = src.getPort(),
            },
            .ping_hash = crypto.keccak256(payload),
            .expiration = @intCast(now + 60),
            .enr_seq = null,
        };

        const pong_payload = try pong_packet.encode(self.allocator);
        defer self.allocator.free(pong_payload);

        try self.sendPacket(.pong, pong_payload, src);
    }

    fn handlePong(self: *Self, payload: []const u8, src: std.net.Address) !void {
        var decoder = rlp.Decoder.init(payload);
        var list_decoder = try decoder.enterList();

        // Decode endpoint
        _ = try list_decoder.enterList(); // to

        // Decode ping hash
        const ping_hash_bytes = try list_decoder.decodeBytesView();
        var ping_hash: [32]u8 = undefined;
        @memcpy(&ping_hash, ping_hash_bytes[0..32]);

        // Verify this matches a pending ping
        var iter = self.pending_pings.iterator();
        while (iter.next()) |entry| {
            const pending = entry.value_ptr.*;
            if (std.mem.eql(u8, &pending.ping_hash, &ping_hash)) {
                // Bond verified - add node to routing table
                const node = Node{
                    .id = pending.node_id,
                    .ip = src,
                    .udp_port = src.getPort(),
                    .tcp_port = src.getPort(),
                };

                try self.routing_table.addNode(node);
                _ = self.pending_pings.remove(pending.node_id);

                std.log.debug("Bond verified, node added to routing table", .{});
                return;
            }
        }

        std.log.warn("Received pong with unknown ping hash", .{});
    }

    fn handleFindNode(self: *Self, payload: []const u8, src: std.net.Address) !void {
        var decoder = rlp.Decoder.init(payload);
        var list_decoder = try decoder.enterList();

        const target_bytes = try list_decoder.decodeBytesView();
        var target: [32]u8 = undefined;
        @memcpy(&target, target_bytes);

        const expiration = try list_decoder.decodeInt();
        const now: u64 = @intCast(std.time.timestamp());
        if (expiration < now) return error.ExpiredPacket;

        // Find closest nodes
        const closest = try self.routing_table.findClosest(target, 16);
        defer self.allocator.free(closest);

        // Send neighbors response
        const neighbors_packet = Neighbors{
            .nodes = closest,
            .expiration = @intCast(now + 60),
        };

        const neighbors_payload = try neighbors_packet.encode(self.allocator);
        defer self.allocator.free(neighbors_payload);

        try self.sendPacket(.neighbors, neighbors_payload, src);
    }

    fn handleNeighbors(self: *Self, payload: []const u8, src: std.net.Address) !void {
        _ = src;

        var decoder = rlp.Decoder.init(payload);
        var list_decoder = try decoder.enterList();

        // Decode nodes list
        var nodes_list = try list_decoder.enterList();

        while (!nodes_list.isEmpty()) {
            var node_list = try nodes_list.enterList();

            // Decode IP
            const ip_bytes = try node_list.decodeBytesView();
            const ip_addr = if (ip_bytes.len == 4) blk: {
                var addr_bytes: [4]u8 = undefined;
                @memcpy(&addr_bytes, ip_bytes[0..4]);
                break :blk try std.net.Address.initIp4(addr_bytes, 0);
            } else blk: {
                var addr_bytes: [16]u8 = undefined;
                @memcpy(&addr_bytes, ip_bytes[0..16]);
                break :blk try std.net.Address.initIp6(addr_bytes, 0, 0, 0);
            };

            const udp_port: u16 = @intCast(try node_list.decodeInt());
            const tcp_port: u16 = @intCast(try node_list.decodeInt());

            const node_id_bytes = try node_list.decodeBytesView();
            var node_id: [32]u8 = undefined;
            @memcpy(&node_id, node_id_bytes[0..32]);

            // Create and add node
            var node_addr = ip_addr;
            node_addr.setPort(udp_port);

            const node = Node{
                .id = node_id,
                .ip = node_addr,
                .udp_port = udp_port,
                .tcp_port = tcp_port,
            };

            try self.routing_table.addNode(node);
            std.log.debug("Added neighbor node to routing table", .{});
        }
    }
};

/// Kademlia routing table
pub const KademliaTable = struct {
    allocator: std.mem.Allocator,
    local_id: [32]u8,
    buckets: [256]Bucket, // 256 buckets for 256-bit node IDs

    const BUCKET_SIZE = 16;

    pub const Bucket = struct {
        nodes: std.ArrayList(Node),
    };

    pub fn init(allocator: std.mem.Allocator, local_id: [32]u8) !*KademliaTable {
        const self = try allocator.create(KademliaTable);
        self.allocator = allocator;
        self.local_id = local_id;

        for (&self.buckets) |*bucket| {
            bucket.* = Bucket{
                .nodes = std.ArrayList(Node).init(allocator),
            };
        }

        return self;
    }

    pub fn deinit(self: *KademliaTable) void {
        for (&self.buckets) |*bucket| {
            bucket.nodes.deinit();
        }
        self.allocator.destroy(self);
    }

    /// Add node to routing table
    pub fn addNode(self: *KademliaTable, node: Node) !void {
        const bucket_idx = self.bucketIndex(&node.id);
        const bucket = &self.buckets[bucket_idx];

        // Check if node already exists
        for (bucket.nodes.items) |existing| {
            if (std.mem.eql(u8, &existing.id, &node.id)) {
                return; // Already have this node
            }
        }

        // Add if bucket not full
        if (bucket.nodes.items.len < BUCKET_SIZE) {
            try bucket.nodes.append(node);
        }
        // TODO: Implement bucket eviction policy
    }

    /// Find closest nodes to target
    pub fn findClosest(self: *KademliaTable, target: [32]u8, count: usize) ![]Node {
        var candidates = std.ArrayList(Node).init(self.allocator);
        defer candidates.deinit();

        // Collect all nodes
        for (self.buckets) |bucket| {
            try candidates.appendSlice(bucket.nodes.items);
        }

        // Sort by distance to target
        const Context = struct {
            target_id: [32]u8,

            pub fn lessThan(ctx: @This(), a: Node, b: Node) bool {
                const dist_a = xorDistance(&ctx.target_id, &a.id);
                const dist_b = xorDistance(&ctx.target_id, &b.id);
                return dist_a < dist_b;
            }
        };

        std.mem.sort(Node, candidates.items, Context{ .target_id = target }, Context.lessThan);

        // Return top N
        const result_count = @min(count, candidates.items.len);
        return self.allocator.dupe(Node, candidates.items[0..result_count]);
    }

    fn bucketIndex(self: *KademliaTable, node_id: *const [32]u8) usize {
        const dist = xorDistance(&self.local_id, node_id);
        // Find first set bit (log distance)
        return @clz(dist);
    }
};

fn xorDistance(a: *const [32]u8, b: *const [32]u8) u256 {
    var result: u256 = 0;
    for (a, 0..) |byte, i| {
        const xor_byte = byte ^ b[i];
        result = (result << 8) | @as(u256, xor_byte);
    }
    return result;
}

/// Packet encoding/decoding functions
/// Based on erigon/p2p/discover/v4wire/v4wire.go

/// Decoded packet with metadata
pub const DecodedPacket = struct {
    packet_type: PacketType,
    from_id: [64]u8, // Public key of sender
    hash: [32]u8,
    data: []u8,

    pub fn deinit(self: *DecodedPacket, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Encode a Discovery v4 packet
/// Packet format: [hash(32) || signature(65) || packet-type(1) || RLP-data]
pub fn encodePacket(
    allocator: std.mem.Allocator,
    priv_key: [32]u8,
    packet_type: PacketType,
    packet_data: []const u8,
) ![]u8 {
    // Build packet: [headspace(97) || type(1) || data]
    var packet = try allocator.alloc(u8, HEAD_SIZE + 1 + packet_data.len);
    errdefer allocator.free(packet);

    // Leave space for hash and signature
    @memset(packet[0..HEAD_SIZE], 0);

    // Write packet type
    packet[HEAD_SIZE] = @intFromEnum(packet_type);

    // Write packet data
    @memcpy(packet[HEAD_SIZE + 1 ..], packet_data);

    // Sign the packet (signature goes over type + data)
    const to_sign = packet[HEAD_SIZE..];
    const msg_hash = crypto.keccak256(to_sign);

    // Generate signature using private key
    // For now, use simplified signature (TODO: proper ECDSA)
    var signature: [65]u8 = undefined;
    @memset(&signature, 0);
    @memcpy(signature[0..32], &msg_hash); // Placeholder

    // Copy signature into packet
    @memcpy(packet[MAC_SIZE .. MAC_SIZE + SIG_SIZE], &signature);

    // Compute hash over signature + type + data
    const hash = crypto.keccak256(packet[MAC_SIZE..]);
    @memcpy(packet[0..MAC_SIZE], &hash);

    return packet;
}

/// Decode a Discovery v4 packet
/// Returns the packet type, sender public key, and packet hash
pub fn decodePacket(
    allocator: std.mem.Allocator,
    packet: []const u8,
) !DecodedPacket {
    if (packet.len < HEAD_SIZE + 1) {
        return DiscoveryError.PacketTooSmall;
    }

    // Extract components
    const hash = packet[0..MAC_SIZE];
    const signature = packet[MAC_SIZE..HEAD_SIZE];
    const packet_type_byte = packet[HEAD_SIZE];
    const data = packet[HEAD_SIZE + 1 ..];

    // Verify hash
    const should_hash = crypto.keccak256(packet[MAC_SIZE..]);
    if (!std.mem.eql(u8, hash, &should_hash)) {
        return DiscoveryError.BadHash;
    }

    // Recover public key from signature
    // TODO: Implement proper signature recovery
    var from_id: [64]u8 = undefined;
    @memset(&from_id, 0); // Placeholder

    // Parse packet type
    const packet_type: PacketType = @enumFromInt(packet_type_byte);

    // Copy data
    const data_copy = try allocator.dupe(u8, data);

    var decoded_hash: [32]u8 = undefined;
    @memcpy(&decoded_hash, hash);

    return DecodedPacket{
        .packet_type = packet_type,
        .from_id = from_id,
        .hash = decoded_hash,
        .data = data_copy,
    };
}

/// Check if a timestamp has expired
pub fn isExpired(timestamp: u64) bool {
    const now = @as(u64, @intCast(std.time.timestamp()));
    return timestamp < now;
}

test "discovery packet encoding" {
    const allocator = std.testing.allocator;

    const endpoint = Endpoint{
        .ip = try std.net.Address.parseIp4("127.0.0.1", 30303),
        .udp_port = 30303,
        .tcp_port = 30303,
    };

    var encoder = rlp.Encoder.init(allocator);
    defer encoder.deinit();

    try endpoint.encode(&encoder);
    const encoded = try encoder.toOwnedSlice();
    defer allocator.free(encoded);

    try std.testing.expect(encoded.len > 0);
}

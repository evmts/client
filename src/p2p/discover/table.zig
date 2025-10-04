//! Kademlia routing table for Node Discovery v4
//! Based on Erigon's p2p/discover/table.go
//!
//! Implements Kademlia DHT routing table with k-buckets for efficient
//! peer discovery and lookup in the Ethereum P2P network.

const std = @import("std");
const crypto = @import("../../crypto.zig");

/// Maximum nodes per bucket (k-parameter in Kademlia)
pub const BUCKET_SIZE = 16;

/// Number of buckets (256 bits = 256 buckets)
pub const BUCKET_COUNT = 256;

/// Bucket replacement cache size
const REPLACEMENT_CACHE_SIZE = 10;

/// Refresh interval for buckets (30 minutes)
const BUCKET_REFRESH_INTERVAL = 30 * 60;

/// Node representation in routing table
pub const Node = struct {
    id: [32]u8, // Keccak256 hash of public key
    ip: std.net.Address,
    udp_port: u16,
    tcp_port: u16,
    last_seen: i64, // Unix timestamp
    add_time: i64, // When added to table
    checks: u32, // Failed ping count
    is_valid: bool,

    pub fn init(id: [32]u8, ip: std.net.Address, udp_port: u16, tcp_port: u16) Node {
        const now = std.time.timestamp();
        return .{
            .id = id,
            .ip = ip,
            .udp_port = udp_port,
            .tcp_port = tcp_port,
            .last_seen = now,
            .add_time = now,
            .checks = 0,
            .is_valid = true,
        };
    }

    pub fn updateLastSeen(self: *Node) void {
        self.last_seen = std.time.timestamp();
        self.checks = 0; // Reset failed checks on successful contact
        self.is_valid = true;
    }

    pub fn markFailed(self: *Node) void {
        self.checks += 1;
        if (self.checks >= 3) {
            self.is_valid = false;
        }
    }
};

/// K-bucket for storing nodes at a specific distance
pub const Bucket = struct {
    entries: std.ArrayList(Node),
    replacements: std.ArrayList(Node), // Replacement cache
    last_refresh: i64,

    pub fn init(allocator: std.mem.Allocator) Bucket {
        return .{
            .entries = std.ArrayList(Node).init(allocator),
            .replacements = std.ArrayList(Node).init(allocator),
            .last_refresh = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *Bucket) void {
        self.entries.deinit();
        self.replacements.deinit();
    }

    /// Add node to bucket, returns true if added
    pub fn addNode(self: *Bucket, node: Node) !bool {
        // Check if node already exists
        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, &entry.id, &node.id)) {
                // Move to end (most recently seen)
                const existing = self.entries.orderedRemove(i);
                var updated = existing;
                updated.updateLastSeen();
                try self.entries.append(updated);
                return true;
            }
        }

        // If bucket not full, add directly
        if (self.entries.items.len < BUCKET_SIZE) {
            try self.entries.append(node);
            return true;
        }

        // Bucket full - add to replacement cache
        return self.addReplacement(node);
    }

    /// Remove node by ID
    pub fn removeNode(self: *Bucket, id: [32]u8) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, &entry.id, &id)) {
                _ = self.entries.orderedRemove(i);
                // Try to replace from cache
                self.replaceFromCache();
                return true;
            }
        }
        return false;
    }

    /// Add to replacement cache
    fn addReplacement(self: *Bucket, node: Node) !bool {
        // Check if already in replacements
        for (self.replacements.items) |entry| {
            if (std.mem.eql(u8, &entry.id, &node.id)) {
                return false;
            }
        }

        // Add to replacements, remove oldest if full
        if (self.replacements.items.len >= REPLACEMENT_CACHE_SIZE) {
            _ = self.replacements.orderedRemove(0);
        }
        try self.replacements.append(node);
        return false;
    }

    /// Replace failed nodes with cached replacements
    fn replaceFromCache(self: *Bucket) void {
        if (self.replacements.items.len == 0) return;

        // Take newest replacement
        const replacement = self.replacements.pop();
        self.entries.append(replacement) catch return;
    }

    /// Mark oldest entry for replacement if needed
    pub fn bump(self: *Bucket, id: [32]u8) void {
        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, &entry.id, &id)) {
                // Move to end (LRU)
                const node = self.entries.orderedRemove(i);
                self.entries.append(node) catch return;
                return;
            }
        }
    }

    /// Check if bucket needs refresh
    pub fn needsRefresh(self: *const Bucket) bool {
        const now = std.time.timestamp();
        return (now - self.last_refresh) > BUCKET_REFRESH_INTERVAL;
    }

    pub fn markRefreshed(self: *Bucket) void {
        self.last_refresh = std.time.timestamp();
    }
};

/// Kademlia routing table
pub const RoutingTable = struct {
    allocator: std.mem.Allocator,
    local_id: [32]u8,
    buckets: [BUCKET_COUNT]Bucket,
    mutex: std.Thread.Mutex,
    node_count: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, local_id: [32]u8) !*Self {
        const self = try allocator.create(Self);

        self.allocator = allocator;
        self.local_id = local_id;
        self.mutex = .{};
        self.node_count = 0;

        // Initialize all buckets
        for (&self.buckets) |*bucket| {
            bucket.* = Bucket.init(allocator);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (&self.buckets) |*bucket| {
            bucket.deinit();
        }
        self.allocator.destroy(self);
    }

    /// Add a node to the routing table
    pub fn addNode(self: *Self, node: Node) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Don't add ourselves
        if (std.mem.eql(u8, &node.id, &self.local_id)) {
            return;
        }

        const bucket_idx = self.bucketIndex(&node.id);
        const bucket = &self.buckets[bucket_idx];

        const added = try bucket.addNode(node);
        if (added) {
            self.node_count += 1;
        }
    }

    /// Remove a node from the routing table
    pub fn removeNode(self: *Self, id: [32]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const bucket_idx = self.bucketIndex(&id);
        if (self.buckets[bucket_idx].removeNode(id)) {
            self.node_count -|= 1;
        }
    }

    /// Find closest nodes to target
    pub fn findClosest(self: *Self, target: [32]u8, count: usize) ![]Node {
        self.mutex.lock();
        defer self.mutex.unlock();

        var candidates = std.ArrayList(NodeWithDistance).init(self.allocator);
        defer candidates.deinit();

        // Collect all valid nodes with their distances
        for (&self.buckets) |*bucket| {
            for (bucket.entries.items) |node| {
                if (!node.is_valid) continue;

                const dist = xorDistance(&target, &node.id);
                try candidates.append(.{
                    .node = node,
                    .distance = dist,
                });
            }
        }

        // Sort by distance
        std.mem.sort(NodeWithDistance, candidates.items, {}, NodeWithDistance.lessThan);

        // Return top N nodes
        const result_count = @min(count, candidates.items.len);
        const result = try self.allocator.alloc(Node, result_count);

        for (candidates.items[0..result_count], 0..) |candidate, i| {
            result[i] = candidate.node;
        }

        return result;
    }

    /// Get nodes in a specific bucket
    pub fn bucketNodes(self: *Self, bucket_idx: usize) ![]Node {
        if (bucket_idx >= BUCKET_COUNT) return error.InvalidBucketIndex;

        self.mutex.lock();
        defer self.mutex.unlock();

        const bucket = &self.buckets[bucket_idx];
        return self.allocator.dupe(Node, bucket.entries.items);
    }

    /// Get random nodes from the table
    pub fn randomNodes(self: *Self, count: usize) ![]Node {
        self.mutex.lock();
        defer self.mutex.unlock();

        var candidates = std.ArrayList(Node).init(self.allocator);
        defer candidates.deinit();

        // Collect all valid nodes
        for (&self.buckets) |*bucket| {
            for (bucket.entries.items) |node| {
                if (node.is_valid) {
                    try candidates.append(node);
                }
            }
        }

        if (candidates.items.len == 0) {
            return &[_]Node{};
        }

        // Shuffle using Fisher-Yates
        var i: usize = candidates.items.len;
        while (i > 1) {
            i -= 1;
            const j = std.crypto.random.intRangeAtMost(usize, 0, i);
            std.mem.swap(Node, &candidates.items[i], &candidates.items[j]);
        }

        // Return first N
        const result_count = @min(count, candidates.items.len);
        return self.allocator.dupe(Node, candidates.items[0..result_count]);
    }

    /// Find nodes that need refresh (bucket-based)
    pub fn refreshCandidates(self: *Self) ![]usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buckets_to_refresh = std.ArrayList(usize).init(self.allocator);

        for (&self.buckets, 0..) |*bucket, i| {
            if (bucket.needsRefresh()) {
                try buckets_to_refresh.append(i);
            }
        }

        return buckets_to_refresh.toOwnedSlice();
    }

    /// Mark bucket as refreshed
    pub fn markRefreshed(self: *Self, bucket_idx: usize) void {
        if (bucket_idx >= BUCKET_COUNT) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.buckets[bucket_idx].markRefreshed();
    }

    /// Get node count
    pub fn len(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.node_count;
    }

    /// Calculate bucket index for a node ID
    fn bucketIndex(self: *Self, id: *const [32]u8) usize {
        const dist = xorDistance(&self.local_id, id);

        // Find position of first differing bit (log2 of distance)
        // This is the bucket number in Kademlia
        return @clz(dist);
    }
};

/// Helper struct for sorting nodes by distance
const NodeWithDistance = struct {
    node: Node,
    distance: u256,

    pub fn lessThan(_: void, a: NodeWithDistance, b: NodeWithDistance) bool {
        return a.distance < b.distance;
    }
};

/// Calculate XOR distance between two node IDs (Kademlia metric)
pub fn xorDistance(a: *const [32]u8, b: *const [32]u8) u256 {
    var result: u256 = 0;

    for (a, 0..) |byte, i| {
        const xor_byte = byte ^ b[i];
        result = (result << 8) | @as(u256, xor_byte);
    }

    return result;
}

/// Calculate log2 distance (bucket number)
pub fn logDistance(a: *const [32]u8, b: *const [32]u8) u8 {
    const dist = xorDistance(a, b);
    if (dist == 0) return 0;
    return @as(u8, @truncate(255 - @clz(dist)));
}

test "routing table initialization" {
    const allocator = std.testing.allocator;

    var local_id: [32]u8 = undefined;
    @memset(&local_id, 0x42);

    const table = try RoutingTable.init(allocator, local_id);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 0), table.len());
}

test "add and find nodes" {
    const allocator = std.testing.allocator;

    var local_id: [32]u8 = undefined;
    @memset(&local_id, 0x00);

    const table = try RoutingTable.init(allocator, local_id);
    defer table.deinit();

    // Add test nodes
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        var node_id: [32]u8 = undefined;
        @memset(&node_id, i);

        const node = Node.init(
            node_id,
            try std.net.Address.parseIp4("127.0.0.1", 30303),
            30303,
            30303,
        );

        try table.addNode(node);
    }

    try std.testing.expectEqual(@as(usize, 10), table.len());

    // Find closest to a target
    var target: [32]u8 = undefined;
    @memset(&target, 0x05);

    const closest = try table.findClosest(target, 5);
    defer allocator.free(closest);

    try std.testing.expect(closest.len <= 5);
}

test "bucket distribution" {
    const allocator = std.testing.allocator;

    var local_id: [32]u8 = undefined;
    @memset(&local_id, 0x00);

    const table = try RoutingTable.init(allocator, local_id);
    defer table.deinit();

    // Add nodes with different distances
    for (0..100) |i| {
        var node_id: [32]u8 = undefined;
        try std.crypto.random.bytes(&node_id);

        const node = Node.init(
            node_id,
            try std.net.Address.parseIp4("127.0.0.1", @intCast(30303 + i)),
            @intCast(30303 + i),
            @intCast(30303 + i),
        );

        try table.addNode(node);
    }

    // Should distribute across buckets
    try std.testing.expect(table.len() > 0);
}

test "xor distance calculation" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;

    @memset(&a, 0x00);
    @memset(&b, 0x00);

    const dist1 = xorDistance(&a, &b);
    try std.testing.expectEqual(@as(u256, 0), dist1);

    @memset(&b, 0xFF);
    const dist2 = xorDistance(&a, &b);
    try std.testing.expect(dist2 > 0);
}

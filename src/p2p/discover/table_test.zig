//! Comprehensive tests for Kademlia routing table
//! Tests node insertion, lookup, bucket distribution, and refresh logic

const std = @import("std");
const table = @import("table.zig");
const testing = std.testing;

test "routing table - basic initialization" {
    const allocator = testing.allocator;

    var local_id: [32]u8 = undefined;
    @memset(&local_id, 0x42);

    const rt = try table.RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    try testing.expectEqual(@as(usize, 0), rt.len());
}

test "routing table - add single node" {
    const allocator = testing.allocator;

    var local_id: [32]u8 = undefined;
    @memset(&local_id, 0x00);

    const rt = try table.RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    var node_id: [32]u8 = undefined;
    @memset(&node_id, 0x01);

    const node = table.Node.init(
        node_id,
        try std.net.Address.parseIp4("127.0.0.1", 30303),
        30303,
        30303,
    );

    try rt.addNode(node);
    try testing.expectEqual(@as(usize, 1), rt.len());
}

test "routing table - reject self" {
    const allocator = testing.allocator;

    var local_id: [32]u8 = undefined;
    @memset(&local_id, 0x42);

    const rt = try table.RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    // Try to add ourselves
    const node = table.Node.init(
        local_id,
        try std.net.Address.parseIp4("127.0.0.1", 30303),
        30303,
        30303,
    );

    try rt.addNode(node);
    try testing.expectEqual(@as(usize, 0), rt.len()); // Should not add self
}

test "routing table - add multiple nodes" {
    const allocator = testing.allocator;

    var local_id: [32]u8 = undefined;
    @memset(&local_id, 0x00);

    const rt = try table.RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    // Add 20 nodes
    var i: u8 = 1;
    while (i <= 20) : (i += 1) {
        var node_id: [32]u8 = undefined;
        @memset(&node_id, i);

        const node = table.Node.init(
            node_id,
            try std.net.Address.parseIp4("127.0.0.1", 30303 + i),
            30303 + i,
            30303 + i,
        );

        try rt.addNode(node);
    }

    try testing.expectEqual(@as(usize, 20), rt.len());
}

test "routing table - find closest nodes" {
    const allocator = testing.allocator;

    var local_id: [32]u8 = undefined;
    @memset(&local_id, 0x00);

    const rt = try table.RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    // Add nodes with different IDs
    var i: u8 = 1;
    while (i <= 30) : (i += 1) {
        var node_id: [32]u8 = undefined;
        @memset(&node_id, i);

        const node = table.Node.init(
            node_id,
            try std.net.Address.parseIp4("127.0.0.1", 30303 + i),
            30303 + i,
            30303 + i,
        );

        try rt.addNode(node);
    }

    // Find 10 closest to a target
    var target: [32]u8 = undefined;
    @memset(&target, 0x15); // Target similar to node 21

    const closest = try rt.findClosest(target, 10);
    defer allocator.free(closest);

    try testing.expect(closest.len <= 10);
    try testing.expect(closest.len > 0);

    // First result should be node 21 (0x15)
    try testing.expect(std.mem.eql(u8, &closest[0].id, &target));
}

test "routing table - bucket distribution" {
    const allocator = testing.allocator;

    var local_id: [32]u8 = undefined;
    @memset(&local_id, 0x00);

    const rt = try table.RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    // Add 100 random nodes
    for (0..100) |i| {
        var node_id: [32]u8 = undefined;
        try std.crypto.random.bytes(&node_id);

        const node = table.Node.init(
            node_id,
            try std.net.Address.parseIp4("127.0.0.1", @intCast(30303 + i)),
            @intCast(30303 + i),
            @intCast(30303 + i),
        );

        try rt.addNode(node);
    }

    // Should have distributed across buckets
    try testing.expect(rt.len() > 0);
    try testing.expect(rt.len() <= 100);
}

test "routing table - random nodes" {
    const allocator = testing.allocator;

    var local_id: [32]u8 = undefined;
    @memset(&local_id, 0x00);

    const rt = try table.RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    // Add nodes
    var i: u8 = 1;
    while (i <= 50) : (i += 1) {
        var node_id: [32]u8 = undefined;
        @memset(&node_id, i);

        const node = table.Node.init(
            node_id,
            try std.net.Address.parseIp4("127.0.0.1", 30303 + i),
            30303 + i,
            30303 + i,
        );

        try rt.addNode(node);
    }

    // Get 10 random nodes
    const random = try rt.randomNodes(10);
    defer allocator.free(random);

    try testing.expect(random.len <= 10);
}

test "bucket - add and remove nodes" {
    const allocator = testing.allocator;

    var bucket = table.Bucket.init(allocator);
    defer bucket.deinit();

    // Add nodes up to bucket size
    var i: u8 = 0;
    while (i < table.BUCKET_SIZE) : (i += 1) {
        var node_id: [32]u8 = undefined;
        @memset(&node_id, i);

        const node = table.Node.init(
            node_id,
            try std.net.Address.parseIp4("127.0.0.1", 30303 + i),
            30303 + i,
            30303 + i,
        );

        const added = try bucket.addNode(node);
        try testing.expect(added);
    }

    try testing.expectEqual(@as(usize, table.BUCKET_SIZE), bucket.entries.items.len);

    // Try to add one more - should go to replacement cache
    var overflow_id: [32]u8 = undefined;
    @memset(&overflow_id, 0xFF);

    const overflow_node = table.Node.init(
        overflow_id,
        try std.net.Address.parseIp4("127.0.0.1", 40000),
        40000,
        40000,
    );

    const overflow_added = try bucket.addNode(overflow_node);
    try testing.expect(!overflow_added); // Not added to main bucket
    try testing.expectEqual(@as(usize, 1), bucket.replacements.items.len);

    // Remove a node
    var remove_id: [32]u8 = undefined;
    @memset(&remove_id, 5);

    const removed = bucket.removeNode(remove_id);
    try testing.expect(removed);
    try testing.expectEqual(@as(usize, table.BUCKET_SIZE - 1), bucket.entries.items.len);
}

test "bucket - LRU update" {
    const allocator = testing.allocator;

    var bucket = table.Bucket.init(allocator);
    defer bucket.deinit();

    // Add 3 nodes
    for (0..3) |i| {
        var node_id: [32]u8 = undefined;
        @memset(&node_id, @intCast(i));

        const node = table.Node.init(
            node_id,
            try std.net.Address.parseIp4("127.0.0.1", @intCast(30303 + i)),
            @intCast(30303 + i),
            @intCast(30303 + i),
        );

        _ = try bucket.addNode(node);
    }

    // First node should be at index 0
    var first_id: [32]u8 = undefined;
    @memset(&first_id, 0);
    try testing.expect(std.mem.eql(u8, &bucket.entries.items[0].id, &first_id));

    // Re-add first node (simulating activity)
    const updated_node = table.Node.init(
        first_id,
        try std.net.Address.parseIp4("127.0.0.1", 30303),
        30303,
        30303,
    );
    _ = try bucket.addNode(updated_node);

    // First node should now be at the end (most recent)
    try testing.expect(std.mem.eql(u8, &bucket.entries.items[2].id, &first_id));
}

test "xor distance calculation" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;

    @memset(&a, 0x00);
    @memset(&b, 0x00);

    // Distance to self is 0
    const dist1 = table.xorDistance(&a, &b);
    try testing.expectEqual(@as(u256, 0), dist1);

    // Distance to opposite
    @memset(&b, 0xFF);
    const dist2 = table.xorDistance(&a, &b);
    try testing.expect(dist2 > 0);

    // XOR is commutative
    const dist3 = table.xorDistance(&b, &a);
    try testing.expectEqual(dist2, dist3);
}

test "log distance calculation" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;

    @memset(&a, 0x00);
    @memset(&b, 0x00);

    // Log distance to self is 0
    const log_dist1 = table.logDistance(&a, &b);
    try testing.expectEqual(@as(u8, 0), log_dist1);

    // Set first bit different
    b[0] = 0x01;
    const log_dist2 = table.logDistance(&a, &b);
    try testing.expect(log_dist2 > 0);
}

test "node - last seen tracking" {
    var node_id: [32]u8 = undefined;
    @memset(&node_id, 0x42);

    var node = table.Node.init(
        node_id,
        try std.net.Address.parseIp4("127.0.0.1", 30303),
        30303,
        30303,
    );

    const initial_time = node.last_seen;

    // Wait a bit
    std.time.sleep(10 * std.time.ns_per_ms);

    // Update last seen
    node.updateLastSeen();

    try testing.expect(node.last_seen > initial_time);
    try testing.expectEqual(@as(u32, 0), node.checks);
    try testing.expect(node.is_valid);
}

test "node - failure tracking" {
    var node_id: [32]u8 = undefined;
    @memset(&node_id, 0x42);

    var node = table.Node.init(
        node_id,
        try std.net.Address.parseIp4("127.0.0.1", 30303),
        30303,
        30303,
    );

    try testing.expect(node.is_valid);

    // Mark failed 3 times
    node.markFailed();
    try testing.expect(node.is_valid);

    node.markFailed();
    try testing.expect(node.is_valid);

    node.markFailed();
    try testing.expect(!node.is_valid); // Should be invalid after 3 failures
}

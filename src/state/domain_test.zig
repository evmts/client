//! Integration tests for Domain system
//! Tests the complete flow: put → getLatest → getAsOf

const std = @import("std");
const testing = std.testing;
const Domain = @import("domain.zig").Domain;
const DomainConfig = @import("domain.zig").DomainConfig;
const kv = @import("../kv/kv.zig");
const memdb = @import("../kv/memdb.zig");

test "domain put and getLatest" {
    const allocator = testing.allocator;

    // Setup in-memory database
    var db = memdb.MemDb.init(allocator);
    defer db.deinit();

    var kv_db = db.database();
    var tx = try kv_db.beginTx(true);
    defer tx.rollback();

    // Create domain
    const config = DomainConfig{
        .name = "test_domain",
        .step_size = 8192,
        .snap_dir = "/tmp/test",
        .with_history = false,
    };

    var domain = try Domain.init(allocator, config);
    defer domain.deinit();

    // Put some values
    const key1 = "account1";
    const value1 = "balance:1000";
    try domain.put(key1, value1, 100, tx);

    const key2 = "account2";
    const value2 = "balance:2000";
    try domain.put(key2, value2, 200, tx);

    // Get latest values
    const result1 = try domain.getLatest(key1, tx);
    try testing.expect(result1.found);
    if (result1.value) |v| {
        defer allocator.free(v);
        try testing.expectEqualStrings(value1, v);
    }

    const result2 = try domain.getLatest(key2, tx);
    try testing.expect(result2.found);
    if (result2.value) |v| {
        defer allocator.free(v);
        try testing.expectEqualStrings(value2, v);
    }

    // Get non-existent key
    const result3 = try domain.getLatest("nonexistent", tx);
    try testing.expect(!result3.found);
}

test "domain put and getAsOf (temporal query)" {
    const allocator = testing.allocator;

    var db = memdb.MemDb.init(allocator);
    defer db.deinit();

    var kv_db = db.database();
    var tx = try kv_db.beginTx(true);
    defer tx.rollback();

    const config = DomainConfig{
        .name = "test_domain",
        .step_size = 100, // Small step for testing
        .snap_dir = "/tmp/test",
        .with_history = true, // Enable history
    };

    var domain = try Domain.init(allocator, config);
    defer domain.deinit();

    // Put value at tx 100
    const key = "account1";
    try domain.put(key, "v1", 100, tx);

    // Update at tx 200
    try domain.put(key, "v2", 200, tx);

    // Update at tx 300
    try domain.put(key, "v3", 300, tx);

    // Query at different points in time
    // At tx 150: should get v1
    if (try domain.getAsOf(key, 150, tx)) |v| {
        defer allocator.free(v);
        try testing.expectEqualStrings("v1", v);
    } else {
        try testing.expect(false); // Should have found value
    }

    // At tx 250: should get v2
    if (try domain.getAsOf(key, 250, tx)) |v| {
        defer allocator.free(v);
        try testing.expectEqualStrings("v2", v);
    } else {
        try testing.expect(false);
    }

    // At tx 350: should get v3
    if (try domain.getAsOf(key, 350, tx)) |v| {
        defer allocator.free(v);
        try testing.expectEqualStrings("v3", v);
    } else {
        try testing.expect(false);
    }

    // At tx 50: should not find (before first write)
    const v_before = try domain.getAsOf(key, 50, tx);
    try testing.expect(v_before == null);
}

test "domain delete and temporal queries" {
    const allocator = testing.allocator;

    var db = memdb.MemDb.init(allocator);
    defer db.deinit();

    var kv_db = db.database();
    var tx = try kv_db.beginTx(true);
    defer tx.rollback();

    const config = DomainConfig{
        .name = "test_domain",
        .step_size = 100,
        .snap_dir = "/tmp/test",
        .with_history = true,
    };

    var domain = try Domain.init(allocator, config);
    defer domain.deinit();

    const key = "account1";

    // Create at tx 100
    try domain.put(key, "exists", 100, tx);

    // Delete at tx 200 (put empty value)
    try domain.delete(key, 200, tx);

    // Query before deletion
    if (try domain.getAsOf(key, 150, tx)) |v| {
        defer allocator.free(v);
        try testing.expectEqualStrings("exists", v);
    } else {
        try testing.expect(false);
    }

    // Query after deletion
    const v_deleted = try domain.getAsOf(key, 250, tx);
    try testing.expect(v_deleted == null); // Should be deleted
}

test "domain multiple keys with history" {
    const allocator = testing.allocator;

    var db = memdb.MemDb.init(allocator);
    defer db.deinit();

    var kv_db = db.database();
    var tx = try kv_db.beginTx(true);
    defer tx.rollback();

    const config = DomainConfig{
        .name = "test_domain",
        .step_size = 1000,
        .snap_dir = "/tmp/test",
        .with_history = true,
    };

    var domain = try Domain.init(allocator, config);
    defer domain.deinit();

    // Simulate transaction processing
    const accounts = [_][]const u8{ "alice", "bob", "charlie" };

    // Block 1 (txNum 100-105)
    try domain.put(accounts[0], "100", 100, tx);
    try domain.put(accounts[1], "200", 101, tx);
    try domain.put(accounts[2], "300", 102, tx);

    // Block 2 (txNum 200-205)
    try domain.put(accounts[0], "150", 200, tx);
    try domain.put(accounts[1], "250", 201, tx);

    // Block 3 (txNum 300-305)
    try domain.put(accounts[0], "200", 300, tx);

    // Query state at block 1
    if (try domain.getAsOf(accounts[0], 150, tx)) |v| {
        defer allocator.free(v);
        try testing.expectEqualStrings("100", v);
    } else {
        try testing.expect(false);
    }

    // Query state at block 2
    if (try domain.getAsOf(accounts[0], 250, tx)) |v| {
        defer allocator.free(v);
        try testing.expectEqualStrings("150", v);
    } else {
        try testing.expect(false);
    }

    // Query latest
    const latest = try domain.getLatest(accounts[0], tx);
    if (latest.value) |v| {
        defer allocator.free(v);
        try testing.expectEqualStrings("200", v);
    } else {
        try testing.expect(false);
    }
}

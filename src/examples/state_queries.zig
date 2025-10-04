//! Example: Temporal State Queries
//!
//! This example demonstrates the Domain system's temporal query capabilities.
//!
//! Usage:
//!   zig build-exe state_queries.zig
//!   ./state_queries

const std = @import("std");
const Domain = @import("../state/domain.zig").Domain;
const DomainConfig = @import("../state/domain.zig").DomainConfig;
const kv = @import("../kv/kv.zig");
const memdb = @import("../kv/memdb.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Temporal State Queries Example ===", .{});

    // Setup in-memory database
    var db = memdb.MemDb.init(allocator);
    defer db.deinit();

    var kv_db = db.database();
    var tx = try kv_db.beginTx(true);
    defer tx.rollback();

    // Create domain for account balances
    std.log.info("\nCreating domain for account balances...", .{});
    const config = DomainConfig{
        .name = "account_balances",
        .step_size = 1000,
        .snap_dir = "/tmp/example",
        .with_history = true, // Enable temporal queries
    };

    var domain = try Domain.init(allocator, config);
    defer domain.deinit();

    // Simulate blockchain history
    std.log.info("\nSimulating blockchain history...", .{});
    std.log.info("", .{});

    // Block 100: Initial state
    std.log.info("Block 100: Alice starts with 1000 ETH", .{});
    try domain.put("alice", "1000.0", 100, tx);
    try domain.put("bob", "500.0", 100, tx);
    try domain.put("charlie", "100.0", 100, tx);

    // Block 200: Alice sends 200 ETH to Bob
    std.log.info("Block 200: Alice sends 200 ETH to Bob", .{});
    try domain.put("alice", "800.0", 200, tx);
    try domain.put("bob", "700.0", 200, tx);

    // Block 300: Bob sends 100 ETH to Charlie
    std.log.info("Block 300: Bob sends 100 ETH to Charlie", .{});
    try domain.put("bob", "600.0", 300, tx);
    try domain.put("charlie", "200.0", 300, tx);

    // Block 400: Alice receives 500 ETH (mining reward)
    std.log.info("Block 400: Alice receives 500 ETH mining reward", .{});
    try domain.put("alice", "1300.0", 400, tx);

    // Block 500: Charlie sends 50 ETH to Alice
    std.log.info("Block 500: Charlie sends 50 ETH to Alice", .{});
    try domain.put("charlie", "150.0", 500, tx);
    try domain.put("alice", "1350.0", 500, tx);

    // Query state at different points in time
    std.log.info("\n=== Temporal Queries ===", .{});
    std.log.info("", .{});

    // Query at block 150 (after block 100, before block 200)
    std.log.info("State at block 150:", .{});
    if (try domain.getAsOf("alice", 150, tx)) |balance| {
        defer allocator.free(balance);
        std.log.info("  Alice: {s} ETH", .{balance});
    }
    if (try domain.getAsOf("bob", 150, tx)) |balance| {
        defer allocator.free(balance);
        std.log.info("  Bob: {s} ETH", .{balance});
    }
    if (try domain.getAsOf("charlie", 150, tx)) |balance| {
        defer allocator.free(balance);
        std.log.info("  Charlie: {s} ETH", .{balance});
    }

    std.log.info("", .{});

    // Query at block 250 (after block 200, before block 300)
    std.log.info("State at block 250:", .{});
    if (try domain.getAsOf("alice", 250, tx)) |balance| {
        defer allocator.free(balance);
        std.log.info("  Alice: {s} ETH (sent 200 to Bob)", .{balance});
    }
    if (try domain.getAsOf("bob", 250, tx)) |balance| {
        defer allocator.free(balance);
        std.log.info("  Bob: {s} ETH (received 200 from Alice)", .{balance});
    }

    std.log.info("", .{});

    // Query at block 350
    std.log.info("State at block 350:", .{});
    if (try domain.getAsOf("bob", 350, tx)) |balance| {
        defer allocator.free(balance);
        std.log.info("  Bob: {s} ETH (sent 100 to Charlie)", .{balance});
    }
    if (try domain.getAsOf("charlie", 350, tx)) |balance| {
        defer allocator.free(balance);
        std.log.info("  Charlie: {s} ETH (received 100 from Bob)", .{balance});
    }

    std.log.info("", .{});

    // Query current state (latest)
    std.log.info("Current state (after block 500):", .{});
    const alice_latest = try domain.getLatest("alice", tx);
    if (alice_latest.value) |balance| {
        defer allocator.free(balance);
        std.log.info("  Alice: {s} ETH", .{balance});
    }

    const bob_latest = try domain.getLatest("bob", tx);
    if (bob_latest.value) |balance| {
        defer allocator.free(balance);
        std.log.info("  Bob: {s} ETH", .{balance});
    }

    const charlie_latest = try domain.getLatest("charlie", tx);
    if (charlie_latest.value) |balance| {
        defer allocator.free(balance);
        std.log.info("  Charlie: {s} ETH", .{balance});
    }

    // Demonstrate time-travel debugging
    std.log.info("\n=== Time-Travel Debugging ===", .{});
    std.log.info("", .{});
    std.log.info("Track Alice's balance over time:", .{});

    const checkpoints = [_]u64{ 100, 200, 300, 400, 500 };
    for (checkpoints) |block_num| {
        if (try domain.getAsOf("alice", block_num, tx)) |balance| {
            defer allocator.free(balance);
            std.log.info("  Block {}: {s} ETH", .{ block_num, balance });
        }
    }

    // Use cases
    std.log.info("\n=== Use Cases ===", .{});
    std.log.info("", .{});
    std.log.info("1. Historical RPC queries:", .{});
    std.log.info("   eth_getBalance(alice, {{blockNumber: 250}})", .{});
    std.log.info("", .{});
    std.log.info("2. State proof generation:", .{});
    std.log.info("   Generate proof that Alice had 800 ETH at block 200", .{});
    std.log.info("", .{});
    std.log.info("3. Time-travel debugging:", .{});
    std.log.info("   Investigate when Charlie's balance changed", .{});
    std.log.info("", .{});
    std.log.info("4. Archive node queries:", .{});
    std.log.info("   Answer 'What was the state at any historical block?'", .{});
    std.log.info("", .{});
    std.log.info("5. Audit and compliance:", .{});
    std.log.info("   Track all historical changes to an account", .{});

    std.log.info("\nExample complete!", .{});
}

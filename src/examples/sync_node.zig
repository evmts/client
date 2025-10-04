//! Example: Basic Sync Node
//!
//! This example shows how to create a simple Ethereum node that syncs from genesis.
//!
//! Usage:
//!   zig build-exe sync_node.zig
//!   ./sync_node

const std = @import("std");
const Node = @import("../node.zig").Node;
const NodeConfig = @import("../node.zig").NodeConfig;

pub fn main() !void {
    // Setup allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Guillotine Ethereum Sync Node Example ===", .{});

    // Configure node
    var config = NodeConfig{
        .data_dir = "./example_data",
        .chain_id = 1, // Mainnet
        .network_id = 1,
        .max_peers = 50,
        .sync_target = 1000, // Sync to block 1000
    };

    std.log.info("Configuration:", .{});
    std.log.info("  Chain ID: {}", .{config.chain_id});
    std.log.info("  Data directory: {s}", .{config.data_dir});
    std.log.info("  Sync target: {} blocks", .{config.sync_target});

    // Initialize node
    std.log.info("\nInitializing node...", .{});
    var node = try Node.init(allocator, config);
    defer node.deinit();

    std.log.info("Node initialized successfully!", .{});

    // Start sync
    std.log.info("\nStarting sync...", .{});
    try node.start();

    // Print final status
    std.log.info("\n=== Sync Complete ===", .{});
    node.printStatus();

    // Query some blocks
    std.log.info("\n=== Sample Queries ===", .{});

    if (node.getLatestBlock()) |latest| {
        std.log.info("Latest block: {}", .{latest});

        // Get a specific block
        if (node.getBlock(100)) |block| {
            std.log.info("Block 100:", .{});
            std.log.info("  Number: {}", .{block.header.number});
            std.log.info("  Timestamp: {}", .{block.header.timestamp});
            std.log.info("  Transactions: {}", .{block.transactions.len});
            std.log.info("  Gas used: {}", .{block.header.gas_used});
            std.log.info("  Gas limit: {}", .{block.header.gas_limit});
        }

        // Get another block
        if (node.getBlock(500)) |block| {
            std.log.info("Block 500:", .{});
            std.log.info("  Number: {}", .{block.header.number});
            std.log.info("  Transactions: {}", .{block.transactions.len});
        }
    }

    std.log.info("\nExample complete!", .{});
}

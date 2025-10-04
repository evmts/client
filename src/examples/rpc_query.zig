//! Example: RPC Query Client
//!
//! This example shows how to query an Ethereum node via RPC.
//!
//! Usage:
//!   zig build-exe rpc_query.zig
//!   ./rpc_query

const std = @import("std");
const Node = @import("../node.zig").Node;
const NodeConfig = @import("../node.zig").NodeConfig;
const rpc = @import("../rpc.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Guillotine RPC Query Example ===", .{});

    // Setup and sync node
    std.log.info("Setting up node...", .{});
    var config = NodeConfig.default();
    config.sync_target = 100;

    var node = try Node.init(allocator, config);
    defer node.deinit();

    try node.start();

    // Initialize RPC server
    std.log.info("\nStarting RPC server on port 8545...", .{});
    var rpc_server = rpc.RpcServer.init(allocator, &node, 8545);

    std.log.info("RPC server ready!", .{});

    // Example RPC queries
    std.log.info("\n=== Example RPC Queries ===", .{});

    // 1. eth_blockNumber
    std.log.info("\n1. eth_blockNumber", .{});
    if (node.getLatestBlock()) |block_num| {
        std.log.info("   Latest block: {}", .{block_num});
        std.log.info("   Hex: 0x{x}", .{block_num});
    }

    // 2. eth_getBlockByNumber
    std.log.info("\n2. eth_getBlockByNumber", .{});
    if (node.getBlock(50)) |block| {
        std.log.info("   Block 50:", .{});
        std.log.info("     Number: {}", .{block.header.number});
        std.log.info("     Hash: {x}", .{std.fmt.fmtSliceHexLower(&block.header.hash())});
        std.log.info("     Parent: {x}", .{std.fmt.fmtSliceHexLower(&block.header.parent_hash)});
        std.log.info("     Timestamp: {}", .{block.header.timestamp});
        std.log.info("     Gas used: {}", .{block.header.gas_used});
        std.log.info("     Transactions: {}", .{block.transactions.len});
    }

    // 3. eth_getBlockByHash
    std.log.info("\n3. eth_getBlockByHash", .{});
    if (node.getBlock(50)) |block| {
        const hash = block.header.hash();
        std.log.info("   Query by hash: {x}", .{std.fmt.fmtSliceHexLower(&hash)});
        // In a real implementation, we'd query by hash
    }

    // 4. eth_chainId
    std.log.info("\n4. eth_chainId", .{});
    std.log.info("   Chain ID: {}", .{node.config.chain_id});

    // 5. eth_syncing
    std.log.info("\n5. eth_syncing", .{});
    const status = node.getSyncStatus();
    std.log.info("   Syncing: {}", .{status.target_block > 0});
    std.log.info("   Current: {}", .{status.current_block});
    std.log.info("   Target: {}", .{status.target_block});

    // Demonstrate curl commands
    std.log.info("\n=== Equivalent curl commands ===", .{});
    std.log.info("", .{});
    std.log.info("# Get latest block number:", .{});
    std.log.info("curl -X POST http://localhost:8545 \\", .{});
    std.log.info("  -H \"Content-Type: application/json\" \\", .{});
    std.log.info("  -d '{{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}}'", .{});
    std.log.info("", .{});
    std.log.info("# Get block by number:", .{});
    std.log.info("curl -X POST http://localhost:8545 \\", .{});
    std.log.info("  -H \"Content-Type: application/json\" \\", .{});
    std.log.info("  -d '{{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"0x32\",false],\"id\":1}}'", .{});
    std.log.info("", .{});
    std.log.info("# Get account balance:", .{});
    std.log.info("curl -X POST http://localhost:8545 \\", .{});
    std.log.info("  -H \"Content-Type: application/json\" \\", .{});
    std.log.info("  -d '{{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"0x...\",\"latest\"],\"id\":1}}'", .{});

    std.log.info("\nRPC server would continue running...", .{});
    std.log.info("(In a real server, this would enter an event loop)", .{});

    _ = rpc_server;
}

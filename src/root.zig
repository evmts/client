//! Ethereum Client Library - Main module exports
const std = @import("std");

// Export all modules
pub const chain = @import("chain.zig");
pub const database = @import("database.zig");
pub const state = @import("state.zig");
pub const sync = @import("sync.zig");
pub const node = @import("node.zig");
pub const p2p = @import("p2p.zig");
pub const rpc = @import("rpc.zig");
pub const rlp = @import("rlp.zig");
pub const crypto = @import("crypto.zig");

// Export KV module
pub const kv = struct {
    pub usingnamespace @import("kv/kv.zig");
    pub const tables = @import("kv/tables.zig");
    pub const memdb = @import("kv/memdb.zig");
};

// Export stages
pub const stages = struct {
    pub const headers = @import("stages/headers.zig");
    pub const bodies = @import("stages/bodies.zig");
    pub const execution = @import("stages/execution.zig");
};

// Re-export common types
pub const Header = chain.Header;
pub const Transaction = chain.Transaction;
pub const Block = chain.Block;
pub const Receipt = chain.Receipt;
pub const U256 = chain.U256;

test {
    // This will run all tests in imported modules
    std.testing.refAllDecls(@This());
}

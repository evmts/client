//! Ethereum Client Library - Main module exports
const std = @import("std");

// Export all modules
pub const chain = @import("chain.zig");
pub const database = @import("database.zig");
pub const state = @import("state.zig");
pub const intra_block_state = @import("intra_block_state.zig");
pub const access_list = @import("access_list.zig");
pub const execution = @import("execution.zig");
pub const sync = @import("sync.zig");
pub const node = @import("node.zig");
pub const p2p = @import("p2p.zig");
pub const rpc = @import("rpc.zig");
pub const rlp = @import("rlp.zig");
pub const crypto = @import("crypto.zig");

// Export common utilities
pub const common_types = @import("common/types.zig");
pub const common_bytes = @import("common/bytes.zig");

// Export trie modules
pub const trie = @import("trie/trie.zig");
pub const merkle_trie = @import("trie/merkle_trie.zig");
pub const commitment = @import("trie/commitment.zig");

// Export KV module
pub const kv = @import("kv/kv.zig");
pub const kv_tables = @import("kv/tables.zig");
pub const kv_memdb = @import("kv/memdb.zig");

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

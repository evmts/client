//! Ethereum JSON-RPC API implementation
//! Based on erigon/rpc
//! Spec: https://ethereum.org/en/developers/docs/apis/json-rpc/

const std = @import("std");
const chain = @import("../chain.zig");
const kv = @import("../kv/kv.zig");
const tables = @import("../kv/tables.zig");

/// RPC API namespace
pub const Namespace = enum {
    eth,
    net,
    web3,
    debug,
    trace,
    txpool,
    admin,
    engine,

    pub fn toString(self: Namespace) []const u8 {
        return @tagName(self);
    }
};

/// Common RPC error codes
pub const RpcError = error{
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
    ServerError,
};

/// Block parameter for RPC calls
pub const BlockParameter = union(enum) {
    number: u64,
    tag: BlockTag,
    hash: [32]u8,

    pub const BlockTag = enum {
        earliest,
        latest,
        pending,
        safe,
        finalized,

        pub fn toString(self: BlockTag) []const u8 {
            return @tagName(self);
        }
    };
};

/// Ethereum API implementation
pub const EthApi = struct {
    allocator: std.mem.Allocator,
    db: kv.Database,
    chain_id: u64,

    pub fn init(allocator: std.mem.Allocator, db: kv.Database, chain_id: u64) EthApi {
        return .{
            .allocator = allocator,
            .db = db,
            .chain_id = chain_id,
        };
    }

    // ========================================
    // Block and Transaction Methods
    // ========================================

    /// eth_blockNumber - Returns the latest block number
    pub fn blockNumber(self: *EthApi) !u64 {
        var tx = try self.db.beginTx(false);
        defer tx.rollback();

        const latest_hash = try tx.get(.HeadBlockHash, "latest") orelse return 0;
        if (latest_hash.len != 32) return 0;

        var hash: [32]u8 = undefined;
        @memcpy(&hash, latest_hash[0..32]);

        const block_num_bytes = try tx.get(.HeaderNumbers, &hash) orelse return 0;
        return try tables.Encoding.decodeBlockNumber(block_num_bytes);
    }

    /// eth_getBlockByNumber - Returns block by number
    pub fn getBlockByNumber(
        self: *EthApi,
        block_param: BlockParameter,
        full_tx: bool,
    ) !?[]const u8 {
        const block_num = try self.resolveBlockNumber(block_param);

        var tx = try self.db.beginTx(false);
        defer tx.rollback();

        const block_key = tables.Encoding.encodeBlockNumber(block_num);

        // Get header
        const header_data = try tx.get(.Headers, &block_key) orelse return null;

        // Get body
        const body_data = try tx.get(.Bodies, &block_key) orelse return null;

        // Import RLP from guillotine primitives
        const rlp = @import("../guillotine/src/primitives/rlp.zig");

        // Decode header RLP
        var header_decoder = rlp.Decoder.init(header_data);
        var header_list = try header_decoder.enterList();

        // Parse header fields
        const parent_hash = try header_list.decodeBytesView();
        const uncle_hash = try header_list.decodeBytesView();
        const coinbase = try header_list.decodeBytesView();
        const state_root = try header_list.decodeBytesView();
        const tx_root = try header_list.decodeBytesView();
        const receipt_root = try header_list.decodeBytesView();
        const bloom = try header_list.decodeBytesView();
        const difficulty = try header_list.decodeInt();
        const number = try header_list.decodeInt();
        const gas_limit = try header_list.decodeInt();
        const gas_used = try header_list.decodeInt();
        const timestamp = try header_list.decodeInt();
        const extra_data = try header_list.decodeBytesView();
        const mix_hash = try header_list.decodeBytesView();
        const nonce_bytes = try header_list.decodeBytesView();

        // Decode body RLP for transactions and uncles
        var body_decoder = rlp.Decoder.init(body_data);
        var body_list = try body_decoder.enterList();
        var txs_list = try body_list.enterList();
        var uncles_list = try body_list.enterList();

        // Count transactions
        var tx_count: usize = 0;
        {
            var temp_list = txs_list;
            while (!temp_list.isEmpty()) {
                _ = try temp_list.decodeBytesView();
                tx_count += 1;
            }
        }

        // Build JSON response
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        const writer = result.writer();

        try writer.writeAll("{");
        try writer.print("\"number\":\"0x{x}\",", .{number});
        try writer.print("\"hash\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(try self.computeBlockHash(header_data))});
        try writer.print("\"parentHash\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(parent_hash)});
        try writer.print("\"nonce\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(nonce_bytes)});
        try writer.print("\"sha3Uncles\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(uncle_hash)});
        try writer.print("\"logsBloom\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(bloom)});
        try writer.print("\"transactionsRoot\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(tx_root)});
        try writer.print("\"stateRoot\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(state_root)});
        try writer.print("\"receiptsRoot\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(receipt_root)});
        try writer.print("\"miner\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(coinbase)});
        try writer.print("\"difficulty\":\"0x{x}\",", .{difficulty});
        try writer.print("\"totalDifficulty\":\"0x{x}\",", .{difficulty}); // Simplified
        try writer.print("\"extraData\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(extra_data)});
        try writer.print("\"size\":\"0x{x}\",", .{header_data.len + body_data.len});
        try writer.print("\"gasLimit\":\"0x{x}\",", .{gas_limit});
        try writer.print("\"gasUsed\":\"0x{x}\",", .{gas_used});
        try writer.print("\"timestamp\":\"0x{x}\",", .{timestamp});
        try writer.print("\"mixHash\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(mix_hash)});

        // Transactions array
        try writer.writeAll("\"transactions\":[");
        if (full_tx) {
            // Full transaction objects
            var tx_index: usize = 0;
            while (!txs_list.isEmpty()) : (tx_index += 1) {
                if (tx_index > 0) try writer.writeAll(",");
                const tx_data = try txs_list.decodeBytesView();
                try self.formatTransaction(writer, tx_data, block_num, tx_index);
            }
        } else {
            // Transaction hashes only
            var tx_index: usize = 0;
            while (!txs_list.isEmpty()) : (tx_index += 1) {
                if (tx_index > 0) try writer.writeAll(",");
                const tx_data = try txs_list.decodeBytesView();
                const tx_hash = try self.computeTxHash(tx_data);
                try writer.print("\"0x{s}\"", .{std.fmt.fmtSliceHexLower(&tx_hash)});
            }
        }
        try writer.writeAll("],");

        // Uncles array
        try writer.writeAll("\"uncles\":[");
        var uncle_index: usize = 0;
        while (!uncles_list.isEmpty()) : (uncle_index += 1) {
            if (uncle_index > 0) try writer.writeAll(",");
            const uncle_data = try uncles_list.decodeBytesView();
            const uncle_hash = try self.computeBlockHash(uncle_data);
            try writer.print("\"0x{s}\"", .{std.fmt.fmtSliceHexLower(&uncle_hash)});
        }
        try writer.writeAll("]");
        try writer.writeAll("}");

        return try result.toOwnedSlice();
    }

    /// eth_getBlockByHash - Returns block by hash
    pub fn getBlockByHash(
        self: *EthApi,
        block_hash: [32]u8,
        full_tx: bool,
    ) !?[]const u8 {
        var tx = try self.db.beginTx(false);
        defer tx.rollback();

        // Get block number from hash
        const block_num_bytes = try tx.get(.HeaderNumbers, &block_hash) orelse return null;
        const block_num = try tables.Encoding.decodeBlockNumber(block_num_bytes);

        return self.getBlockByNumber(.{ .number = block_num }, full_tx);
    }

    /// eth_getTransactionByHash - Returns transaction by hash
    pub fn getTransactionByHash(self: *EthApi, tx_hash: [32]u8) !?[]const u8 {
        var tx = try self.db.beginTx(false);
        defer tx.rollback();

        // Lookup block number
        const block_num_bytes = try tx.get(.TxLookup, &tx_hash) orelse return null;
        const block_num = try tables.Encoding.decodeBlockNumber(block_num_bytes);

        // Get transactions from block
        const block_key = tables.Encoding.encodeBlockNumber(block_num);
        const body_data = try tx.get(.Bodies, &block_key) orelse return null;

        const rlp = @import("../guillotine/src/primitives/rlp.zig");

        // Decode body to find the transaction
        var body_decoder = rlp.Decoder.init(body_data);
        var body_list = try body_decoder.enterList();
        var txs_list = try body_list.enterList();

        // Find the matching transaction
        var tx_index: usize = 0;
        while (!txs_list.isEmpty()) : (tx_index += 1) {
            const tx_data = try txs_list.decodeBytesView();
            const current_hash = try self.computeTxHash(tx_data);

            if (std.mem.eql(u8, &current_hash, &tx_hash)) {
                // Found the transaction, format as JSON
                var result = std.ArrayList(u8).init(self.allocator);
                defer result.deinit();
                const writer = result.writer();

                try self.formatTransaction(writer, tx_data, block_num, tx_index);
                return try result.toOwnedSlice();
            }
        }

        return null;
    }

    /// eth_getTransactionReceipt - Returns transaction receipt
    pub fn getTransactionReceipt(self: *EthApi, tx_hash: [32]u8) !?[]const u8 {
        var tx = try self.db.beginTx(false);
        defer tx.rollback();

        // Lookup block number
        const block_num_bytes = try tx.get(.TxLookup, &tx_hash) orelse return null;
        const block_num = try tables.Encoding.decodeBlockNumber(block_num_bytes);

        // Get block body to find transaction index
        const block_key = tables.Encoding.encodeBlockNumber(block_num);
        const body_data = try tx.get(.Bodies, &block_key) orelse return null;

        const rlp = @import("../guillotine/src/primitives/rlp.zig");

        // Find transaction index
        var body_decoder = rlp.Decoder.init(body_data);
        var body_list = try body_decoder.enterList();
        var txs_list = try body_list.enterList();

        var tx_index: usize = 0;
        var found = false;
        while (!txs_list.isEmpty()) : (tx_index += 1) {
            const tx_data = try txs_list.decodeBytesView();
            const current_hash = try self.computeTxHash(tx_data);
            if (std.mem.eql(u8, &current_hash, &tx_hash)) {
                found = true;
                break;
            }
        }

        if (!found) return null;

        // Get receipts for the block
        const receipts_data = try tx.get(.BlockReceipts, block_num_bytes) orelse return null;

        // Decode receipts
        var receipts_decoder = rlp.Decoder.init(receipts_data);
        var receipts_list = try receipts_decoder.enterList();

        // Skip to the correct receipt
        var i: usize = 0;
        while (i < tx_index and !receipts_list.isEmpty()) : (i += 1) {
            _ = try receipts_list.decodeBytesView();
        }

        if (receipts_list.isEmpty()) return null;

        // Decode the receipt
        const receipt_data = try receipts_list.decodeBytesView();
        var receipt_decoder = rlp.Decoder.init(receipt_data);

        // Check if typed receipt
        const first_byte = receipt_data[0];
        var receipt_list = if (first_byte <= 0x7f) blk: {
            // Typed receipt - skip type byte
            var typed_decoder = rlp.Decoder.init(receipt_data[1..]);
            break :blk try typed_decoder.enterList();
        } else blk: {
            break :blk try receipt_decoder.enterList();
        };

        // Parse receipt fields
        const status = try receipt_list.decodeInt();
        const cumulative_gas = try receipt_list.decodeInt();
        const logs_bloom = try receipt_list.decodeBytesView();
        var logs_list = try receipt_list.enterList();

        // Build JSON response
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        const writer = result.writer();

        try writer.writeAll("{");
        try writer.print("\"transactionHash\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(&tx_hash)});
        try writer.print("\"transactionIndex\":\"0x{x}\",", .{tx_index});
        try writer.print("\"blockNumber\":\"0x{x}\",", .{block_num});
        try writer.print("\"cumulativeGasUsed\":\"0x{x}\",", .{cumulative_gas});
        try writer.print("\"status\":\"0x{x}\",", .{status});
        try writer.print("\"logsBloom\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(logs_bloom)});

        // Logs array
        try writer.writeAll("\"logs\":[");
        var log_index: usize = 0;
        while (!logs_list.isEmpty()) : (log_index += 1) {
            if (log_index > 0) try writer.writeAll(",");
            var log_list = try logs_list.enterList();

            const address = try log_list.decodeBytesView();
            var topics_list = try log_list.enterList();
            const data = try log_list.decodeBytesView();

            try writer.writeAll("{");
            try writer.print("\"address\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(address)});
            try writer.writeAll("\"topics\":[");
            var topic_index: usize = 0;
            while (!topics_list.isEmpty()) : (topic_index += 1) {
                if (topic_index > 0) try writer.writeAll(",");
                const topic = try topics_list.decodeBytesView();
                try writer.print("\"0x{s}\"", .{std.fmt.fmtSliceHexLower(topic)});
            }
            try writer.writeAll("],");
            try writer.print("\"data\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(data)});
            try writer.print("\"logIndex\":\"0x{x}\"", .{log_index});
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
        try writer.writeAll("}");

        return try result.toOwnedSlice();
    }

    // ========================================
    // State Methods
    // ========================================

    /// eth_getBalance - Returns account balance at specified block
    pub fn getBalance(self: *EthApi, address: [20]u8, block_param: BlockParameter) ![]const u8 {
        const block_num = try self.resolveBlockNumber(block_param);

        var tx = try self.db.beginTx(false);
        defer tx.rollback();

        // For historical queries, we'd need to reconstruct state at that block
        // For now, query current state (latest)
        const account_data = try tx.get(.PlainState, &address) orelse {
            return try self.allocator.dupe(u8, "0x0");
        };

        // Decode RLP account and extract balance
        const account = try decodeAccount(account_data);

        // Convert balance bytes to u256 for proper hex formatting
        const balance = bytesToU256(account.balance);

        // Format balance as hex
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        const writer = result.writer();

        try writer.print("0x{x}", .{balance});
        return try result.toOwnedSlice();
    }

    /// eth_getTransactionCount - Returns account nonce
    pub fn getTransactionCount(
        self: *EthApi,
        address: [20]u8,
        block_param: BlockParameter,
    ) !u64 {
        _ = block_param;

        var tx = try self.db.beginTx(false);
        defer tx.rollback();

        const account_data = try tx.get(.PlainState, &address) orelse return 0;

        // Decode RLP account and extract nonce
        const account = try decodeAccount(account_data);
        return account.nonce;
    }

    /// eth_getCode - Returns contract code
    pub fn getCode(
        self: *EthApi,
        address: [20]u8,
        block_param: BlockParameter,
    ) ![]const u8 {
        _ = block_param;

        var tx = try self.db.beginTx(false);
        defer tx.rollback();

        // Get code hash from account
        const account_data = try tx.get(.PlainState, &address) orelse {
            return try self.allocator.dupe(u8, "0x");
        };

        // Decode account to get code hash
        const account = try decodeAccount(account_data);

        // Empty code hash (keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470)
        const empty_code_hash = [_]u8{
            0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c, 0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
            0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b, 0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
        };

        // Check if account has code
        if (account.code_hash.len == 32 and !std.mem.eql(u8, account.code_hash, &empty_code_hash)) {
            // Fetch code from Code table using code hash
            var code_hash: [32]u8 = undefined;
            @memcpy(&code_hash, account.code_hash);
            const code_data = try tx.get(.Code, &code_hash) orelse {
                return try self.allocator.dupe(u8, "0x");
            };

            // Return hex-encoded code
            var result = std.ArrayList(u8).init(self.allocator);
            defer result.deinit();
            const writer = result.writer();

            try writer.print("0x{s}", .{std.fmt.fmtSliceHexLower(code_data)});
            return try result.toOwnedSlice();
        }

        return try self.allocator.dupe(u8, "0x");
    }

    /// eth_getStorageAt - Returns storage value at position
    pub fn getStorageAt(
        self: *EthApi,
        address: [20]u8,
        position: [32]u8,
        block_param: BlockParameter,
    ) ![]const u8 {
        _ = block_param;

        var tx = try self.db.beginTx(false);
        defer tx.rollback();

        // Construct storage key
        const storage_key = tables.Encoding.encodeStorageKey(address, 0, position);
        const value = try tx.get(.PlainState, &storage_key) orelse {
            // Return zero value padded to 32 bytes
            var result = std.ArrayList(u8).init(self.allocator);
            defer result.deinit();
            const writer = result.writer();

            try writer.writeAll("0x");
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                try writer.writeAll("0");
            }
            return try result.toOwnedSlice();
        };

        // Format storage value as hex (pad to 32 bytes)
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        const writer = result.writer();

        try writer.writeAll("0x");
        // Pad with leading zeros if needed
        if (value.len < 32) {
            var i: usize = 0;
            while (i < (32 - value.len) * 2) : (i += 1) {
                try writer.writeAll("0");
            }
        }
        try writer.print("{s}", .{std.fmt.fmtSliceHexLower(value)});
        return try result.toOwnedSlice();
    }

    // ========================================
    // Transaction Methods
    // ========================================

    /// eth_sendRawTransaction - Submits signed transaction
    pub fn sendRawTransaction(self: *EthApi, signed_tx: []const u8) ![]const u8 {
        // Decode and validate the RLP transaction
        const rlp = @import("../guillotine/src/primitives/rlp.zig");

        // Compute transaction hash
        const tx_hash = try self.computeTxHash(signed_tx);

        // Basic validation: ensure transaction can be decoded
        var decoder = rlp.Decoder.init(signed_tx);
        const first_byte = signed_tx[0];

        if (first_byte <= 0x7f) {
            // Typed transaction - decode payload
            var typed_decoder = rlp.Decoder.init(signed_tx[1..]);
            _ = try typed_decoder.enterList();
        } else {
            // Legacy transaction
            _ = try decoder.enterList();
        }

        // In production: Add to transaction pool
        // For now, we just validate and return the hash
        // TODO: Integrate with txpool when available

        return try std.fmt.allocPrint(
            self.allocator,
            "0x{s}",
            .{std.fmt.fmtSliceHexLower(&tx_hash)},
        );
    }

    /// eth_call - Executes call without creating transaction
    pub fn call(self: *EthApi, call_msg: CallMessage, block_param: BlockParameter) ![]const u8 {
        const block_num = try self.resolveBlockNumber(block_param);

        // Get block context for execution
        var tx = try self.db.beginTx(false);
        defer tx.rollback();

        const block_key = tables.Encoding.encodeBlockNumber(block_num);
        const header_data = try tx.get(.Headers, &block_key) orelse return error.BlockNotFound;

        // Decode header for block context
        const rlp = @import("../guillotine/src/primitives/rlp.zig");
        var header_decoder = rlp.Decoder.init(header_data);
        var header_list = try header_decoder.enterList();

        // Skip to relevant fields
        _ = try header_list.decodeBytesView(); // parent_hash
        _ = try header_list.decodeBytesView(); // uncle_hash
        const coinbase_bytes = try header_list.decodeBytesView();
        _ = try header_list.decodeBytesView(); // state_root
        _ = try header_list.decodeBytesView(); // tx_root
        _ = try header_list.decodeBytesView(); // receipt_root
        _ = try header_list.decodeBytesView(); // bloom
        const difficulty = try header_list.decodeInt();
        const number = try header_list.decodeInt();
        const gas_limit = try header_list.decodeInt();
        _ = try header_list.decodeInt(); // gas_used
        const timestamp = try header_list.decodeInt();
        const extra_data = try header_list.decodeBytesView();
        const mix_hash = try header_list.decodeBytesView();
        const nonce_bytes = try header_list.decodeBytesView();

        // Convert coinbase to Address
        var coinbase: [20]u8 = undefined;
        @memcpy(&coinbase, coinbase_bytes[0..20]);

        // Set up block context
        const BlockInfo = @import("../guillotine/src/block/block_info.zig").BlockInfo(.{});
        const block_info = BlockInfo{
            .number = number,
            .timestamp = timestamp,
            .gas_limit = gas_limit,
            .coinbase = .{ .bytes = coinbase },
            .difficulty = difficulty,
            .prevrandao = blk: {
                var prevrandao: [32]u8 = undefined;
                if (mix_hash.len >= 32) {
                    @memcpy(&prevrandao, mix_hash[0..32]);
                } else {
                    @memset(&prevrandao, 0);
                }
                break :blk prevrandao;
            },
            .basefee = 0, // Simplified: would need to calculate from parent
            .blob_basefee = 0, // EIP-4844 - would calculate if needed
            .parent_beacon_block_root = null, // EIP-4788 - would load if needed
        };

        // Create transaction context
        const TransactionContext = @import("../guillotine/src/block/transaction_context.zig").TransactionContext;
        const origin = if (call_msg.from) |f| f else [_]u8{0} ** 20;

        const tx_context = TransactionContext{
            .tx_gas_price = call_msg.gas_price orelse 0,
            .origin = .{ .bytes = origin },
            .blob_hashes = &[_][32]u8{},
        };

        // Initialize guillotine database wrapper
        const GuillotineDb = @import("../guillotine/src/storage/database.zig").Database;
        var guillotine_db = GuillotineDb.init(self.allocator);
        defer guillotine_db.deinit();

        // Load state from our database into guillotine database
        // For the target address, load its account and code
        if (call_msg.to) |to_addr| {
            const account_data = try tx.get(.PlainState, &to_addr);
            if (account_data) |data| {
                const account = try decodeAccount(data);

                // Store account in guillotine db
                const db_account = GuillotineDb.Account{
                    .balance = bytesToU256(account.balance),
                    .nonce = account.nonce,
                    .code_hash = blk: {
                        var hash: [32]u8 = undefined;
                        if (account.code_hash.len >= 32) {
                            @memcpy(&hash, account.code_hash[0..32]);
                        } else {
                            @memset(&hash, 0);
                        }
                        break :blk hash;
                    },
                    .storage_root = [_]u8{0} ** 32,
                };

                try guillotine_db.set_account(to_addr, db_account);

                // Load contract code if it exists
                if (account.code_hash.len == 32) {
                    var code_hash: [32]u8 = undefined;
                    @memcpy(&code_hash, account.code_hash[0..32]);

                    const empty_code_hash = [_]u8{
                        0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c, 0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
                        0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b, 0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
                    };

                    if (!std.mem.eql(u8, &code_hash, &empty_code_hash)) {
                        const code_data = try tx.get(.Code, &code_hash);
                        if (code_data) |code| {
                            try guillotine_db.set_code(&code_hash, code);
                        }
                    }
                }
            }
        }

        // Initialize EVM
        const Evm = @import("../guillotine/src/evm.zig").Evm(.{});
        var evm = try Evm.init(
            self.allocator,
            &guillotine_db,
            block_info,
            tx_context,
            call_msg.gas_price orelse 0,
            .{ .bytes = origin },
        );
        defer evm.deinit();

        // Set up call parameters
        const CallParams = @import("../guillotine/src/frame/call_params.zig").CallParams(.{});
        const call_params = if (call_msg.to) |to_addr|
            CallParams{
                .call = .{
                    .caller = .{ .bytes = origin },
                    .to = .{ .bytes = to_addr },
                    .value = call_msg.value orelse 0,
                    .input = call_msg.data orelse &[_]u8{},
                    .gas = call_msg.gas orelse 30_000_000, // Default 30M gas for calls
                }
            }
        else
            // Contract creation
            CallParams{
                .create = .{
                    .caller = .{ .bytes = origin },
                    .value = call_msg.value orelse 0,
                    .init_code = call_msg.data orelse &[_]u8{},
                    .gas = call_msg.gas orelse 30_000_000,
                }
            };

        // Execute the call
        const result = evm.call(call_params);

        // Format result as hex
        if (result.success and result.output.len > 0) {
            var output = std.ArrayList(u8).init(self.allocator);
            defer output.deinit();
            const writer = output.writer();

            try writer.print("0x{s}", .{std.fmt.fmtSliceHexLower(result.output)});
            return try output.toOwnedSlice();
        } else if (!result.success and result.output.len > 0) {
            // Revert with data
            return error.ExecutionReverted;
        } else {
            return try self.allocator.dupe(u8, "0x");
        }
    }

    /// eth_estimateGas - Estimates gas for transaction
    pub fn estimateGas(self: *EthApi, call_msg: CallMessage) !u64 {
        // Calculate intrinsic gas
        const intrinsic_gas = blk: {
            var gas: u64 = 21000; // Base transaction cost

            // Add cost for calldata
            if (call_msg.data) |data| {
                for (data) |byte| {
                    if (byte == 0) {
                        gas += 4; // Zero byte cost
                    } else {
                        gas += 16; // Non-zero byte cost
                    }
                }
            }

            // Contract creation has higher base cost
            if (call_msg.to == null) {
                gas += 32000; // CREATE cost
            }

            break :blk gas;
        };

        // Binary search for minimum gas
        var lo: u64 = intrinsic_gas;
        var hi: u64 = call_msg.gas orelse 30_000_000; // Use provided gas or cap at 30M

        // If caller provided exact gas, try it first
        if (call_msg.gas) |exact_gas| {
            var test_msg = call_msg;
            test_msg.gas = exact_gas;

            const result = self.call(test_msg, .{ .tag = .latest }) catch |err| {
                if (err == error.ExecutionReverted) {
                    return error.ExecutionReverted;
                }
                // On other errors, fall through to binary search
                lo = intrinsic_gas;
                hi = exact_gas;
            } else {
                // Execution succeeded, this is enough gas
                self.allocator.free(result);
                return exact_gas;
            };
        }

        // Binary search to find minimum gas
        var last_success: ?u64 = null;

        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;

            var test_msg = call_msg;
            test_msg.gas = mid;

            const result = self.call(test_msg, .{ .tag = .latest }) catch |err| {
                if (err == error.ExecutionReverted) {
                    // Execution failed - need more gas
                    lo = mid;
                    continue;
                }
                return err;
            };

            // Execution succeeded
            self.allocator.free(result);
            last_success = mid;
            hi = mid;
        }

        // Return the last successful gas amount, or hi if we never succeeded
        if (last_success) |gas| {
            // Add 15% buffer for safety (same as erigon)
            const buffer = gas / 100 * 15;
            return gas + buffer;
        } else {
            return hi;
        }
    }

    // ========================================
    // Mining Methods
    // ========================================

    /// eth_gasPrice - Returns current gas price
    pub fn gasPrice(self: *EthApi) ![]const u8 {
        // Calculate from recent blocks
        // Based on erigon: sample transactions from recent blocks
        // and return median gas price

        var tx = try self.db.beginTx(false);
        defer tx.rollback();

        const latest_block = try self.blockNumber();

        // Sample last 20 blocks (or fewer if chain is shorter)
        const sample_size = 20;
        const start_block = if (latest_block > sample_size) latest_block - sample_size else 0;

        var total_gas_price: u128 = 0;
        var sample_count: u64 = 0;

        var block_num = start_block;
        while (block_num <= latest_block) : (block_num += 1) {
            const block_key = tables.Encoding.encodeBlockNumber(block_num);
            const body_data = try tx.get(.Bodies, &block_key) orelse continue;

            const rlp = @import("../guillotine/src/primitives/rlp.zig");
            var body_decoder = rlp.Decoder.init(body_data);
            var body_list = try body_decoder.enterList();
            var txs_list = try body_list.enterList();

            // Sample gas prices from transactions
            while (!txs_list.isEmpty()) {
                const tx_data = try txs_list.decodeBytesView();
                var tx_decoder = rlp.Decoder.init(tx_data);

                const first_byte = tx_data[0];
                if (first_byte <= 0x7f) {
                    // Typed transaction - skip for simplified implementation
                    continue;
                } else {
                    // Legacy transaction
                    var tx_list = try tx_decoder.enterList();
                    _ = try tx_list.decodeInt(); // nonce
                    const gas_price_bytes = try tx_list.decodeBytesView();

                    // Convert bytes to u64 (simplified)
                    if (gas_price_bytes.len > 0 and gas_price_bytes.len <= 8) {
                        var gas_price: u64 = 0;
                        for (gas_price_bytes) |byte| {
                            gas_price = (gas_price << 8) | byte;
                        }
                        total_gas_price += gas_price;
                        sample_count += 1;
                    }
                }
            }
        }

        // Calculate average gas price, or use default
        const avg_gas_price = if (sample_count > 0)
            @as(u64, @intCast(total_gas_price / sample_count))
        else
            1000000000; // 1 gwei default

        return try std.fmt.allocPrint(self.allocator, "0x{x}", .{avg_gas_price});
    }

    /// eth_maxPriorityFeePerGas - Returns max priority fee
    pub fn maxPriorityFeePerGas(self: *EthApi) ![]const u8 {
        // For EIP-1559, this is the suggested tip
        // Simplified: return 1 gwei
        return try std.fmt.allocPrint(self.allocator, "0x{x}", .{1000000000});
    }

    /// eth_feeHistory - Returns fee history
    pub fn feeHistory(
        self: *EthApi,
        block_count: u64,
        newest_block: BlockParameter,
        reward_percentiles: []const f64,
    ) ![]const u8 {
        const latest = try self.resolveBlockNumber(newest_block);
        const oldest = if (latest > block_count) latest - block_count + 1 else 0;

        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        const writer = result.writer();

        try writer.writeAll("{");
        try writer.print("\"oldestBlock\":\"0x{x}\",", .{oldest});

        // Base fee per gas array
        try writer.writeAll("\"baseFeePerGas\":[");
        var block_num = oldest;
        while (block_num <= latest) : (block_num += 1) {
            if (block_num > oldest) try writer.writeAll(",");
            try writer.print("\"0x{x}\"", .{1000000000}); // Simplified: 1 gwei
        }
        try writer.writeAll("],");

        // Gas used ratio array
        try writer.writeAll("\"gasUsedRatio\":[");
        block_num = oldest;
        while (block_num < latest) : (block_num += 1) {
            if (block_num > oldest) try writer.writeAll(",");
            try writer.writeAll("0.5"); // Simplified: 50% utilization
        }
        try writer.writeAll("]");

        // Reward array (if percentiles requested)
        if (reward_percentiles.len > 0) {
            try writer.writeAll(",\"reward\":[");
            block_num = oldest;
            while (block_num < latest) : (block_num += 1) {
                if (block_num > oldest) try writer.writeAll(",");
                try writer.writeAll("[");
                for (reward_percentiles, 0..) |_, i| {
                    if (i > 0) try writer.writeAll(",");
                    try writer.print("\"0x{x}\"", .{1000000000}); // Simplified
                }
                try writer.writeAll("]");
            }
            try writer.writeAll("]");
        }

        try writer.writeAll("}");
        return try result.toOwnedSlice();
    }

    // ========================================
    // Filter Methods
    // ========================================

    /// eth_newFilter - Creates new filter
    pub fn newFilter(self: *EthApi, filter_options: FilterOptions) !u64 {
        // In production: Store filter in a filter manager
        // For now, generate a random filter ID
        // Filter should track:
        // - from_block, to_block range
        // - address (contract address to watch)
        // - topics (event topics to match)
        // - last_checked_block (for incremental updates)
        //
        // TODO: Implement filter storage and management

        _ = filter_options;
        _ = self;

        var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
        return prng.random().int(u64);
    }

    /// eth_newBlockFilter - Creates block filter
    pub fn newBlockFilter(self: *EthApi) !u64 {
        // Similar to newFilter but tracks new blocks
        // TODO: Implement block filter storage
        _ = self;

        var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
        return prng.random().int(u64);
    }

    /// eth_getFilterChanges - Returns filter changes
    pub fn getFilterChanges(self: *EthApi, filter_id: u64) ![]const u8 {
        // In production: Retrieve filter by ID and return changes since last check
        // For log filters: scan blocks from last_checked to latest, match logs
        // For block filters: return new block hashes
        // For pending transaction filters: return new pending tx hashes
        //
        // TODO: Implement filter change tracking

        _ = filter_id;
        return try self.allocator.dupe(u8, "[]");
    }

    // ========================================
    // Network Methods
    // ========================================

    /// eth_chainId - Returns chain ID
    pub fn chainId(self: *EthApi) !u64 {
        return self.chain_id;
    }

    /// eth_syncing - Returns sync status
    pub fn syncing(self: *EthApi) !?SyncStatus {
        // Check sync status from database
        // In erigon, this checks SyncStageProgress table
        var tx = try self.db.beginTx(false);
        defer tx.rollback();

        // Get current block and highest known block
        const current_block = try self.blockNumber();

        // In production: Query sync stages to determine actual sync status
        // For now, check if we have recent blocks (simplified)
        const highest_block = current_block; // Simplified

        // If current == highest, we're synced
        if (current_block >= highest_block) {
            return null; // Not syncing
        }

        // Return sync status
        return SyncStatus{
            .starting_block = 0, // Simplified
            .current_block = current_block,
            .highest_block = highest_block,
        };
    }

    // ========================================
    // Helper Methods
    // ========================================

    fn resolveBlockNumber(self: *EthApi, block_param: BlockParameter) !u64 {
        return switch (block_param) {
            .number => |num| num,
            .tag => |tag| switch (tag) {
                .latest, .pending => try self.blockNumber(),
                .earliest => 0,
                .safe, .finalized => try self.blockNumber(), // Simplified
            },
            .hash => |hash| blk: {
                var tx = try self.db.beginTx(false);
                defer tx.rollback();

                const block_num_bytes = try tx.get(.HeaderNumbers, &hash) orelse return 0;
                break :blk try tables.Encoding.decodeBlockNumber(block_num_bytes);
            },
        };
    }

    /// Compute keccak256 hash of block header
    fn computeBlockHash(self: *EthApi, header_data: []const u8) ![32]u8 {
        _ = self;
        const crypto = @import("std").crypto;
        var hash: [32]u8 = undefined;
        crypto.hash.sha3.Keccak256.hash(header_data, &hash, .{});
        return hash;
    }

    /// Compute keccak256 hash of transaction
    fn computeTxHash(self: *EthApi, tx_data: []const u8) ![32]u8 {
        _ = self;
        const crypto = @import("std").crypto;
        var hash: [32]u8 = undefined;
        crypto.hash.sha3.Keccak256.hash(tx_data, &hash, .{});
        return hash;
    }

    /// Format transaction as JSON
    fn formatTransaction(
        self: *EthApi,
        writer: anytype,
        tx_data: []const u8,
        block_num: u64,
        tx_index: usize,
    ) !void {
        const rlp = @import("../guillotine/src/primitives/rlp.zig");
        const tx_hash = try self.computeTxHash(tx_data);

        // Decode transaction based on type
        var decoder = rlp.Decoder.init(tx_data);

        try writer.writeAll("{");
        try writer.print("\"hash\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(&tx_hash)});
        try writer.print("\"blockNumber\":\"0x{x}\",", .{block_num});
        try writer.print("\"transactionIndex\":\"0x{x}\",", .{tx_index});

        // Check if typed transaction (EIP-2718)
        const first_byte = tx_data[0];
        if (first_byte <= 0x7f) {
            // Typed transaction
            const tx_type = first_byte;
            try writer.print("\"type\":\"0x{x}\",", .{tx_type});

            // Decode based on type
            var typed_decoder = rlp.Decoder.init(tx_data[1..]);
            var tx_list = try typed_decoder.enterList();

            switch (tx_type) {
                0x01 => { // EIP-2930 (Access List)
                    const chain_id = try tx_list.decodeInt();
                    const nonce = try tx_list.decodeInt();
                    const gas_price = try tx_list.decodeBytesView();
                    const gas_limit = try tx_list.decodeInt();
                    const to = try tx_list.decodeBytesView();
                    const value = try tx_list.decodeBytesView();
                    const data = try tx_list.decodeBytesView();

                    try writer.print("\"chainId\":\"0x{x}\",", .{chain_id});
                    try writer.print("\"nonce\":\"0x{x}\",", .{nonce});
                    try writer.print("\"gasPrice\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(gas_price)});
                    try writer.print("\"gas\":\"0x{x}\",", .{gas_limit});
                    if (to.len > 0) {
                        try writer.print("\"to\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(to)});
                    } else {
                        try writer.writeAll("\"to\":null,");
                    }
                    try writer.print("\"value\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(value)});
                    try writer.print("\"input\":\"0x{s}\"", .{std.fmt.fmtSliceHexLower(data)});
                },
                0x02 => { // EIP-1559 (Dynamic Fee)
                    const chain_id = try tx_list.decodeInt();
                    const nonce = try tx_list.decodeInt();
                    const max_priority_fee = try tx_list.decodeBytesView();
                    const max_fee = try tx_list.decodeBytesView();
                    const gas_limit = try tx_list.decodeInt();
                    const to = try tx_list.decodeBytesView();
                    const value = try tx_list.decodeBytesView();
                    const data = try tx_list.decodeBytesView();

                    try writer.print("\"chainId\":\"0x{x}\",", .{chain_id});
                    try writer.print("\"nonce\":\"0x{x}\",", .{nonce});
                    try writer.print("\"maxPriorityFeePerGas\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(max_priority_fee)});
                    try writer.print("\"maxFeePerGas\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(max_fee)});
                    try writer.print("\"gas\":\"0x{x}\",", .{gas_limit});
                    if (to.len > 0) {
                        try writer.print("\"to\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(to)});
                    } else {
                        try writer.writeAll("\"to\":null,");
                    }
                    try writer.print("\"value\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(value)});
                    try writer.print("\"input\":\"0x{s}\"", .{std.fmt.fmtSliceHexLower(data)});
                },
                else => {
                    // Unknown type, basic decoding
                    try writer.writeAll("\"nonce\":\"0x0\",\"gas\":\"0x0\",\"input\":\"0x\"");
                },
            }
        } else {
            // Legacy transaction
            try writer.writeAll("\"type\":\"0x0\",");
            var tx_list = try decoder.enterList();

            const nonce = try tx_list.decodeInt();
            const gas_price = try tx_list.decodeBytesView();
            const gas_limit = try tx_list.decodeInt();
            const to = try tx_list.decodeBytesView();
            const value = try tx_list.decodeBytesView();
            const data = try tx_list.decodeBytesView();

            try writer.print("\"nonce\":\"0x{x}\",", .{nonce});
            try writer.print("\"gasPrice\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(gas_price)});
            try writer.print("\"gas\":\"0x{x}\",", .{gas_limit});
            if (to.len > 0) {
                try writer.print("\"to\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(to)});
            } else {
                try writer.writeAll("\"to\":null,");
            }
            try writer.print("\"value\":\"0x{s}\",", .{std.fmt.fmtSliceHexLower(value)});
            try writer.print("\"input\":\"0x{s}\"", .{std.fmt.fmtSliceHexLower(data)});
        }

        try writer.writeAll("}");
    }

    /// Decode account from RLP-encoded state data
    fn decodeAccount(data: []const u8) !struct { nonce: u64, balance: []const u8, code_hash: []const u8 } {
        const rlp = @import("../guillotine/src/primitives/rlp.zig");
        var decoder = rlp.Decoder.init(data);
        var account_list = try decoder.enterList();

        const nonce = try account_list.decodeInt();
        const balance = try account_list.decodeBytesView();
        const storage_root = try account_list.decodeBytesView();
        _ = storage_root; // We don't need this for balance/nonce
        const code_hash = try account_list.decodeBytesView();

        return .{
            .nonce = nonce,
            .balance = balance,
            .code_hash = code_hash,
        };
    }

    /// Convert bytes to u256 (big-endian)
    fn bytesToU256(bytes: []const u8) u256 {
        var result: u256 = 0;
        for (bytes) |byte| {
            result = (result << 8) | byte;
        }
        return result;
    }
};

/// Call message for eth_call
pub const CallMessage = struct {
    from: ?[20]u8,
    to: ?[20]u8,
    gas: ?u64,
    gas_price: ?u256,
    value: ?u256,
    data: ?[]const u8,
};

/// Filter options
pub const FilterOptions = struct {
    from_block: ?BlockParameter,
    to_block: ?BlockParameter,
    address: ?[20]u8,
    topics: ?[]const ?[32]u8,
};

/// Sync status
pub const SyncStatus = struct {
    starting_block: u64,
    current_block: u64,
    highest_block: u64,
};

test "eth api initialization" {
    const memdb = @import("../kv/memdb.zig");
    const db_impl = try memdb.MemDb.init(std.testing.allocator);
    defer db_impl.deinit();

    var api = EthApi.init(std.testing.allocator, db_impl.asDatabase(), 1);
    const chain_id = try api.chainId();
    try std.testing.expectEqual(@as(u64, 1), chain_id);
}

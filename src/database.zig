//! Simplified database layer for blockchain storage
//! In production, this would use MDBX, but for simplicity we use an in-memory HashMap

const std = @import("std");
const chain = @import("chain.zig");

pub const DatabaseError = error{
    NotFound,
    AlreadyExists,
    CorruptedData,
    OutOfMemory,
};

/// Database table types
pub const Table = enum {
    headers,
    bodies,
    receipts,
    state,
    code,
    sync_progress,
};

/// Stage progress tracking
pub const Stage = enum {
    headers,
    bodies,
    senders,
    execution,
    finish,

    pub fn toString(self: Stage) []const u8 {
        return switch (self) {
            .headers => "Headers",
            .bodies => "Bodies",
            .senders => "Senders",
            .execution => "Execution",
            .finish => "Finish",
        };
    }
};

/// Simple in-memory database
/// Production would use MDBX with proper transactions
pub const Database = struct {
    allocator: std.mem.Allocator,
    headers: std.AutoHashMap(u64, chain.Header),
    bodies: std.AutoHashMap(u64, BlockBody),
    receipts: std.AutoHashMap(u64, []chain.Receipt),
    state: std.AutoHashMap([20]u8, Account),
    code: std.AutoHashMap([32]u8, []u8),
    stage_progress: std.AutoHashMap(Stage, u64),

    pub fn init(allocator: std.mem.Allocator) Database {
        return .{
            .allocator = allocator,
            .headers = std.AutoHashMap(u64, chain.Header).init(allocator),
            .bodies = std.AutoHashMap(u64, BlockBody).init(allocator),
            .receipts = std.AutoHashMap(u64, []chain.Receipt).init(allocator),
            .state = std.AutoHashMap([20]u8, Account).init(allocator),
            .code = std.AutoHashMap([32]u8, []u8).init(allocator),
            .stage_progress = std.AutoHashMap(Stage, u64).init(allocator),
        };
    }

    pub fn deinit(self: *Database) void {
        self.headers.deinit();

        // Free body data
        var body_iter = self.bodies.valueIterator();
        while (body_iter.next()) |body| {
            body.deinit(self.allocator);
        }
        self.bodies.deinit();

        // Free receipts
        var receipts_iter = self.receipts.valueIterator();
        while (receipts_iter.next()) |receipts| {
            for (receipts.*) |*receipt| {
                receipt.deinit(self.allocator);
            }
            self.allocator.free(receipts.*);
        }
        self.receipts.deinit();

        // Free state
        self.state.deinit();

        // Free code
        var code_iter = self.code.valueIterator();
        while (code_iter.next()) |code| {
            self.allocator.free(code.*);
        }
        self.code.deinit();

        self.stage_progress.deinit();
    }

    // Header operations
    pub fn putHeader(self: *Database, number: u64, header: chain.Header) !void {
        try self.headers.put(number, header);
    }

    pub fn getHeader(self: *Database, number: u64) ?chain.Header {
        return self.headers.get(number);
    }

    pub fn getLatestHeader(self: *Database) ?chain.Header {
        var max_number: u64 = 0;
        var iter = self.headers.keyIterator();
        while (iter.next()) |key| {
            if (key.* > max_number) max_number = key.*;
        }
        if (max_number == 0 and self.headers.count() == 0) return null;
        return self.headers.get(max_number);
    }

    // Body operations
    pub fn putBody(self: *Database, number: u64, body: BlockBody) !void {
        try self.bodies.put(number, body);
    }

    pub fn getBody(self: *Database, number: u64) ?BlockBody {
        return self.bodies.get(number);
    }

    // Receipt operations
    pub fn putReceipts(self: *Database, number: u64, receipts: []chain.Receipt) !void {
        try self.receipts.put(number, receipts);
    }

    pub fn getReceipts(self: *Database, number: u64) ?[]chain.Receipt {
        return self.receipts.get(number);
    }

    // State operations
    pub fn getAccount(self: *Database, address: [20]u8) ?Account {
        return self.state.get(address);
    }

    pub fn putAccount(self: *Database, address: [20]u8, account: Account) !void {
        try self.state.put(address, account);
    }

    pub fn getCode(self: *Database, code_hash: [32]u8) ?[]u8 {
        return self.code.get(code_hash);
    }

    pub fn putCode(self: *Database, code_hash: [32]u8, code_bytes: []u8) !void {
        try self.code.put(code_hash, code_bytes);
    }

    // Stage progress tracking
    pub fn getStageProgress(self: *Database, stage: Stage) u64 {
        return self.stage_progress.get(stage) orelse 0;
    }

    pub fn setStageProgress(self: *Database, stage: Stage, progress: u64) !void {
        try self.stage_progress.put(stage, progress);
    }

    // Transaction support (simplified - no ACID in this version)
    pub fn beginTx(self: *Database) Transaction {
        return Transaction{ .db = self };
    }
};

/// Block body (transactions without header)
pub const BlockBody = struct {
    transactions: []chain.Transaction,
    uncles: []chain.Header,

    pub fn deinit(self: *BlockBody, allocator: std.mem.Allocator) void {
        allocator.free(self.transactions);
        allocator.free(self.uncles);
    }
};

/// Account state
pub const Account = struct {
    nonce: u64,
    balance: [32]u8, // U256 as bytes
    storage_root: [32]u8,
    code_hash: [32]u8,

    pub fn empty() Account {
        return .{
            .nonce = 0,
            .balance = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
            .code_hash = [_]u8{0} ** 32,
        };
    }
};

/// Simplified transaction (no ACID guarantees in this minimal version)
pub const Transaction = struct {
    db: *Database,

    pub fn commit(self: *Transaction) void {
        _ = self;
        // In production: flush to disk, release locks
    }

    pub fn rollback(self: *Transaction) void {
        _ = self;
        // In production: discard changes, release locks
    }
};

test "database header operations" {
    const primitives = @import("primitives");
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    const header = chain.Header{
        .parent_hash = [_]u8{0} ** 32,
        .uncle_hash = [_]u8{0} ** 32,
        .coinbase = primitives.Address.zero(),
        .state_root = [_]u8{0} ** 32,
        .transactions_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = primitives.U256.zero(),
        .number = 1,
        .gas_limit = 30000000,
        .gas_used = 0,
        .timestamp = 1234567890,
        .extra_data = &[_]u8{},
        .mix_hash = [_]u8{0} ** 32,
        .nonce = 0,
        .base_fee_per_gas = null,
        .withdrawals_root = null,
    };

    try db.putHeader(1, header);
    const retrieved = db.getHeader(1);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u64, 1), retrieved.?.number);
}

test "database stage progress" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    try std.testing.expectEqual(@as(u64, 0), db.getStageProgress(.headers));
    try db.setStageProgress(.headers, 100);
    try std.testing.expectEqual(@as(u64, 100), db.getStageProgress(.headers));
}

test "database account operations" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    const addr = [_]u8{1} ++ [_]u8{0} ** 19;
    var account = Account.empty();
    account.nonce = 5;

    try db.putAccount(addr, account);
    const retrieved = db.getAccount(addr);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u64, 5), retrieved.?.nonce);
}

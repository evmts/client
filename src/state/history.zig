//! History - tracks value changes over time for temporal queries
//!
//! Architecture:
//! - Stores historical values per transaction number
//! - Uses InvertedIndex for efficient temporal lookups
//! - Change sets enable "time-travel" queries
//!
//! File Types:
//! - .v  - compressed historical values
//! - .vi - value index (txNum+key → offset in .v)
//!
//! Based on: erigon/db/state/history.go (1,419 lines)
//! Zig version: ~300 lines (4.7x compression)

const std = @import("std");
const kv = @import("../kv/kv.zig");
const tables = @import("../kv/tables.zig");
const InvertedIndex = @import("inverted_index.zig").InvertedIndex;

/// History configuration
pub const HistoryConfig = struct {
    name: []const u8,
    step_size: u64,
    /// Enable inverted index
    with_index: bool = true,
    /// Directory for history files
    snap_dir: []const u8,
};

/// History - tracks all value changes for a domain
pub const History = struct {
    allocator: std.mem.Allocator,
    step_size: u64,
    inverted_index: ?*InvertedIndex,

    /// Files containing historical values
    files: std.ArrayList(HistoryFile),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, step_size: u64) !Self {
        return Self{
            .allocator = allocator,
            .step_size = step_size,
            .inverted_index = null,
            .files = std.ArrayList(HistoryFile).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.inverted_index) |idx| {
            idx.deinit();
            self.allocator.destroy(idx);
        }
        for (self.files.items) |*file| {
            file.deinit();
        }
        self.files.deinit();
    }

    /// Track a value change at specific transaction number
    ///
    /// Algorithm (from history.go):
    /// 1. Write to keys table: txNum → key
    /// 2. Write to values table: key+txNum → value
    /// 3. Update inverted index: key → list of txNums
    pub fn trackChange(self: *Self, key: []const u8, value: []const u8, tx_num: u64, db_tx: *kv.Transaction) !void {
        // Format for keys table: txNum (8 bytes, big-endian) → key
        var tx_num_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &tx_num_buf, tx_num, .big);

        // Write to history keys table
        try db_tx.put(.AccountsHistory, &tx_num_buf, key);

        // Format for values table: key ++ txNum (8 bytes) → value
        var key_tx_buf = try self.allocator.alloc(u8, key.len + 8);
        defer self.allocator.free(key_tx_buf);

        @memcpy(key_tx_buf[0..key.len], key);
        std.mem.writeInt(u64, key_tx_buf[key.len..][0..8], tx_num, .big);

        // Write to history values table
        // Use inverted txNum for sorting (most recent first)
        const inverted_tx_num = ~tx_num;
        var inv_tx_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &inv_tx_buf, inverted_tx_num, .big);

        var value_buf = try self.allocator.alloc(u8, 8 + value.len);
        defer self.allocator.free(value_buf);

        @memcpy(value_buf[0..8], &inv_tx_buf);
        @memcpy(value_buf[8..], value);

        try db_tx.put(.AccountsHistory, key_tx_buf, value_buf);

        // Update inverted index if enabled
        if (self.inverted_index) |idx| {
            try idx.add(key, tx_num, db_tx);
        }
    }

    /// Seek value for key at or before given transaction number
    /// Returns the value that was active at tx_num
    ///
    /// Algorithm (from history.go HistorySeek):
    /// 1. Use inverted index to find txNums where key changed
    /// 2. Binary search for largest txNum <= target
    /// 3. Read value from .v file or DB
    pub fn seekValue(self: *Self, key: []const u8, tx_num: u64, db_tx: *kv.Transaction) !?[]const u8 {
        // First try inverted index to find relevant transaction numbers
        if (self.inverted_index) |idx| {
            const tx_nums = try idx.seek(key, tx_num, db_tx);
            defer self.allocator.free(tx_nums);

            if (tx_nums.len > 0) {
                // Find the most recent txNum <= our target
                const target_tx = self.findMostRecentTx(tx_nums, tx_num);
                if (target_tx) |tx| {
                    return try self.getValue(key, tx, db_tx);
                }
            }
        }

        // Fallback: scan history table directly
        return try self.scanHistory(key, tx_num, db_tx);
    }

    /// Get value for key at specific transaction number
    fn getValue(self: *Self, key: []const u8, tx_num: u64, db_tx: *kv.Transaction) !?[]const u8 {
        // Format: key ++ txNum
        var key_tx_buf = try self.allocator.alloc(u8, key.len + 8);
        defer self.allocator.free(key_tx_buf);

        @memcpy(key_tx_buf[0..key.len], key);
        std.mem.writeInt(u64, key_tx_buf[key.len..][0..8], tx_num, .big);

        // Get from history table
        if (try db_tx.get(.AccountsHistory, key_tx_buf)) |value_with_step| {
            // Value format: inverted_step (8 bytes) ++ actual_value
            if (value_with_step.len < 8) {
                return null;
            }
            return try self.allocator.dupe(u8, value_with_step[8..]);
        }

        return null;
    }

    /// Find most recent transaction number <= target
    fn findMostRecentTx(self: *Self, tx_nums: []const u64, target: u64) ?u64 {
        _ = self;
        var result: ?u64 = null;

        for (tx_nums) |tx| {
            if (tx <= target) {
                if (result) |r| {
                    if (tx > r) {
                        result = tx;
                    }
                } else {
                    result = tx;
                }
            }
        }

        return result;
    }

    /// Scan history table to find value
    /// Slower fallback when index not available
    fn scanHistory(self: *Self, key: []const u8, tx_num: u64, db_tx: *kv.Transaction) !?[]const u8 {
        var cursor = try db_tx.cursor(.AccountsHistory);
        defer cursor.close();

        // Build seek key: key ++ txNum
        var seek_key = try self.allocator.alloc(u8, key.len + 8);
        defer self.allocator.free(seek_key);

        @memcpy(seek_key[0..key.len], key);
        std.mem.writeInt(u64, seek_key[key.len..][0..8], tx_num, .big);

        // Seek to position
        if (try cursor.seek(seek_key)) |entry| {
            // Check if key matches
            if (entry.key.len >= key.len and
                std.mem.eql(u8, entry.key[0..key.len], key))
            {
                // Extract value (skip inverted step)
                if (entry.value.len < 8) {
                    return null;
                }
                return try self.allocator.dupe(u8, entry.value[8..]);
            }
        }

        // Try previous entry (seek may land after target)
        if (try cursor.prev()) |entry| {
            if (entry.key.len >= key.len and
                std.mem.eql(u8, entry.key[0..key.len], key))
            {
                if (entry.value.len < 8) {
                    return null;
                }
                return try self.allocator.dupe(u8, entry.value[8..]);
            }
        }

        return null;
    }

    /// Build history files from database
    pub fn buildFiles(self: *Self, from_step: u64, to_step: u64, db_tx: *kv.Transaction) !void {
        _ = self;
        _ = from_step;
        _ = to_step;
        _ = db_tx;
        // TODO: Implement file building
        // 1. Collect all changes in step range
        // 2. Compress to .v file
        // 3. Build .vi index
    }

    /// Merge history files
    pub fn mergeFiles(self: *Self, files: []HistoryFile) !HistoryFile {
        _ = self;
        _ = files;
        // TODO: Implement merging
        return undefined;
    }
};

/// History file on disk
pub const HistoryFile = struct {
    from_step: u64,
    to_step: u64,

    /// Path to .v file (compressed values)
    v_path: []const u8,

    /// Path to .vi file (value index)
    vi_path: ?[]const u8 = null,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, from: u64, to: u64, base_path: []const u8) !HistoryFile {
        const v_path = try std.fmt.allocPrint(allocator, "{s}.{d}-{d}.v", .{ base_path, from, to });
        return HistoryFile{
            .allocator = allocator,
            .from_step = from,
            .to_step = to,
            .v_path = v_path,
        };
    }

    pub fn deinit(self: *HistoryFile) void {
        self.allocator.free(self.v_path);
        if (self.vi_path) |p| self.allocator.free(p);
    }

    /// Get value for key at transaction number from this file
    pub fn get(self: *HistoryFile, key: []const u8, tx_num: u64) !?[]const u8 {
        _ = self;
        _ = key;
        _ = tx_num;
        // TODO: Implement file reading
        return null;
    }
};

// ============ Tests ============

test "history init/deinit" {
    const allocator = std.testing.allocator;

    var history = try History.init(allocator, 8192);
    defer history.deinit();

    try std.testing.expectEqual(@as(u64, 8192), history.step_size);
}

test "history file path generation" {
    const allocator = std.testing.allocator;

    var file = try HistoryFile.init(allocator, 0, 8192, "v1-accounts");
    defer file.deinit();

    try std.testing.expect(std.mem.indexOf(u8, file.v_path, "0-8192.v") != null);
}

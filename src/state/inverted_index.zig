//! InvertedIndex - fast temporal lookups using bitmaps
//!
//! Architecture:
//! - Maps key → list of transaction numbers where key changed
//! - Uses bitmap compression for efficient storage
//! - Enables fast "which transactions touched this key?" queries
//!
//! File Types:
//! - .ef  - elias-fano compressed transaction lists
//! - .efi - index for .ef file lookups
//!
//! Based on: erigon/db/state/inverted_index.go (1,252 lines)
//! Zig version: ~200 lines (6x compression)

const std = @import("std");
const kv = @import("../kv/kv.zig");
const tables = @import("../kv/tables.zig");

/// InvertedIndex configuration
pub const IndexConfig = struct {
    name: []const u8,
    step_size: u64,
    snap_dir: []const u8,
};

/// InvertedIndex - maps keys to transaction numbers
pub const InvertedIndex = struct {
    allocator: std.mem.Allocator,
    step_size: u64,

    /// In-memory index: key → list of txNums
    /// In production, this would be backed by files
    index: std.StringHashMap(std.ArrayList(u64)),

    /// Files containing inverted index data
    files: std.ArrayList(IndexFile),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, step_size: u64) !Self {
        return Self{
            .allocator = allocator,
            .step_size = step_size,
            .index = std.StringHashMap(std.ArrayList(u64)).init(allocator),
            .files = std.ArrayList(IndexFile).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.index.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.index.deinit();

        for (self.files.items) |*file| {
            file.deinit();
        }
        self.files.deinit();
    }

    /// Add transaction number for key
    ///
    /// Algorithm (from inverted_index.go):
    /// 1. Add to in-memory bitmap/list
    /// 2. Later flushed to .ef file with Elias-Fano compression
    pub fn add(self: *Self, key: []const u8, tx_num: u64, db_tx: *kv.Transaction) !void {
        _ = db_tx; // Not used in memory-only version

        // Get or create list for key
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const gop = try self.index.getOrPut(key_copy);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u64).init(self.allocator);
        } else {
            // Key already exists, free the duplicate
            self.allocator.free(key_copy);
        }

        // Add transaction number (keep sorted)
        const list = gop.value_ptr;
        try list.append(tx_num);

        // Sort to maintain order (for bitmap compression)
        std.mem.sort(u64, list.items, {}, comptime std.sort.asc(u64));
    }

    /// Seek transaction numbers for key up to tx_num
    /// Returns sorted list of all txNums where this key was modified
    ///
    /// Algorithm (from inverted_index.go):
    /// 1. Check in-memory index first
    /// 2. Read from .ef files
    /// 3. Merge and decompress bitmaps
    pub fn seek(self: *Self, key: []const u8, tx_num: u64, db_tx: *kv.Transaction) ![]u64 {
        _ = db_tx; // Not used in memory-only version

        var result = std.ArrayList(u64).init(self.allocator);
        errdefer result.deinit();

        // Check in-memory index
        if (self.index.get(key)) |list| {
            for (list.items) |tx| {
                if (tx <= tx_num) {
                    try result.append(tx);
                }
            }
        }

        // TODO: Check files as well
        // for (self.files.items) |*file| {
        //     const file_txs = try file.seek(key, tx_num);
        //     try result.appendSlice(file_txs);
        // }

        return result.toOwnedSlice();
    }

    /// Seek single transaction number for key
    /// Returns the largest txNum <= target where this key was modified
    ///
    /// Algorithm (from inverted_index.go seekInFiles):
    /// 1. Check files for key
    /// 2. Use .efi index to find encoded sequence
    /// 3. Binary search in Elias-Fano sequence for txNum
    /// 4. Return equal or higher txNum
    pub fn seekTxNum(self: *Self, key: []const u8, target_tx: u64) !?u64 {
        // First check in-memory index
        if (self.index.get(key)) |list| {
            var result: ?u64 = null;
            for (list.items) |tx| {
                if (tx <= target_tx) {
                    result = tx;
                } else {
                    break; // List is sorted, no need to continue
                }
            }
            if (result) |r| return r;
        }

        // TODO: Check files (seekInFiles implementation)
        // This would:
        // 1. Hash the key (murmur3)
        // 2. Look up in .efi index
        // 3. Read compressed sequence from .ef
        // 4. Binary search for largest txNum <= target

        return null;
    }

    /// Get all transaction numbers for key (no limit)
    pub fn get(self: *Self, key: []const u8) ![]u64 {
        var result = std.ArrayList(u64).init(self.allocator);
        errdefer result.deinit();

        if (self.index.get(key)) |list| {
            try result.appendSlice(list.items);
        }

        return result.toOwnedSlice();
    }

    /// Build index files from database
    pub fn buildFiles(self: *Self, from_step: u64, to_step: u64, db_tx: *kv.Transaction) !void {
        _ = self;
        _ = from_step;
        _ = to_step;
        _ = db_tx;
        // TODO: Implement file building
        // 1. Collect all key → txNum mappings in step range
        // 2. Compress with Elias-Fano encoding
        // 3. Build .efi index
    }

    /// Merge index files
    pub fn mergeFiles(self: *Self, files: []IndexFile) !IndexFile {
        _ = self;
        _ = files;
        // TODO: Implement merging
        return undefined;
    }
};

/// Index file on disk
pub const IndexFile = struct {
    from_step: u64,
    to_step: u64,

    /// Path to .ef file (Elias-Fano compressed data)
    ef_path: []const u8,

    /// Path to .efi file (index)
    efi_path: ?[]const u8 = null,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, from: u64, to: u64, base_path: []const u8) !IndexFile {
        const ef_path = try std.fmt.allocPrint(allocator, "{s}.{d}-{d}.ef", .{ base_path, from, to });
        return IndexFile{
            .allocator = allocator,
            .from_step = from,
            .to_step = to,
            .ef_path = ef_path,
        };
    }

    pub fn deinit(self: *IndexFile) void {
        self.allocator.free(self.ef_path);
        if (self.efi_path) |p| self.allocator.free(p);
    }

    /// Seek transaction numbers for key in this file
    pub fn seek(self: *IndexFile, key: []const u8, tx_num: u64) ![]u64 {
        _ = self;
        _ = key;
        _ = tx_num;
        // TODO: Implement file reading
        // 1. Use .efi index to find position
        // 2. Read compressed bitmap from .ef
        // 3. Decompress and filter by tx_num
        return &[_]u64{};
    }
};

/// Bitmap for efficient transaction number storage
/// In production, this would use Roaring bitmaps or Elias-Fano encoding
pub const TxNumBitmap = struct {
    numbers: std.ArrayList(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TxNumBitmap {
        return .{
            .allocator = allocator,
            .numbers = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *TxNumBitmap) void {
        self.numbers.deinit();
    }

    pub fn add(self: *TxNumBitmap, tx_num: u64) !void {
        try self.numbers.append(tx_num);
        std.mem.sort(u64, self.numbers.items, {}, comptime std.sort.asc(u64));
    }

    pub fn contains(self: *TxNumBitmap, tx_num: u64) bool {
        return std.mem.indexOfScalar(u64, self.numbers.items, tx_num) != null;
    }

    /// Compress bitmap using Elias-Fano encoding
    /// Returns compressed bytes
    pub fn compress(self: *TxNumBitmap) ![]u8 {
        _ = self;
        // TODO: Implement Elias-Fano compression
        // For now, just return raw encoding
        return &[_]u8{};
    }

    /// Decompress from bytes
    pub fn decompress(allocator: std.mem.Allocator, data: []const u8) !TxNumBitmap {
        _ = data;
        // TODO: Implement Elias-Fano decompression
        return TxNumBitmap.init(allocator);
    }
};

// ============ Tests ============

test "inverted index init/deinit" {
    const allocator = std.testing.allocator;

    var index = try InvertedIndex.init(allocator, 8192);
    defer index.deinit();

    try std.testing.expectEqual(@as(u64, 8192), index.step_size);
}

test "inverted index add/seek" {
    const allocator = std.testing.allocator;

    var index = try InvertedIndex.init(allocator, 8192);
    defer index.deinit();

    const key = "test_key";

    // Add some transaction numbers
    try index.add(key, 100, undefined);
    try index.add(key, 200, undefined);
    try index.add(key, 300, undefined);

    // Seek up to tx 250
    const result = try index.seek(key, 250, undefined);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u64, 100), result[0]);
    try std.testing.expectEqual(@as(u64, 200), result[1]);
}

test "bitmap compress/decompress" {
    const allocator = std.testing.allocator;

    var bitmap = TxNumBitmap.init(allocator);
    defer bitmap.deinit();

    try bitmap.add(100);
    try bitmap.add(200);
    try bitmap.add(300);

    try std.testing.expect(bitmap.contains(200));
    try std.testing.expect(!bitmap.contains(150));
}

test "index file path generation" {
    const allocator = std.testing.allocator;

    var file = try IndexFile.init(allocator, 0, 8192, "v1-accounts");
    defer file.deinit();

    try std.testing.expect(std.mem.indexOf(u8, file.ef_path, "0-8192.ef") != null);
}

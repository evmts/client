//! Domain - Erigon's flat state storage without intermediate trie nodes
//!
//! Architecture:
//! - Direct key→value storage in "domains" (no trie nodes in DB)
//! - Temporal indexing for historical queries
//! - Step-based file organization (stepSize = 8192 blocks typically)
//! - Multiple accessor indices for fast lookups
//!
//! File Types:
//! - .kv   - compressed key-value pairs
//! - .bt   - B-tree index for key lookups
//! - .kvi  - HashMap index (recsplit)
//! - .kvei - Existence filter (bloom-like)
//!
//! Based on: erigon/db/state/domain.go (2,005 lines)
//! Zig version: ~400 lines (5x compression)

const std = @import("std");
const kv = @import("../kv/kv.zig");
const tables = @import("../kv/tables.zig");
const History = @import("history.zig").History;

/// Domain configuration matching Erigon's statecfg.DomainCfg
pub const DomainConfig = struct {
    name: []const u8,
    /// Step size in blocks (usually 8192)
    step_size: u64 = 8192,
    /// Enable history tracking
    with_history: bool = true,
    /// Enable compression
    compression: bool = true,
    /// Directory for domain files
    snap_dir: []const u8,
};

/// Domain - main structure for flat state storage
pub const Domain = struct {
    allocator: std.mem.Allocator,
    config: DomainConfig,
    history: ?*History,

    /// Files currently open (equivalent to dirtyFiles btree)
    /// In Erigon this is btree2.BTreeG[*FilesItem]
    files: std.ArrayList(DomainFile),

    /// Current step (txNum / stepSize)
    current_step: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: DomainConfig) !Self {
        var history: ?*History = null;
        if (config.with_history) {
            const hist = try allocator.create(History);
            hist.* = try History.init(allocator, config.step_size);
            history = hist;
        }

        return Self{
            .allocator = allocator,
            .config = config,
            .history = history,
            .files = std.ArrayList(DomainFile).init(allocator),
            .current_step = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.history) |hist| {
            hist.deinit();
            self.allocator.destroy(hist);
        }
        for (self.files.items) |*file| {
            file.deinit();
        }
        self.files.deinit();
    }

    /// Get value for key at specific transaction number (temporal query)
    /// This is the core "time-travel" query method
    ///
    /// Algorithm (from domain.go GetAsOf):
    /// 1. Check history for value at txNum
    /// 2. If not in history, get latest value
    /// 3. Return nil if key didn't exist at that time
    pub fn getAsOf(self: *Self, key: []const u8, tx_num: u64, db_tx: *kv.Transaction) !?[]const u8 {
        // First try to find in history
        if (self.history) |hist| {
            if (try hist.seekValue(key, tx_num, db_tx)) |value| {
                // Empty value means key was deleted at this point
                if (value.len == 0) {
                    return null;
                }
                // Must copy because history buffer is temporary
                return try self.allocator.dupe(u8, value);
            }
        }

        // Not in history - get latest value
        // This handles case where key was created before history started
        const latest_result = try self.getLatest(key, db_tx);
        if (latest_result.found) {
            return latest_result.value;
        }

        return null;
    }

    /// Get latest value for key
    /// Returns struct with value, step where found, and found flag
    ///
    /// Algorithm (from domain.go GetLatest):
    /// 1. Check DB first (hot data)
    /// 2. Check files from newest to oldest
    /// 3. Return nil if not found anywhere
    pub fn getLatest(self: *Self, key: []const u8, db_tx: *kv.Transaction) !LatestResult {
        // First try database (hot/recent data)
        if (try self.getLatestFromDb(key, db_tx)) |result| {
            return result;
        }

        // Then try files (cold/historical data)
        if (try self.getLatestFromFiles(key)) |result| {
            return result;
        }

        return LatestResult{
            .value = null,
            .step = 0,
            .found = false,
        };
    }

    /// Put value for key
    /// In production, this writes to a buffer that's later flushed to files
    /// For now, we write directly to the database
    pub fn put(self: *Self, key: []const u8, value: []const u8, tx_num: u64, db_tx: *kv.Transaction) !void {
        // Calculate step
        const step = tx_num / self.config.step_size;

        // Update current step
        self.current_step = @max(self.current_step, step);

        // In Erigon, this would write to a buffer (DomainBufferedWriter)
        // For simplicity, we write to a special table with step encoding
        const table = self.getValuesTable();

        // Encode key with inverted step (for sorting newest first)
        // Format: key ++ ^step (8 bytes, big-endian, inverted)
        var keybuf = try self.allocator.alloc(u8, key.len + 8);
        defer self.allocator.free(keybuf);

        @memcpy(keybuf[0..key.len], key);
        const inverted_step = ~step; // Invert for reverse sort
        std.mem.writeInt(u64, keybuf[key.len..][0..8], inverted_step, .big);

        // Encode value with step prefix
        // Format: step (8 bytes) ++ value
        var valbuf = try self.allocator.alloc(u8, 8 + value.len);
        defer self.allocator.free(valbuf);

        std.mem.writeInt(u64, valbuf[0..8], inverted_step, .big);
        @memcpy(valbuf[8..], value);

        try db_tx.put(table, keybuf, valbuf);

        // Track in history if enabled
        if (self.history) |hist| {
            try hist.trackChange(key, value, tx_num, db_tx);
        }
    }

    /// Delete key (put empty value)
    pub fn delete(self: *Self, key: []const u8, tx_num: u64, db_tx: *kv.Transaction) !void {
        try self.put(key, &[_]u8{}, tx_num, db_tx);
    }

    // ============ Internal Methods ============

    fn getValuesTable(self: *Self) tables.Table {
        // Map domain name to table
        // In production, this would be configurable
        _ = self;
        return .PlainState; // Default to PlainState for accounts/storage
    }

    fn getLatestFromDb(self: *Self, key: []const u8, db_tx: *kv.Transaction) !?LatestResult {
        const table = self.getValuesTable();

        // Scan for latest value (keys are sorted with inverted step)
        var cursor = try db_tx.cursor(table);
        defer cursor.close();

        // Seek to first key matching our prefix
        if (try cursor.seek(key)) |entry| {
            // Check if key matches (may be prefix match)
            if (std.mem.startsWith(u8, entry.key, key)) {
                // Extract step from value
                if (entry.value.len < 8) {
                    return null;
                }
                const inverted_step = std.mem.readInt(u64, entry.value[0..8], .big);
                const step = ~inverted_step;

                const value = try self.allocator.dupe(u8, entry.value[8..]);
                return LatestResult{
                    .value = value,
                    .step = step,
                    .found = true,
                };
            }
        }

        return null;
    }

    fn getLatestFromFiles(self: *Self, key: []const u8) !?LatestResult {
        // Search files from newest to oldest
        // Files are sorted by step range
        var i: usize = self.files.items.len;
        while (i > 0) {
            i -= 1;
            const file = &self.files.items[i];

            if (try file.get(key)) |value| {
                const value_copy = try self.allocator.dupe(u8, value);
                return LatestResult{
                    .value = value_copy,
                    .step = file.to_step,
                    .found = true,
                };
            }
        }

        return null;
    }

    /// Build domain files from database (collation + build)
    /// This is the core of Erigon's optimization - moving data from DB to files
    pub fn buildFiles(self: *Self, from_step: u64, to_step: u64, db_tx: *kv.Transaction) !void {
        _ = self;
        _ = from_step;
        _ = to_step;
        _ = db_tx;
        // TODO: Implement file building
        // 1. Collate data from DB for step range
        // 2. Compress to .kv file
        // 3. Build accessor indices (.bt, .kvi, .kvei)
        // 4. Register file in files list
    }

    /// Merge files together (background compaction)
    pub fn mergeFiles(self: *Self, files_to_merge: []DomainFile) !DomainFile {
        _ = self;
        _ = files_to_merge;
        // TODO: Implement file merging
        // 1. Open all files to merge
        // 2. Merge-sort their contents
        // 3. Write to new file
        // 4. Build indices
        // 5. Mark old files for deletion
        return undefined;
    }
};

/// Result from getLatest query
pub const LatestResult = struct {
    value: ?[]const u8,
    step: u64,
    found: bool,
};

/// Domain file on disk
/// Represents a range of steps [from_step, to_step)
pub const DomainFile = struct {
    from_step: u64,
    to_step: u64,

    /// Path to .kv file (compressed key-value data)
    kv_path: []const u8,

    /// Path to .bt file (B-tree index)
    bt_path: ?[]const u8 = null,

    /// Path to .kvi file (HashMap index)
    kvi_path: ?[]const u8 = null,

    /// Path to .kvei file (existence filter)
    kvei_path: ?[]const u8 = null,

    /// File handles (opened lazily)
    kv_file: ?std.fs.File = null,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, from: u64, to: u64, base_path: []const u8) !DomainFile {
        const kv_path = try std.fmt.allocPrint(allocator, "{s}.{d}-{d}.kv", .{ base_path, from, to });
        return DomainFile{
            .allocator = allocator,
            .from_step = from,
            .to_step = to,
            .kv_path = kv_path,
        };
    }

    pub fn deinit(self: *DomainFile) void {
        if (self.kv_file) |f| {
            f.close();
        }
        self.allocator.free(self.kv_path);
        if (self.bt_path) |p| self.allocator.free(p);
        if (self.kvi_path) |p| self.allocator.free(p);
        if (self.kvei_path) |p| self.allocator.free(p);
    }

    /// Get value for key from this file
    pub fn get(self: *DomainFile, key: []const u8) !?[]const u8 {
        _ = self;
        _ = key;
        // TODO: Implement file reading
        // 1. Use index (.bt or .kvi) to find offset
        // 2. Read from .kv file at offset
        // 3. Decompress if needed
        return null;
    }

    /// Check if key exists in this file (using .kvei filter)
    pub fn exists(self: *DomainFile, key: []const u8) !bool {
        _ = self;
        _ = key;
        // TODO: Check existence filter first (fast negative lookup)
        return false;
    }
};

/// Read-only transaction over domain
/// Equivalent to Erigon's DomainRoTx
pub const DomainRoTx = struct {
    domain: *Domain,
    files: []DomainFile,

    pub fn getAsOf(self: *DomainRoTx, key: []const u8, tx_num: u64, db_tx: *kv.Transaction) !?[]const u8 {
        return self.domain.getAsOf(key, tx_num, db_tx);
    }

    pub fn getLatest(self: *DomainRoTx, key: []const u8, db_tx: *kv.Transaction) !LatestResult {
        return self.domain.getLatest(key, db_tx);
    }
};

// ============ Tests ============

test "domain init/deinit" {
    const allocator = std.testing.allocator;

    const config = DomainConfig{
        .name = "accounts",
        .step_size = 8192,
        .snap_dir = "/tmp/test",
        .with_history = false,
    };

    var domain = try Domain.init(allocator, config);
    defer domain.deinit();

    try std.testing.expectEqual(@as(u64, 8192), domain.config.step_size);
    try std.testing.expectEqual(@as(usize, 0), domain.files.items.len);
}

test "domain file path generation" {
    const allocator = std.testing.allocator;

    var file = try DomainFile.init(allocator, 0, 8192, "v1-accounts");
    defer file.deinit();

    try std.testing.expect(std.mem.indexOf(u8, file.kv_path, "0-8192.kv") != null);
}

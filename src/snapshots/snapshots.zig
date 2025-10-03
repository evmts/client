//! Snapshot/Freezer architecture - Erigon's key optimization
//! Based on erigon-lib/downloader and erigon/eth/snapshots
//!
//! Snapshots are immutable, compressed historical data files that can be:
//! - Downloaded via torrent (faster than P2P sync)
//! - Memory-mapped for zero-copy access
//! - Shared across nodes to save bandwidth

const std = @import("std");

/// Snapshot types matching Erigon's schema
pub const SnapshotType = enum {
    headers,
    bodies,
    transactions,

    pub fn toString(self: SnapshotType) []const u8 {
        return switch (self) {
            .headers => "headers",
            .bodies => "bodies",
            .transactions => "transactions",
        };
    }

    pub fn fileExtension(self: SnapshotType) []const u8 {
        return switch (self) {
            .headers => ".seg",
            .bodies => ".seg",
            .transactions => ".seg",
        };
    }
};

/// Snapshot segment representing a range of blocks
pub const SnapshotSegment = struct {
    snapshot_type: SnapshotType,
    from_block: u64,
    to_block: u64,
    file_path: []const u8,
    size: u64,
    compressed: bool,

    /// Snapshot file naming: headers-000000-000500.seg
    pub fn fileName(
        self: SnapshotSegment,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        return try std.fmt.allocPrint(
            allocator,
            "{s}-{d:0>6}-{d:0>6}{s}",
            .{
                self.snapshot_type.toString(),
                self.from_block / 1000,
                self.to_block / 1000,
                self.snapshot_type.fileExtension(),
            },
        );
    }
};

/// Snapshot configuration
pub const SnapshotConfig = struct {
    /// Directory where snapshots are stored
    snapshot_dir: []const u8,
    /// Whether to enable snapshots
    enabled: bool,
    /// Download snapshots via torrent
    torrent_download: bool,
    /// Snapshot segment size (in blocks)
    segment_size: u64,

    pub fn default() SnapshotConfig {
        return .{
            .snapshot_dir = "./snapshots",
            .enabled = true,
            .torrent_download = false,
            .segment_size = 500_000, // 500k blocks per segment
        };
    }
};

/// Snapshot manager
pub const SnapshotManager = struct {
    allocator: std.mem.Allocator,
    config: SnapshotConfig,
    segments: std.ArrayList(SnapshotSegment),

    pub fn init(allocator: std.mem.Allocator, config: SnapshotConfig) SnapshotManager {
        return .{
            .allocator = allocator,
            .config = config,
            .segments = std.ArrayList(SnapshotSegment).empty,
        };
    }

    pub fn deinit(self: *SnapshotManager) void {
        for (self.segments.items) |segment| {
            self.allocator.free(segment.file_path);
        }
        self.segments.deinit(self.allocator);
    }

    /// Open all available snapshot segments
    pub fn openSnapshots(self: *SnapshotManager) !void {
        if (!self.config.enabled) return;

        std.log.info("Opening snapshots from {s}", .{self.config.snapshot_dir});

        // Create snapshot directory if it doesn't exist
        std.fs.cwd().makeDir(self.config.snapshot_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Scan directory for snapshot files
        var dir = try std.fs.cwd().openDir(self.config.snapshot_dir, .{ .iterate = true });
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".seg")) continue;

            // Parse snapshot filename
            if (try self.parseSnapshotFile(entry.name)) |segment| {
                try self.segments.append(self.allocator, segment);
                std.log.debug("Loaded snapshot: {s}", .{entry.name});
            }
        }

        // Sort segments by block range
        std.mem.sort(SnapshotSegment, self.segments.items, {}, compareSegments);

        std.log.info("Loaded {} snapshot segments", .{self.segments.items.len});
    }

    fn parseSnapshotFile(self: *SnapshotManager, filename: []const u8) !?SnapshotSegment {
        // Parse: headers-000000-000500.seg
        var it = std.mem.splitScalar(u8, filename, '-');

        const type_str = it.next() orelse return null;
        const from_str = it.next() orelse return null;

        var rest_it = std.mem.splitScalar(u8, it.rest(), '.');
        const to_str = rest_it.next() orelse return null;

        const snapshot_type = std.meta.stringToEnum(SnapshotType, type_str) orelse return null;
        const from_block = try std.fmt.parseInt(u64, from_str, 10) * 1000;
        const to_block = try std.fmt.parseInt(u64, to_str, 10) * 1000;

        const file_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.config.snapshot_dir, filename },
        );

        // Get file size
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const stat = try file.stat();

        return SnapshotSegment{
            .snapshot_type = snapshot_type,
            .from_block = from_block,
            .to_block = to_block,
            .file_path = file_path,
            .size = stat.size,
            .compressed = true,
        };
    }

    fn compareSegments(_: void, a: SnapshotSegment, b: SnapshotSegment) bool {
        if (a.from_block != b.from_block) {
            return a.from_block < b.from_block;
        }
        return @intFromEnum(a.snapshot_type) < @intFromEnum(b.snapshot_type);
    }

    /// Get the highest block covered by snapshots
    pub fn getHighestBlock(self: *SnapshotManager, snapshot_type: SnapshotType) ?u64 {
        var highest: ?u64 = null;

        for (self.segments.items) |segment| {
            if (segment.snapshot_type == snapshot_type) {
                if (highest == null or segment.to_block > highest.?) {
                    highest = segment.to_block;
                }
            }
        }

        return highest;
    }

    /// Check if a block is available in snapshots
    pub fn hasBlock(self: *SnapshotManager, block_num: u64, snapshot_type: SnapshotType) bool {
        for (self.segments.items) |segment| {
            if (segment.snapshot_type == snapshot_type and
                block_num >= segment.from_block and
                block_num < segment.to_block)
            {
                return true;
            }
        }
        return false;
    }

    /// Read header from snapshot
    pub fn readHeader(self: *SnapshotManager, block_num: u64) !?[]const u8 {
        for (self.segments.items) |segment| {
            if (segment.snapshot_type == .headers and
                block_num >= segment.from_block and
                block_num < segment.to_block)
            {
                // In production: memory-map file, decompress, seek to block
                std.log.debug("Would read header {} from snapshot {s}", .{
                    block_num,
                    segment.file_path,
                });
                return null; // Simplified
            }
        }
        return null;
    }
};

test "snapshot file parsing" {
    var manager = SnapshotManager.init(
        std.testing.allocator,
        SnapshotConfig.default(),
    );
    defer manager.deinit();

    const segment = try manager.parseSnapshotFile("headers-000000-000500.seg");
    try std.testing.expect(segment != null);
    try std.testing.expectEqual(SnapshotType.headers, segment.?.snapshot_type);
    try std.testing.expectEqual(@as(u64, 0), segment.?.from_block);
    try std.testing.expectEqual(@as(u64, 500_000), segment.?.to_block);

    std.testing.allocator.free(segment.?.file_path);
}

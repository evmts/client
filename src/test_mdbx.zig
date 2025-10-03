// Test MDBX integration with client
const std = @import("std");
const mdbx = @import("kv/mdbx.zig");
const kv = @import("kv/kv.zig");
const tables = @import("kv/tables.zig");

test "MDBX integration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create temporary directory
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = "testdb";
    try tmp_dir.dir.makeDir(path);

    const full_path = try tmp_dir.dir.realpathAlloc(allocator, path);
    defer allocator.free(full_path);

    // Initialize MDBX database
    var db = try mdbx.MdbxDb.init(allocator, full_path);
    defer db.deinit();

    var kv_db = db.database();

    // Begin write transaction
    var tx = try kv_db.beginTx(true);

    // Store a block header
    const block_num_key = tables.encodeBlockNumber(100);
    const header_data = "mock_header_data";
    try tx.put(.Headers, &block_num_key, header_data);

    // Read it back
    const read_data = try tx.get(.Headers, &block_num_key);
    try testing.expect(read_data != null);
    try testing.expectEqualStrings(header_data, read_data.?);

    // Store stage progress
    const stage_key = "Headers";
    var progress_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &progress_buf, 100, .big);
    try tx.put(.SyncStageProgress, stage_key, &progress_buf);

    // Read stage progress
    const progress_data = try tx.get(.SyncStageProgress, stage_key);
    try testing.expect(progress_data != null);
    const progress = std.mem.readInt(u64, progress_data.?[0..8], .big);
    try testing.expectEqual(@as(u64, 100), progress);

    // Test cursor iteration
    var cursor = try tx.cursor(.Headers);
    defer cursor.close();

    const first = try cursor.first();
    try testing.expect(first != null);
    try testing.expectEqualStrings(header_data, first.?.value);

    // Commit transaction
    try tx.commit();

    std.log.info("✅ MDBX integration test passed!", .{});
}

test "MDBX cursor operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = "testdb2";
    try tmp_dir.dir.makeDir(path);

    const full_path = try tmp_dir.dir.realpathAlloc(allocator, path);
    defer allocator.free(full_path);

    var db = try mdbx.MdbxDb.init(allocator, full_path);
    defer db.deinit();

    var kv_db = db.database();

    // Write multiple entries
    {
        var tx = try kv_db.beginTx(true);

        for (0..10) |i| {
            const key = tables.encodeBlockNumber(@intCast(i));
            var value_buf: [32]u8 = undefined;
            @memset(&value_buf, @intCast(i));
            try tx.put(.Headers, &key, &value_buf);
        }

        try tx.commit();
    }

    // Read back with cursor
    {
        var tx = try kv_db.beginTx(false);
        defer tx.rollback();

        var cursor = try tx.cursor(.Headers);
        defer cursor.close();

        // Iterate forward
        var count: usize = 0;
        var entry_opt = try cursor.first();
        while (entry_opt) |entry| : (entry_opt = try cursor.next()) {
            try testing.expect(entry.value.len == 32);
            count += 1;
        }
        try testing.expectEqual(@as(usize, 10), count);

        // Seek to specific key
        const seek_key = tables.encodeBlockNumber(5);
        const seek_result = try cursor.seek(&seek_key);
        try testing.expect(seek_result != null);
    }

    std.log.info("✅ MDBX cursor test passed!", .{});
}

// MDBX database implementation
//! Implements the KV interface using libmdbx
//! Based on Erigon's MDBX usage patterns

const std = @import("std");
const kv = @import("kv.zig");
const tables = @import("tables.zig");
const mdbx = @import("mdbx_bindings.zig");

pub const MdbxDb = struct {
    allocator: std.mem.Allocator,
    env: *mdbx.Env,
    path: []const u8,
    dbis: std.StringHashMap(mdbx.Dbi),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Self {
        var env: ?*mdbx.Env = null;

        // Create environment
        try mdbx.checkError(mdbx.env_create(&env));
        const env_ptr = env orelse return error.FailedToCreateEnv;

        // Set max databases (one per table)
        try mdbx.checkError(mdbx.env_set_maxdbs(env_ptr, 128));

        // Set geometry (size limits)
        // Parameters: size_lower, size_now, size_upper, growth_step, shrink_threshold, pagesize
        const size_lower = 1024 * 1024; // 1 MB minimum
        const size_now = 100 * 1024 * 1024; // 100 MB initial
        const size_upper = 1024 * 1024 * 1024 * @as(i64, 1024); // 1 TB maximum
        const growth_step = 10 * 1024 * 1024; // 10 MB growth
        const shrink_threshold = 0; // Don't auto-shrink
        const pagesize = 4096; // 4 KB pages

        try mdbx.checkError(mdbx.env_set_geometry(
            env_ptr,
            size_lower,
            size_now,
            size_upper,
            growth_step,
            shrink_threshold,
            pagesize,
        ));

        // Open environment
        const flags = mdbx.EnvFlags.WRITEMAP | mdbx.EnvFlags.COALESCE | mdbx.EnvFlags.LIFORECLAIM;
        const mode = 0o664; // rw-rw-r--
        try mdbx.checkError(mdbx.env_open(env_ptr, path.ptr, flags, mode));

        return Self{
            .allocator = allocator,
            .env = env_ptr,
            .path = path,
            .dbis = std.StringHashMap(mdbx.Dbi).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Close all DBIs
        var it = self.dbis.iterator();
        while (it.next()) |entry| {
            mdbx.dbi_close(self.env, entry.value_ptr.*);
        }
        self.dbis.deinit();

        // Close environment
        _ = mdbx.env_close(self.env);
    }

    /// Get or open a DBI for a table
    fn getDbi(self: *Self, txn: *mdbx.Txn, table: tables.Table) !mdbx.Dbi {
        const table_name = table.toString();

        if (self.dbis.get(table_name)) |dbi| {
            return dbi;
        }

        // Open the DBI
        var dbi: mdbx.Dbi = 0;
        const flags = mdbx.DbiFlags.CREATE;
        try mdbx.checkError(mdbx.dbi_open(txn, table_name.ptr, flags, &dbi));

        try self.dbis.put(table_name, dbi);
        return dbi;
    }

    /// Convert to KV Database interface
    pub fn database(self: *Self) kv.Database {
        return kv.Database{
            .vtable = &.{
                .beginTx = beginTxImpl,
                .close = closeImpl,
            },
            .ptr = self,
        };
    }

    fn beginTxImpl(ptr: *anyopaque, writable: bool) anyerror!*kv.Transaction {
        const self: *Self = @ptrCast(@alignCast(ptr));

        var txn: ?*mdbx.Txn = null;
        const flags = if (writable) mdbx.TxnFlags.READWRITE else mdbx.TxnFlags.RDONLY;
        try mdbx.checkError(mdbx.txn_begin(self.env, null, flags, &txn));

        const mdbx_txn = try self.allocator.create(MdbxTransaction);
        mdbx_txn.* = MdbxTransaction{
            .allocator = self.allocator,
            .db = self,
            .txn = txn.?,
            .writable = writable,
            .cursors = std.ArrayList(*MdbxCursor).init(self.allocator),
        };

        return &mdbx_txn.transaction;
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

const MdbxTransaction = struct {
    allocator: std.mem.Allocator,
    db: *MdbxDb,
    txn: *mdbx.Txn,
    writable: bool,
    cursors: std.ArrayList(*MdbxCursor),
    transaction: kv.Transaction,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db: *MdbxDb, txn: *mdbx.Txn, writable: bool) Self {
        return Self{
            .allocator = allocator,
            .db = db,
            .txn = txn,
            .writable = writable,
            .cursors = std.ArrayList(*MdbxCursor).init(allocator),
            .transaction = kv.Transaction{
                .vtable = &.{
                    .get = getImpl,
                    .put = putImpl,
                    .delete = deleteImpl,
                    .cursor = cursorImpl,
                    .commit = commitImpl,
                    .rollback = rollbackImpl,
                },
                .ptr = undefined, // Set after initialization
            },
        };
    }

    fn getImpl(ptr: *anyopaque, table: tables.Table, key: []const u8) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const dbi = try self.db.getDbi(self.txn, table);

        var key_val = mdbx.valFromSlice(key);
        var data_val: mdbx.Val = undefined;

        const rc = mdbx.get(self.txn, dbi, &key_val, &data_val);
        if (rc == @import("mdbx_bindings.zig").c.MDBX_NOTFOUND) {
            return null;
        }
        try mdbx.checkError(rc);

        // Allocate and copy the data (MDBX memory is only valid during transaction)
        const data_slice = mdbx.sliceFromVal(data_val);
        const copy = try self.allocator.dupe(u8, data_slice);
        return copy;
    }

    fn putImpl(ptr: *anyopaque, table: tables.Table, key: []const u8, value: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!self.writable) return error.ReadOnlyTransaction;

        const dbi = try self.db.getDbi(self.txn, table);

        var key_val = mdbx.valFromSlice(key);
        var data_val = mdbx.valFromSlice(value);

        try mdbx.checkError(mdbx.put(self.txn, dbi, &key_val, &data_val, 0));
    }

    fn deleteImpl(ptr: *anyopaque, table: tables.Table, key: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!self.writable) return error.ReadOnlyTransaction;

        const dbi = try self.db.getDbi(self.txn, table);

        var key_val = mdbx.valFromSlice(key);

        const rc = mdbx.del(self.txn, dbi, &key_val, null);
        if (rc == @import("mdbx_bindings.zig").c.MDBX_NOTFOUND) {
            return; // Deleting non-existent key is OK
        }
        try mdbx.checkError(rc);
    }

    fn cursorImpl(ptr: *anyopaque, table: tables.Table) anyerror!*kv.Cursor {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const dbi = try self.db.getDbi(self.txn, table);

        var cursor: ?*mdbx.Cursor = null;
        try mdbx.checkError(mdbx.cursor_open(self.txn, dbi, &cursor));

        const mdbx_cursor = try self.allocator.create(MdbxCursor);
        mdbx_cursor.* = MdbxCursor{
            .allocator = self.allocator,
            .cursor = cursor.?,
            .kv_cursor = kv.Cursor{
                .vtable = &.{
                    .first = MdbxCursor.firstImpl,
                    .last = MdbxCursor.lastImpl,
                    .next = MdbxCursor.nextImpl,
                    .prev = MdbxCursor.prevImpl,
                    .seek = MdbxCursor.seekImpl,
                    .current = MdbxCursor.currentImpl,
                    .close = MdbxCursor.closeImpl,
                },
                .ptr = mdbx_cursor,
            },
        };

        try self.cursors.append(mdbx_cursor);
        return &mdbx_cursor.kv_cursor;
    }

    fn commitImpl(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Close all cursors
        for (self.cursors.items) |cursor| {
            mdbx.cursor_close(cursor.cursor);
            self.allocator.destroy(cursor);
        }
        self.cursors.deinit();

        try mdbx.checkError(mdbx.txn_commit(self.txn));
        self.allocator.destroy(self);
    }

    fn rollbackImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Close all cursors
        for (self.cursors.items) |cursor| {
            mdbx.cursor_close(cursor.cursor);
            self.allocator.destroy(cursor);
        }
        self.cursors.deinit();

        _ = mdbx.txn_abort(self.txn);
        self.allocator.destroy(self);
    }
};

const MdbxCursor = struct {
    allocator: std.mem.Allocator,
    cursor: *mdbx.Cursor,
    kv_cursor: kv.Cursor,

    const Self = @This();

    fn doGet(self: *Self, op: c_uint) anyerror!?kv.Cursor.Entry {
        var key_val: mdbx.Val = undefined;
        var data_val: mdbx.Val = undefined;

        const rc = mdbx.cursor_get(self.cursor, &key_val, &data_val, op);
        if (rc == @import("mdbx_bindings.zig").c.MDBX_NOTFOUND) {
            return null;
        }
        try mdbx.checkError(rc);

        const key_slice = mdbx.sliceFromVal(key_val);
        const data_slice = mdbx.sliceFromVal(data_val);

        // Allocate copies (MDBX memory is only valid during transaction)
        const key_copy = try self.allocator.dupe(u8, key_slice);
        const data_copy = try self.allocator.dupe(u8, data_slice);

        return kv.Cursor.Entry{
            .key = key_copy,
            .value = data_copy,
        };
    }

    fn firstImpl(ptr: *anyopaque) anyerror!?kv.Cursor.Entry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.doGet(mdbx.CursorOp.FIRST);
    }

    fn lastImpl(ptr: *anyopaque) anyerror!?kv.Cursor.Entry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.doGet(mdbx.CursorOp.LAST);
    }

    fn nextImpl(ptr: *anyopaque) anyerror!?kv.Cursor.Entry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.doGet(mdbx.CursorOp.NEXT);
    }

    fn prevImpl(ptr: *anyopaque) anyerror!?kv.Cursor.Entry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.doGet(mdbx.CursorOp.PREV);
    }

    fn seekImpl(ptr: *anyopaque, key: []const u8) anyerror!?kv.Cursor.Entry {
        const self: *Self = @ptrCast(@alignCast(ptr));

        var key_val = mdbx.valFromSlice(key);
        var data_val: mdbx.Val = undefined;

        const rc = mdbx.cursor_get(self.cursor, &key_val, &data_val, mdbx.CursorOp.SET_RANGE);
        if (rc == @import("mdbx_bindings.zig").c.MDBX_NOTFOUND) {
            return null;
        }
        try mdbx.checkError(rc);

        const key_slice = mdbx.sliceFromVal(key_val);
        const data_slice = mdbx.sliceFromVal(data_val);

        const key_copy = try self.allocator.dupe(u8, key_slice);
        const data_copy = try self.allocator.dupe(u8, data_slice);

        return kv.Cursor.Entry{
            .key = key_copy,
            .value = data_copy,
        };
    }

    fn currentImpl(ptr: *anyopaque) anyerror!?kv.Cursor.Entry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.doGet(mdbx.CursorOp.GET_CURRENT);
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        mdbx.cursor_close(self.cursor);
        // Note: Memory is freed by transaction cleanup
    }
};

test "mdbx basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create temporary directory
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = "test_db";
    try tmp_dir.dir.makeDir(path);

    const full_path = try tmp_dir.dir.realpathAlloc(allocator, path);
    defer allocator.free(full_path);

    // Open database
    var db = try MdbxDb.init(allocator, full_path);
    defer db.deinit();

    var kv_db = db.database();

    // Begin transaction
    var tx = try kv_db.beginTx(true);

    // Put a value
    try tx.put(.Headers, "key1", "value1");

    // Get the value
    const value = try tx.get(.Headers, "key1");
    try testing.expect(value != null);
    try testing.expectEqualStrings("value1", value.?);

    // Commit
    try tx.commit();
}

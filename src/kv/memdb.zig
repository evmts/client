//! In-memory database implementation
//! For testing and development; production would use MDBX

const std = @import("std");
const kv = @import("kv.zig");
const tables = @import("tables.zig");

pub const MemDb = struct {
    allocator: std.mem.Allocator,
    data: std.StringHashMap(*TableData),
    db_interface: kv.Database,

    const TableData = std.StringArrayHashMap([]const u8);

    pub fn init(allocator: std.mem.Allocator) !*MemDb {
        const self = try allocator.create(MemDb);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .data = std.StringHashMap(*TableData).init(allocator),
            .db_interface = .{
                .vtable = &db_vtable,
                .ptr = self,
            },
        };

        return self;
    }

    pub fn deinit(self: *MemDb) void {
        var iter = self.data.valueIterator();
        while (iter.next()) |table_data| {
            var entry_iter = table_data.*.iterator();
            while (entry_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            table_data.*.deinit();
            self.allocator.destroy(table_data.*);
        }
        self.data.deinit();
        self.allocator.destroy(self);
    }

    pub fn asDatabase(self: *MemDb) kv.Database {
        return self.db_interface;
    }

    fn getOrCreateTable(self: *MemDb, table: tables.Table) !*TableData {
        const table_name = table.toString();
        if (self.data.get(table_name)) |td| {
            return td;
        }

        const new_table = try self.allocator.create(TableData);
        new_table.* = TableData.init(self.allocator);
        try self.data.put(table_name, new_table);
        return new_table;
    }

    const db_vtable = kv.Database.VTable{
        .beginTx = beginTxImpl,
        .close = closeImpl,
    };

    fn beginTxImpl(ptr: *anyopaque, writable: bool) !*kv.Transaction {
        const self: *MemDb = @ptrCast(@alignCast(ptr));
        const tx = try self.allocator.create(MemTx);
        errdefer self.allocator.destroy(tx);

        tx.* = .{
            .db = self,
            .writable = writable,
            .allocator = self.allocator,
            .tx_interface = .{
                .vtable = &tx_vtable,
                .ptr = tx,
            },
        };

        return &tx.tx_interface;
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *MemDb = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

const MemTx = struct {
    db: *MemDb,
    writable: bool,
    allocator: std.mem.Allocator,
    tx_interface: kv.Transaction,

    const tx_vtable = kv.Transaction.VTable{
        .get = getImpl,
        .put = putImpl,
        .delete = deleteImpl,
        .cursor = cursorImpl,
        .commit = commitImpl,
        .rollback = rollbackImpl,
    };

    fn getImpl(ptr: *anyopaque, table: tables.Table, key: []const u8) !?[]const u8 {
        const self: *MemTx = @ptrCast(@alignCast(ptr));
        const table_data = self.db.getOrCreateTable(table) catch return null;
        return table_data.get(key);
    }

    fn putImpl(ptr: *anyopaque, table: tables.Table, key: []const u8, value: []const u8) !void {
        const self: *MemTx = @ptrCast(@alignCast(ptr));
        if (!self.writable) return kv.KvError.ReadOnlyTransaction;

        const table_data = try self.db.getOrCreateTable(table);

        // Check if key exists
        if (table_data.get(key)) |old_value| {
            self.allocator.free(old_value);
            _ = table_data.orderedRemove(key);
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        try table_data.put(key_copy, value_copy);
    }

    fn deleteImpl(ptr: *anyopaque, table: tables.Table, key: []const u8) !void {
        const self: *MemTx = @ptrCast(@alignCast(ptr));
        if (!self.writable) return kv.KvError.ReadOnlyTransaction;

        const table_data = self.db.getOrCreateTable(table) catch return;

        if (table_data.fetchSwapRemove(key)) |kv_pair| {
            self.allocator.free(kv_pair.key);
            self.allocator.free(kv_pair.value);
        }
    }

    fn cursorImpl(ptr: *anyopaque, table: tables.Table) !*kv.Cursor {
        const self: *MemTx = @ptrCast(@alignCast(ptr));
        const cursor = try self.allocator.create(MemCursor);
        errdefer self.allocator.destroy(cursor);

        const table_data = try self.db.getOrCreateTable(table);

        cursor.* = .{
            .table_data = table_data,
            .current_index = null,
            .allocator = self.allocator,
            .cursor_interface = .{
                .vtable = &cursor_vtable,
                .ptr = cursor,
            },
        };

        return &cursor.cursor_interface;
    }

    fn commitImpl(ptr: *anyopaque) !void {
        const self: *MemTx = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn rollbackImpl(ptr: *anyopaque) void {
        const self: *MemTx = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

const MemCursor = struct {
    table_data: *MemDb.TableData,
    current_index: ?usize,
    allocator: std.mem.Allocator,
    cursor_interface: kv.Cursor,

    const cursor_vtable = kv.Cursor.VTable{
        .first = firstImpl,
        .last = lastImpl,
        .next = nextImpl,
        .prev = prevImpl,
        .seek = seekImpl,
        .current = currentImpl,
        .close = closeImpl,
    };

    fn firstImpl(ptr: *anyopaque) !?kv.Cursor.Entry {
        const self: *MemCursor = @ptrCast(@alignCast(ptr));
        if (self.table_data.count() == 0) return null;

        self.current_index = 0;
        const entry = self.table_data.keys()[0];
        const value = self.table_data.values()[0];

        return kv.Cursor.Entry{
            .key = entry,
            .value = value,
        };
    }

    fn lastImpl(ptr: *anyopaque) !?kv.Cursor.Entry {
        const self: *MemCursor = @ptrCast(@alignCast(ptr));
        const count = self.table_data.count();
        if (count == 0) return null;

        self.current_index = count - 1;
        const entry = self.table_data.keys()[count - 1];
        const value = self.table_data.values()[count - 1];

        return kv.Cursor.Entry{
            .key = entry,
            .value = value,
        };
    }

    fn nextImpl(ptr: *anyopaque) !?kv.Cursor.Entry {
        const self: *MemCursor = @ptrCast(@alignCast(ptr));
        const idx = self.current_index orelse return firstImpl(ptr);

        const next_idx = idx + 1;
        if (next_idx >= self.table_data.count()) return null;

        self.current_index = next_idx;
        const entry = self.table_data.keys()[next_idx];
        const value = self.table_data.values()[next_idx];

        return kv.Cursor.Entry{
            .key = entry,
            .value = value,
        };
    }

    fn prevImpl(ptr: *anyopaque) !?kv.Cursor.Entry {
        const self: *MemCursor = @ptrCast(@alignCast(ptr));
        const idx = self.current_index orelse return null;

        if (idx == 0) return null;

        const prev_idx = idx - 1;
        self.current_index = prev_idx;
        const entry = self.table_data.keys()[prev_idx];
        const value = self.table_data.values()[prev_idx];

        return kv.Cursor.Entry{
            .key = entry,
            .value = value,
        };
    }

    fn seekImpl(ptr: *anyopaque, key: []const u8) !?kv.Cursor.Entry {
        const self: *MemCursor = @ptrCast(@alignCast(ptr));

        // Linear search (would be binary search in real MDBX)
        const keys = self.table_data.keys();
        for (keys, 0..) |k, i| {
            if (std.mem.eql(u8, k, key) or std.mem.order(u8, k, key) == .gt) {
                self.current_index = i;
                return kv.Cursor.Entry{
                    .key = k,
                    .value = self.table_data.values()[i],
                };
            }
        }

        return null;
    }

    fn currentImpl(ptr: *anyopaque) !?kv.Cursor.Entry {
        const self: *MemCursor = @ptrCast(@alignCast(ptr));
        const idx = self.current_index orelse return null;

        if (idx >= self.table_data.count()) return null;

        return kv.Cursor.Entry{
            .key = self.table_data.keys()[idx],
            .value = self.table_data.values()[idx],
        };
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *MemCursor = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

test "memdb basic operations" {
    const db = try MemDb.init(std.testing.allocator);
    defer db.deinit();

    var tx = try db.asDatabase().beginTx(true);
    defer tx.commit() catch {};

    try tx.put(.Headers, "key1", "value1");
    const value = try tx.get(.Headers, "key1");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("value1", value.?);
}

test "memdb cursor iteration" {
    const db = try MemDb.init(std.testing.allocator);
    defer db.deinit();

    var tx = try db.asDatabase().beginTx(true);
    defer tx.commit() catch {};

    try tx.put(.Headers, "key1", "value1");
    try tx.put(.Headers, "key2", "value2");
    try tx.put(.Headers, "key3", "value3");

    var cursor = try tx.cursor(.Headers);
    defer cursor.close();

    var entry = try cursor.first();
    try std.testing.expect(entry != null);

    var count: usize = 0;
    while (entry != null) : (entry = try cursor.next()) {
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), count);
}

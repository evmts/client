//! Key-Value database interface matching Erigon's kv abstraction
//! Provides a unified interface over MDBX (or in-memory for testing)

const std = @import("std");
const tables = @import("tables.zig");

pub const KvError = error{
    DatabaseClosed,
    TransactionClosed,
    KeyNotFound,
    DuplicateKey,
    InvalidCursor,
    ReadOnlyTransaction,
    OutOfMemory,
};

/// Cursor order for iteration
pub const CursorOrder = enum {
    forward,
    reverse,
};

/// Database interface
pub const Database = struct {
    vtable: *const VTable,
    ptr: *anyopaque,

    pub const VTable = struct {
        beginTx: *const fn (ptr: *anyopaque, writable: bool) anyerror!*Transaction,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn beginTx(self: Database, writable: bool) !*Transaction {
        return self.vtable.beginTx(self.ptr, writable);
    }

    pub fn close(self: Database) void {
        self.vtable.close(self.ptr);
    }
};

/// Transaction interface (Read-only or Read-Write)
pub const Transaction = struct {
    vtable: *const VTable,
    ptr: *anyopaque,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, table: tables.Table, key: []const u8) anyerror!?[]const u8,
        put: *const fn (ptr: *anyopaque, table: tables.Table, key: []const u8, value: []const u8) anyerror!void,
        delete: *const fn (ptr: *anyopaque, table: tables.Table, key: []const u8) anyerror!void,
        cursor: *const fn (ptr: *anyopaque, table: tables.Table) anyerror!*Cursor,
        commit: *const fn (ptr: *anyopaque) anyerror!void,
        rollback: *const fn (ptr: *anyopaque) void,
    };

    pub fn get(self: *Transaction, table: tables.Table, key: []const u8) !?[]const u8 {
        return self.vtable.get(self.ptr, table, key);
    }

    pub fn put(self: *Transaction, table: tables.Table, key: []const u8, value: []const u8) !void {
        return self.vtable.put(self.ptr, table, key, value);
    }

    pub fn delete(self: *Transaction, table: tables.Table, key: []const u8) !void {
        return self.vtable.delete(self.ptr, table, key);
    }

    pub fn cursor(self: *Transaction, table: tables.Table) !*Cursor {
        return self.vtable.cursor(self.ptr, table);
    }

    pub fn commit(self: *Transaction) !void {
        return self.vtable.commit(self.ptr);
    }

    pub fn rollback(self: *Transaction) void {
        self.vtable.rollback(self.ptr);
    }

    /// Helper: Get u64 value
    pub fn getU64(self: *Transaction, table: tables.Table, key: []const u8) !?u64 {
        const value = try self.get(table, key) orelse return null;
        if (value.len != 8) return error.InvalidValueLength;
        return std.mem.readInt(u64, value[0..8], .big);
    }

    /// Helper: Put u64 value
    pub fn putU64(self: *Transaction, table: tables.Table, key: []const u8, value: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .big);
        try self.put(table, key, &buf);
    }
};

/// Cursor for iterating over table entries
pub const Cursor = struct {
    vtable: *const VTable,
    ptr: *anyopaque,

    pub const VTable = struct {
        first: *const fn (ptr: *anyopaque) anyerror!?Entry,
        last: *const fn (ptr: *anyopaque) anyerror!?Entry,
        next: *const fn (ptr: *anyopaque) anyerror!?Entry,
        prev: *const fn (ptr: *anyopaque) anyerror!?Entry,
        seek: *const fn (ptr: *anyopaque, key: []const u8) anyerror!?Entry,
        current: *const fn (ptr: *anyopaque) anyerror!?Entry,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn first(self: *Cursor) !?Entry {
        return self.vtable.first(self.ptr);
    }

    pub fn last(self: *Cursor) !?Entry {
        return self.vtable.last(self.ptr);
    }

    pub fn next(self: *Cursor) !?Entry {
        return self.vtable.next(self.ptr);
    }

    pub fn prev(self: *Cursor) !?Entry {
        return self.vtable.prev(self.ptr);
    }

    pub fn seek(self: *Cursor, key: []const u8) !?Entry {
        return self.vtable.seek(self.ptr, key);
    }

    pub fn current(self: *Cursor) !?Entry {
        return self.vtable.current(self.ptr);
    }

    pub fn close(self: *Cursor) void {
        self.vtable.close(self.ptr);
    }
};

/// Batch write operation
pub const Batch = struct {
    operations: std.ArrayList(Operation),
    allocator: std.mem.Allocator,

    const Operation = struct {
        op_type: enum { put, delete },
        table: tables.Table,
        key: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Batch {
        return .{
            .operations = std.ArrayList(Operation).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Batch) void {
        self.operations.deinit(self.allocator);
    }

    pub fn put(self: *Batch, table: tables.Table, key: []const u8, value: []const u8) !void {
        try self.operations.append(self.allocator, .{
            .op_type = .put,
            .table = table,
            .key = key,
            .value = value,
        });
    }

    pub fn delete(self: *Batch, table: tables.Table, key: []const u8) !void {
        try self.operations.append(self.allocator, .{
            .op_type = .delete,
            .table = table,
            .key = key,
            .value = &[_]u8{},
        });
    }

    pub fn commit(self: *Batch, tx: *Transaction) !void {
        for (self.operations.items) |op| {
            switch (op.op_type) {
                .put => try tx.put(op.table, op.key, op.value),
                .delete => try tx.delete(op.table, op.key),
            }
        }
    }
};

// Zig bindings for libmdbx C API
//! MDBX is a fast, compact, embedded key-value database
//! See: https://libmdbx.dqdkfa.ru

const c = @cImport({
    @cInclude("mdbx.h");
});

// Re-export C types and functions with cleaner names
pub const Env = c.MDBX_env;
pub const Txn = c.MDBX_txn;
pub const Dbi = c.MDBX_dbi;
pub const Cursor = c.MDBX_cursor;

pub const Val = c.MDBX_val;

// Environment flags
pub const EnvFlags = struct {
    pub const NOSUBDIR = c.MDBX_NOSUBDIR;
    pub const RDONLY = c.MDBX_RDONLY;
    pub const EXCLUSIVE = c.MDBX_EXCLUSIVE;
    pub const ACCEDE = c.MDBX_ACCEDE;
    pub const WRITEMAP = c.MDBX_WRITEMAP;
    pub const NOTLS = c.MDBX_NOTLS;
    pub const NORDAHEAD = c.MDBX_NORDAHEAD;
    pub const NOMEMINIT = c.MDBX_NOMEMINIT;
    pub const COALESCE = c.MDBX_COALESCE;
    pub const LIFORECLAIM = c.MDBX_LIFORECLAIM;
    pub const PAGEPERTURB = c.MDBX_PAGEPERTURB;
};

// Transaction flags
pub const TxnFlags = struct {
    pub const READWRITE = @as(c_uint, 0);
    pub const RDONLY = c.MDBX_TXN_RDONLY;
    pub const TRY = c.MDBX_TXN_TRY;
    pub const NOMETASYNC = c.MDBX_TXN_NOMETASYNC;
    pub const NOSYNC = c.MDBX_TXN_NOSYNC;
};

// Database flags
pub const DbiFlags = struct {
    pub const NONE = @as(c_uint, 0);
    pub const REVERSEKEY = c.MDBX_REVERSEKEY;
    pub const DUPSORT = c.MDBX_DUPSORT;
    pub const INTEGERKEY = c.MDBX_INTEGERKEY;
    pub const DUPFIXED = c.MDBX_DUPFIXED;
    pub const INTEGERDUP = c.MDBX_INTEGERDUP;
    pub const REVERSEDUP = c.MDBX_REVERSEDUP;
    pub const CREATE = c.MDBX_CREATE;
};

// Cursor operations
pub const CursorOp = struct {
    pub const FIRST = c.MDBX_FIRST;
    pub const LAST = c.MDBX_LAST;
    pub const NEXT = c.MDBX_NEXT;
    pub const PREV = c.MDBX_PREV;
    pub const SET = c.MDBX_SET;
    pub const SET_KEY = c.MDBX_SET_KEY;
    pub const SET_RANGE = c.MDBX_SET_RANGE;
    pub const GET_CURRENT = c.MDBX_GET_CURRENT;
};

// Error codes
pub const Error = error{
    KeyExist,
    NotFound,
    PageNotFound,
    Corrupted,
    Panic,
    VersionMismatch,
    Invalid,
    MapFull,
    DbsFull,
    ReadersFull,
    TxnFull,
    CursorFull,
    PageFull,
    UnableExtendMapsize,
    Incompatible,
    BadRslot,
    BadTxn,
    BadValsize,
    BadDbi,
    Problem,
    Busy,
    Multival,
    Ebadsign,
    Wanna,
    Ekeymismatch,
    TooLarge,
    EmultivalMismatch,
    UnknownError,
};

// Convert MDBX error code to Zig error
pub fn checkError(rc: c_int) Error!void {
    return switch (rc) {
        c.MDBX_SUCCESS => {},
        c.MDBX_KEYEXIST => Error.KeyExist,
        c.MDBX_NOTFOUND => Error.NotFound,
        c.MDBX_PAGE_NOTFOUND => Error.PageNotFound,
        c.MDBX_CORRUPTED => Error.Corrupted,
        c.MDBX_PANIC => Error.Panic,
        c.MDBX_VERSION_MISMATCH => Error.VersionMismatch,
        c.MDBX_INVALID => Error.Invalid,
        c.MDBX_MAP_FULL => Error.MapFull,
        c.MDBX_DBS_FULL => Error.DbsFull,
        c.MDBX_READERS_FULL => Error.ReadersFull,
        c.MDBX_TXN_FULL => Error.TxnFull,
        c.MDBX_CURSOR_FULL => Error.CursorFull,
        c.MDBX_PAGE_FULL => Error.PageFull,
        c.MDBX_UNABLE_EXTEND_MAPSIZE => Error.UnableExtendMapsize,
        c.MDBX_INCOMPATIBLE => Error.Incompatible,
        c.MDBX_BAD_RSLOT => Error.BadRslot,
        c.MDBX_BAD_TXN => Error.BadTxn,
        c.MDBX_BAD_VALSIZE => Error.BadValsize,
        c.MDBX_BAD_DBI => Error.BadDbi,
        c.MDBX_PROBLEM => Error.Problem,
        c.MDBX_BUSY => Error.Busy,
        c.MDBX_MULTIVAL => Error.Multival,
        c.MDBX_EBADSIGN => Error.Ebadsign,
        c.MDBX_WANNA_RECOVERY => Error.Wanna,
        c.MDBX_EKEYMISMATCH => Error.Ekeymismatch,
        c.MDBX_TOO_LARGE => Error.TooLarge,
        c.MDBX_EMULTIVAL_MISMATCH => Error.EmultivalMismatch,
        else => Error.UnknownError,
    };
}

// Environment functions
pub const env_create = c.mdbx_env_create;
pub const env_open = c.mdbx_env_open;
pub const env_close = c.mdbx_env_close;
pub const env_set_geometry = c.mdbx_env_set_geometry;
pub const env_set_maxdbs = c.mdbx_env_set_maxdbs;
pub const env_sync = c.mdbx_env_sync;

// Transaction functions
pub const txn_begin = c.mdbx_txn_begin;
pub const txn_commit = c.mdbx_txn_commit;
pub const txn_abort = c.mdbx_txn_abort;
pub const txn_env = c.mdbx_txn_env;

// Database functions
pub const dbi_open = c.mdbx_dbi_open;
pub const dbi_close = c.mdbx_dbi_close;

// Data access functions
pub const get = c.mdbx_get;
pub const put = c.mdbx_put;
pub const del = c.mdbx_del;

// Cursor functions
pub const cursor_open = c.mdbx_cursor_open;
pub const cursor_close = c.mdbx_cursor_close;
pub const cursor_get = c.mdbx_cursor_get;
pub const cursor_put = c.mdbx_cursor_put;
pub const cursor_del = c.mdbx_cursor_del;

// Utility functions
pub const strerror = c.mdbx_strerror;

// Helper to create MDBX_val from Zig slice
pub fn valFromSlice(slice: []const u8) Val {
    return Val{
        .iov_base = @constCast(@ptrCast(slice.ptr)),
        .iov_len = slice.len,
    };
}

// Helper to convert MDBX_val to Zig slice
pub fn sliceFromVal(val: Val) []const u8 {
    return @as([*]const u8, @ptrCast(val.iov_base))[0..val.iov_len];
}

// Statistics and info functions
pub const env_info = c.mdbx_env_info;
pub const env_stat = c.mdbx_env_stat;
pub const txn_info = c.mdbx_txn_info;

// Additional cursor operations
pub const NEXT_DUP = c.MDBX_NEXT_DUP;
pub const NEXT_NODUP = c.MDBX_NEXT_NODUP;
pub const PREV_DUP = c.MDBX_PREV_DUP;
pub const PREV_NODUP = c.MDBX_PREV_NODUP;
pub const FIRST_DUP = c.MDBX_FIRST_DUP;
pub const LAST_DUP = c.MDBX_LAST_DUP;
pub const GET_BOTH = c.MDBX_GET_BOTH;
pub const GET_BOTH_RANGE = c.MDBX_GET_BOTH_RANGE;

// Put flags
pub const PutFlags = struct {
    pub const UPSERT = @as(c_uint, 0);
    pub const NOOVERWRITE = c.MDBX_NOOVERWRITE;
    pub const NODUPDATA = c.MDBX_NODUPDATA;
    pub const CURRENT = c.MDBX_CURRENT;
    pub const ALLDUPS = c.MDBX_ALLDUPS;
    pub const RESERVE = c.MDBX_RESERVE;
    pub const APPEND = c.MDBX_APPEND;
    pub const APPENDDUP = c.MDBX_APPENDDUP;
    pub const MULTIPLE = c.MDBX_MULTIPLE;
};

// Environment geometry
pub fn setGeometry(env: *Env, size_lower: i64, size_now: i64, size_upper: i64, growth_step: i64, shrink_threshold: i64, pagesize: i64) Error!void {
    const rc = c.mdbx_env_set_geometry(env, size_lower, size_now, size_upper, growth_step, shrink_threshold, pagesize);
    try checkError(rc);
}

// Database comparison functions
pub const cmp = c.mdbx_cmp;
pub const dcmp = c.mdbx_dcmp;

// Reader list functions
pub const reader_list = c.mdbx_reader_list;
pub const reader_check = c.mdbx_reader_check;

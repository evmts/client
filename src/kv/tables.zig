//! Database table definitions matching Erigon's schema
//! Based on erigon-lib/kv/tables.go

const std = @import("std");

/// Database table names
pub const Table = enum {
    // Block chain tables
    Headers,
    HeaderNumbers,
    CanonicalHashes,
    HeadersSnapshotInfo,
    BodiesSnapshotInfo,
    StateSnapshotInfo,
    Bodies,
    BlockReceipts,
    Senders,
    HeadBlockHash,
    HeadHeaderHash,
    LastForkchoice,
    SafeBlockHash,
    FinalizedBlockHash,

    // Transaction tables
    Transactions,
    TransactionLookup,
    MaxTransactionID,

    // State tables
    PlainState,
    PlainContractCode,
    ContractCode,
    IncarnationMap,
    Code,
    TrieOfAccounts,
    TrieOfStorage,
    HashedAccounts,
    HashedStorage,

    // History and indices
    AccountsHistory,
    StorageHistory,
    CodeHistory,
    LogAddressIndex,
    LogTopicIndex,
    CallTraceSet,
    CallFromIndex,
    CallToIndex,
    Receipts,
    Log,

    // Snapshots
    SnapshotInfo,
    BorReceipts,

    // Sync metadata
    SyncStageProgress,
    SyncStageUnwind,
    Migrations,
    Sequence,

    // Configuration
    DatabaseInfo,
    ConfigHistory,

    // Clique consensus
    CliqueSeparate,
    CliqueSnapshot,
    CliqueLastSnapshot,

    // Additional indices
    TxLookup,
    BloomBits,
    PreImages,

    // Account change sets (deprecated in Erigon3)
    PlainAccountChangeSet,
    PlainStorageChangeSet,

    pub fn toString(self: Table) []const u8 {
        return switch (self) {
            .Headers => "Header",
            .HeaderNumbers => "HeaderNumber",
            .CanonicalHashes => "CanonicalHeader",
            .HeadersSnapshotInfo => "HeadersSnapshotInfo",
            .BodiesSnapshotInfo => "BodiesSnapshotInfo",
            .StateSnapshotInfo => "StateSnapshotInfo",
            .Bodies => "BlockBody",
            .BlockReceipts => "Receipt",
            .Senders => "TxSender",
            .HeadBlockHash => "LastBlock",
            .HeadHeaderHash => "LastHeader",
            .LastForkchoice => "LastForkchoice",
            .SafeBlockHash => "SafeBlock",
            .FinalizedBlockHash => "FinalizedBlock",
            .Transactions => "BlockTransaction",
            .TransactionLookup => "TransactionLookup",
            .MaxTransactionID => "MaxTxID",
            .PlainState => "PlainState",
            .PlainContractCode => "PlainCodeHash",
            .ContractCode => "Code",
            .IncarnationMap => "IncarnationMap",
            .Code => "CODE",
            .TrieOfAccounts => "TrieAccount",
            .TrieOfStorage => "TrieStorage",
            .HashedAccounts => "HashedAccount",
            .HashedStorage => "HashedStorage",
            .AccountsHistory => "AccountHistory",
            .StorageHistory => "StorageHistory",
            .CodeHistory => "CodeHistory",
            .LogAddressIndex => "LogAddressIndex",
            .LogTopicIndex => "LogTopicIndex",
            .CallTraceSet => "CallTraceSet",
            .CallFromIndex => "CallFromIndex",
            .CallToIndex => "CallToIndex",
            .Receipts => "Receipt",
            .Log => "TransactionLog",
            .SnapshotInfo => "SnapshotInfo",
            .BorReceipts => "BorReceipt",
            .SyncStageProgress => "SyncStage",
            .SyncStageUnwind => "SyncStageUnwind",
            .Migrations => "Migration",
            .Sequence => "Sequence",
            .DatabaseInfo => "DbInfo",
            .ConfigHistory => "ConfigHistory",
            .CliqueSeparate => "CliqueSeparate",
            .CliqueSnapshot => "CliqueSnapshot",
            .CliqueLastSnapshot => "CliqueLastSnapshot",
            .TxLookup => "BlockTransactionLookup",
            .BloomBits => "BloomBitsIndex",
            .PreImages => "PreImage",
            .PlainAccountChangeSet => "PlainACS",
            .PlainStorageChangeSet => "PlainSCS",
        };
    }
};

/// Key encoding utilities
pub const Encoding = struct {
    /// Encode block number as big-endian u64
    pub fn encodeBlockNumber(num: u64) [8]u8 {
        var result: [8]u8 = undefined;
        std.mem.writeInt(u64, &result, num, .big);
        return result;
    }

    /// Decode block number from big-endian u64
    pub fn decodeBlockNumber(bytes: []const u8) !u64 {
        if (bytes.len != 8) return error.InvalidKeyLength;
        return std.mem.readInt(u64, bytes[0..8], .big);
    }

    /// Encode address (20 bytes)
    pub fn encodeAddress(addr: [20]u8) [20]u8 {
        return addr;
    }

    /// Encode storage key: address (20 bytes) + incarnation (8 bytes) + location (32 bytes)
    pub fn encodeStorageKey(addr: [20]u8, incarnation: u64, location: [32]u8) [60]u8 {
        var result: [60]u8 = undefined;
        @memcpy(result[0..20], &addr);
        std.mem.writeInt(u64, result[20..28], incarnation, .big);
        @memcpy(result[28..60], &location);
        return result;
    }

    /// Composite key: blockNum + hash
    pub fn encodeBlockHash(num: u64, hash: [32]u8) [40]u8 {
        var result: [40]u8 = undefined;
        std.mem.writeInt(u64, result[0..8], num, .big);
        @memcpy(result[8..40], &hash);
        return result;
    }
};

/// Table configuration
pub const TableConfig = struct {
    name: []const u8,
    /// Whether this table has duplicate keys (DupSort in MDBX)
    dup_sort: bool,
    /// Whether values in dup_sort are fixed size
    dup_fixed: bool,
    /// Expected key size (0 = variable)
    key_size: usize,
    /// Expected value size (0 = variable)
    value_size: usize,

    pub fn get(table: Table) TableConfig {
        return switch (table) {
            .Headers => .{ .name = table.toString(), .dup_sort = false, .dup_fixed = false, .key_size = 40, .value_size = 0 },
            .HeaderNumbers => .{ .name = table.toString(), .dup_sort = false, .dup_fixed = false, .key_size = 32, .value_size = 8 },
            .CanonicalHashes => .{ .name = table.toString(), .dup_sort = false, .dup_fixed = false, .key_size = 8, .value_size = 32 },
            .Bodies => .{ .name = table.toString(), .dup_sort = false, .dup_fixed = false, .key_size = 40, .value_size = 0 },
            .BlockReceipts => .{ .name = table.toString(), .dup_sort = false, .dup_fixed = false, .key_size = 8, .value_size = 0 },
            .Senders => .{ .name = table.toString(), .dup_sort = false, .dup_fixed = false, .key_size = 40, .value_size = 0 },
            .Transactions => .{ .name = table.toString(), .dup_sort = false, .dup_fixed = false, .key_size = 8, .value_size = 0 },
            .TxLookup => .{ .name = table.toString(), .dup_sort = false, .dup_fixed = false, .key_size = 32, .value_size = 8 },
            .PlainState => .{ .name = table.toString(), .dup_sort = true, .dup_fixed = false, .key_size = 20, .value_size = 0 },
            .PlainContractCode => .{ .name = table.toString(), .dup_sort = false, .dup_fixed = false, .key_size = 20, .value_size = 32 },
            .Code => .{ .name = table.toString(), .dup_sort = false, .dup_fixed = false, .key_size = 32, .value_size = 0 },
            .AccountsHistory => .{ .name = table.toString(), .dup_sort = true, .dup_fixed = true, .key_size = 20, .value_size = 8 },
            .StorageHistory => .{ .name = table.toString(), .dup_sort = true, .dup_fixed = true, .key_size = 20, .value_size = 8 },
            .SyncStageProgress => .{ .name = table.toString(), .dup_sort = false, .dup_fixed = false, .key_size = 0, .value_size = 8 },
            else => .{ .name = table.toString(), .dup_sort = false, .dup_fixed = false, .key_size = 0, .value_size = 0 },
        };
    }
};

test "encoding block number" {
    const num: u64 = 12345678;
    const encoded = Encoding.encodeBlockNumber(num);
    const decoded = try Encoding.decodeBlockNumber(&encoded);
    try std.testing.expectEqual(num, decoded);
}

test "table names" {
    try std.testing.expectEqualStrings("Header", Table.Headers.toString());
    try std.testing.expectEqualStrings("PlainState", Table.PlainState.toString());
}

//! Transaction types
//! Port of erigon/execution/types/transaction.go

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const Hash = primitives.Hash;
const U256 = primitives.U256;

const common_mod = @import("common.zig");
pub const TxType = common_mod.TxType;
pub const TxError = common_mod.TxError;
pub const AccessList = common_mod.AccessList;
pub const AccessTuple = common_mod.AccessTuple;
pub const Authorization = common_mod.Authorization;
pub const CommonTx = common_mod.CommonTx;

const LegacyTx = @import("legacy.zig").LegacyTx;
// TODO: Import other transaction types as they're implemented
// const AccessListTx = @import("access_list.zig").AccessListTx;
// const DynamicFeeTx = @import("dynamic_fee.zig").DynamicFeeTx;
// const BlobTx = @import("blob.zig").BlobTx;
// const SetCodeTx = @import("set_code.zig").SetCodeTx;

/// Main transaction type (tagged union)
pub const Transaction = union(TxType) {
    legacy: LegacyTx,
    // TODO: Add other transaction types
    // access_list: AccessListTx,
    // dynamic_fee: DynamicFeeTx,
    // blob: BlobTx,
    // set_code: SetCodeTx,
    // account_abstraction: AATx,

    /// Get transaction type byte
    pub fn txType(self: Transaction) u8 {
        return switch (self) {
            .legacy => 0,
            // .access_list => 1,
            // .dynamic_fee => 2,
            // .blob => 3,
            // .set_code => 4,
            // .account_abstraction => 5,
        };
    }

    /// Get nonce
    pub fn getNonce(self: Transaction) u64 {
        return switch (self) {
            inline else => |tx| tx.getNonce(),
        };
    }

    /// Get gas limit
    pub fn getGasLimit(self: Transaction) u64 {
        return switch (self) {
            inline else => |tx| tx.getGasLimit(),
        };
    }

    /// Get gas price (for legacy and access list txs)
    pub fn getGasPrice(self: Transaction) ?U256 {
        return switch (self) {
            .legacy => |tx| tx.getGasPrice(),
            // .access_list => |tx| tx.getGasPrice(),
            // else => null,
        };
    }

    /// Get tip cap (max priority fee per gas)
    pub fn getTipCap(self: Transaction) U256 {
        return switch (self) {
            inline else => |tx| tx.getTipCap(),
        };
    }

    /// Get fee cap (max fee per gas)
    pub fn getFeeCap(self: Transaction) U256 {
        return switch (self) {
            inline else => |tx| tx.getFeeCap(),
        };
    }

    /// Get effective gas tip
    pub fn getEffectiveGasTip(self: Transaction, base_fee: ?U256) U256 {
        return switch (self) {
            inline else => |tx| tx.getEffectiveGasTip(base_fee),
        };
    }

    /// Get recipient address (null for contract creation)
    pub fn getTo(self: Transaction) ?Address {
        return switch (self) {
            inline else => |tx| tx.getTo(),
        };
    }

    /// Get transaction value
    pub fn getValue(self: Transaction) U256 {
        return switch (self) {
            inline else => |tx| tx.getValue(),
        };
    }

    /// Get transaction data/input
    pub fn getData(self: Transaction) []const u8 {
        return switch (self) {
            inline else => |tx| tx.getData(),
        };
    }

    /// Get access list (empty for legacy)
    pub fn getAccessList(self: Transaction) AccessList {
        return switch (self) {
            inline else => |tx| tx.getAccessList(),
        };
    }

    /// Get authorizations (empty except for set_code)
    pub fn getAuthorizations(self: Transaction) []const Authorization {
        return switch (self) {
            inline else => |tx| tx.getAuthorizations(),
        };
    }

    /// Get blob hashes (empty except for blob txs)
    pub fn getBlobHashes(self: Transaction) []const Hash {
        return switch (self) {
            inline else => |tx| tx.getBlobHashes(),
        };
    }

    /// Get blob gas (0 except for blob txs)
    pub fn getBlobGas(self: Transaction) u64 {
        return switch (self) {
            inline else => |tx| tx.getBlobGas(),
        };
    }

    /// Check if transaction is contract creation
    pub fn isContractCreation(self: Transaction) bool {
        return switch (self) {
            inline else => |tx| tx.isContractCreation(),
        };
    }

    /// Check if transaction is EIP-155 protected
    pub fn isProtected(self: Transaction) bool {
        return switch (self) {
            .legacy => |tx| tx.isProtected(),
            // All typed transactions are protected by default
            // else => true,
        };
    }

    /// Get chain ID
    pub fn getChainId(self: Transaction) ?U256 {
        return switch (self) {
            .legacy => |tx| tx.getChainId(),
            // .access_list => |tx| tx.chain_id,
            // .dynamic_fee => |tx| tx.chain_id,
            // .blob => |tx| tx.chain_id,
            // .set_code => |tx| tx.chain_id,
            // .account_abstraction => null,
        };
    }

    /// Get raw signature values (V, R, S)
    pub fn rawSignatureValues(self: Transaction) struct { v: U256, r: U256, s: U256 } {
        return switch (self) {
            inline else => |tx| tx.rawSignatureValues(),
        };
    }

    /// Get cached sender if available
    pub fn getSender(self: Transaction) ?Address {
        return switch (self) {
            .legacy => |tx| tx.common.getSender(),
            // .access_list => |tx| tx.common.getSender(),
            // .dynamic_fee => |tx| tx.common.getSender(),
            // .blob => |tx| tx.common.getSender(),
            // .set_code => |tx| tx.common.getSender(),
            // .account_abstraction => null,
        };
    }

    /// Set sender address (after recovery)
    pub fn setSender(self: *Transaction, sender: Address) void {
        switch (self.*) {
            .legacy => |*tx| tx.common.setSender(sender),
            // .access_list => |*tx| tx.common.setSender(sender),
            // .dynamic_fee => |*tx| tx.common.setSender(sender),
            // .blob => |*tx| tx.common.setSender(sender),
            // .set_code => |*tx| tx.common.setSender(sender),
            // .account_abstraction => {},
        }
    }

    /// Calculate transaction hash
    pub fn hash(self: *Transaction, allocator: std.mem.Allocator) !Hash {
        return switch (self.*) {
            .legacy => |*tx| try tx.hash(allocator),
            // TODO: Implement for other types
        };
    }

    /// Calculate signing hash
    pub fn signingHash(self: Transaction, allocator: std.mem.Allocator, chain_id: ?U256) !Hash {
        return switch (self) {
            .legacy => |tx| try tx.signingHash(allocator, chain_id),
            // TODO: Implement for other types
        };
    }

    /// Clone transaction
    pub fn clone(self: Transaction, allocator: std.mem.Allocator) !Transaction {
        return switch (self) {
            .legacy => |tx| .{ .legacy = try tx.clone(allocator) },
            // TODO: Implement for other types
        };
    }

    /// Free transaction memory
    pub fn deinit(self: *Transaction, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .legacy => |*tx| tx.deinit(allocator),
            // TODO: Implement for other types
        }
    }

    /// Decode transaction from RLP bytes
    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Transaction {
        if (data.len == 0) {
            return error.InvalidRlpData;
        }

        // Check first byte to determine transaction type
        if (data[0] < 0x80) {
            // EIP-2718 typed transaction
            const tx_type = try TxType.fromByte(data[0]);
            _ = tx_type;
            // TODO: Decode typed transactions
            return error.TxTypeNotSupported;
        } else {
            // Legacy transaction (RLP encoded)
            // TODO: Implement RLP decoder
            _ = allocator;
            return error.TxTypeNotSupported;
        }
    }

    /// Encode transaction to RLP bytes
    pub fn encode(self: Transaction, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .legacy => |tx| try tx.encodeRlp(allocator),
            // TODO: Implement for other types
        };
    }
};

// Tests
test "Transaction - legacy type" {
    const testing = std.testing;

    var legacy = LegacyTx.init();
    legacy.common.nonce = 5;

    const tx = Transaction{ .legacy = legacy };

    try testing.expectEqual(@as(u8, 0), tx.txType());
    try testing.expectEqual(@as(u64, 5), tx.getNonce());
    try testing.expect(tx.isContractCreation());
}

test "Transaction - sender caching" {
    const testing = std.testing;

    var tx = Transaction{ .legacy = LegacyTx.init() };

    try testing.expectEqual(@as(?Address, null), tx.getSender());

    const sender = Address.zero();
    tx.setSender(sender);
    try testing.expectEqual(sender, tx.getSender().?);
}

test "Transaction - clone" {
    const testing = std.testing;

    var legacy = LegacyTx.init();
    legacy.common.nonce = 10;
    const data = try testing.allocator.dupe(u8, "test");
    legacy.common.data = data;

    const tx = Transaction{ .legacy = legacy };
    const cloned = try tx.clone(testing.allocator);
    defer {
        var mut_cloned = cloned;
        mut_cloned.deinit(testing.allocator);
    }

    try testing.expectEqual(tx.getNonce(), cloned.getNonce());

    // Clean up original
    testing.allocator.free(data);
}

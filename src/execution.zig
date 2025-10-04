//! Transaction execution and state transition
//! Based on Erigon's core/state_transition.go
//!
//! The State Transitioning Model:
//! 1) Nonce handling
//! 2) Pre pay gas
//! 3) Create a new state object if the recipient is \0*32
//! 4) Value transfer
//! 5) Run Script section (EVM execution)
//! 6) Derive new state root

const std = @import("std");
const primitives = @import("primitives");
const chain = @import("chain.zig");
const state = @import("state.zig");
const crypto = @import("crypto.zig");

/// Execution errors matching Erigon's core/error.go
pub const ExecutionError = error{
    // Block-level errors
    KnownBlock,
    BlacklistedHash,
    NoGenesis,
    InternalFailure,
    StateTransitionFailed,
    BlockExceedsMaxRlpSize,

    // Transaction validation errors
    NonceTooLow,
    NonceTooHigh,
    NonceMax,
    GasLimitReached,
    BlobGasLimitReached,
    MaxInitCodeSizeExceeded,
    InsufficientFunds,
    GasUintOverflow,
    IntrinsicGas,
    TxTypeNotSupported,
    FeeCapTooLow,
    SenderNoEOA,
    GasLimitTooHigh,

    // EIP-1559 errors
    TipAboveFeeCap,
    TipVeryHigh,
    FeeCapVeryHigh,

    // EIP-4844 (blob) errors
    MaxFeePerBlobGasTooLow,
    TooManyBlobs,

    // Generic errors
    InvalidTransaction,
    OutOfGas,
};

/// Gas pool manages the block-level gas limit
pub const GasPool = struct {
    gas: u64,
    blob_gas: u64,

    pub fn init(block_gas_limit: u64, blob_gas_limit: u64) GasPool {
        return .{
            .gas = block_gas_limit,
            .blob_gas = blob_gas_limit,
        };
    }

    pub fn subGas(self: *GasPool, amount: u64) !void {
        if (amount > self.gas) {
            return ExecutionError.GasLimitReached;
        }
        self.gas -= amount;
    }

    pub fn subBlobGas(self: *GasPool, amount: u64) !void {
        if (amount > self.blob_gas) {
            return ExecutionError.BlobGasLimitReached;
        }
        self.blob_gas -= amount;
    }

    pub fn addGas(self: *GasPool, amount: u64) void {
        self.gas +|= amount; // Saturating add
    }

    pub fn reset(self: *GasPool, gas: u64, blob_gas: u64) void {
        self.gas = gas;
        self.blob_gas = blob_gas;
    }
};

/// Message interface for transaction execution
pub const Message = struct {
    from: primitives.Address,
    to: ?primitives.Address,

    // Gas fields
    gas: u64,
    gas_price: u256,
    fee_cap: u256,
    tip_cap: u256,

    // Blob fields (EIP-4844)
    blob_gas: u64,
    max_fee_per_blob_gas: u256,
    blob_hashes: []const [32]u8,

    // Transaction data
    value: u256,
    nonce: u64,
    data: []const u8,

    // Access list (EIP-2930)
    access_list: []const chain.AccessListEntry,

    // Authorization list (EIP-7702)
    authorizations: []const chain.Authorization,

    // Flags
    check_nonce: bool,
    check_gas: bool,
    is_free: bool, // Service transactions (Gnosis)

    pub fn init(tx: *const chain.Transaction, from: primitives.Address) Message {
        return .{
            .from = from,
            .to = tx.to,
            .gas = tx.gas_limit,
            .gas_price = tx.gasPrice(),
            .fee_cap = tx.maxFeePerGas(),
            .tip_cap = tx.maxPriorityFeePerGas(),
            .blob_gas = tx.blobGas(),
            .max_fee_per_blob_gas = tx.maxFeePerBlobGas(),
            .blob_hashes = tx.blobVersionedHashes(),
            .value = tx.value,
            .nonce = tx.nonce,
            .data = tx.data,
            .access_list = tx.accessList(),
            .authorizations = tx.authorizationList(),
            .check_nonce = true,
            .check_gas = true,
            .is_free = false,
        };
    }

    pub fn setIsFree(self: *Message, free: bool) void {
        self.is_free = free;
    }
};

/// Execution result
pub const ExecutionResult = struct {
    return_data: []const u8,
    gas_used: u64,
    gas_refund: u64,
    failed: bool,
    error_message: ?[]const u8,

    // Fee accounting (for parallel execution)
    burnt_fee: u256,
    tip_fee: u256,

    pub fn success(return_data: []const u8, gas_used: u64, gas_refund: u64) ExecutionResult {
        return .{
            .return_data = return_data,
            .gas_used = gas_used,
            .gas_refund = gas_refund,
            .failed = false,
            .error_message = null,
            .burnt_fee = 0,
            .tip_fee = 0,
        };
    }

    pub fn failure(error_message: []const u8, gas_used: u64) ExecutionResult {
        return .{
            .return_data = &.{},
            .gas_used = gas_used,
            .gas_refund = 0,
            .failed = true,
            .error_message = error_message,
            .burnt_fee = 0,
            .tip_fee = 0,
        };
    }
};

/// State transition manages the execution of a single transaction
pub const StateTransition = struct {
    gp: *GasPool,
    msg: Message,
    gas_remaining: u64,
    initial_gas: u64,
    ibs: *state.IntraBlockState,

    // Block context
    block_number: u64,
    block_timestamp: u64,
    block_base_fee: u256,
    block_blob_base_fee: ?u256,
    coinbase: primitives.Address,

    // Chain configuration
    chain_id: u64,
    is_london: bool,
    is_cancun: bool,
    is_osaka: bool,

    // Flags
    no_fee_burn_and_tip: bool,

    pub fn init(
        gp: *GasPool,
        msg: Message,
        ibs: *state.IntraBlockState,
        block_context: BlockContext,
        chain_config: ChainConfig,
    ) StateTransition {
        return .{
            .gp = gp,
            .msg = msg,
            .gas_remaining = 0,
            .initial_gas = 0,
            .ibs = ibs,
            .block_number = block_context.block_number,
            .block_timestamp = block_context.timestamp,
            .block_base_fee = block_context.base_fee,
            .block_blob_base_fee = block_context.blob_base_fee,
            .coinbase = block_context.coinbase,
            .chain_id = chain_config.chain_id,
            .is_london = chain_config.is_london,
            .is_cancun = chain_config.is_cancun,
            .is_osaka = chain_config.is_osaka,
            .no_fee_burn_and_tip = false,
        };
    }

    /// Pre-transaction validation
    /// DESCRIBED: docs/programmers_guide/guide.md#nonce in Erigon
    fn preCheck(self: *StateTransition, gas_bailout: bool) !void {
        // EIP-7825: Check max blobs per transaction (Osaka)
        const max_blobs_per_txn: usize = 6;
        if (self.is_osaka and self.msg.blob_hashes.len > max_blobs_per_txn) {
            return ExecutionError.TooManyBlobs;
        }

        // Nonce validation
        if (self.msg.check_nonce) {
            const state_nonce = try self.ibs.getNonce(self.msg.from);
            const msg_nonce = self.msg.nonce;

            if (state_nonce < msg_nonce) {
                return ExecutionError.NonceTooHigh;
            } else if (state_nonce > msg_nonce) {
                return ExecutionError.NonceTooLow;
            } else if (state_nonce == std.math.maxInt(u64)) {
                return ExecutionError.NonceMax;
            }

            // EIP-3607: Reject transactions from senders with deployed code
            const code_hash = try self.ibs.getCodeHash(self.msg.from);
            const empty_hash = [_]u8{0xc5} ++ [_]u8{0xd2} ** 31; // keccak256("")

            if (!std.mem.eql(u8, &code_hash, &empty_hash) and
                !std.mem.eql(u8, &code_hash, &([_]u8{0} ** 32))) {
                // Check for EIP-7702 delegated designation
                const has_delegation = try self.ibs.hasDelegatedDesignation(self.msg.from);
                if (!has_delegation) {
                    return ExecutionError.SenderNoEOA;
                }
            }
        }

        // EIP-1559: Validate fee cap and tip
        if (self.is_london) {
            const skip_check = self.msg.fee_cap == 0 and self.msg.tip_cap == 0;
            if (!skip_check) {
                if (self.msg.fee_cap < self.msg.tip_cap) {
                    return ExecutionError.TipAboveFeeCap;
                }
                if (self.block_base_fee > 0 and self.msg.fee_cap < self.block_base_fee and !self.msg.is_free) {
                    return ExecutionError.FeeCapTooLow;
                }
            }
        }

        // EIP-4844: Validate blob gas pricing
        if (self.msg.blob_gas > 0 and self.is_cancun) {
            const blob_gas_price = self.block_blob_base_fee orelse return ExecutionError.InternalFailure;
            if (blob_gas_price > self.msg.max_fee_per_blob_gas) {
                return ExecutionError.MaxFeePerBlobGasTooLow;
            }
        }

        // EIP-7825: Transaction gas limit cap (Osaka)
        const max_txn_gas_limit: u64 = 30_000_000;
        if (self.msg.check_gas and self.is_osaka and self.msg.gas > max_txn_gas_limit) {
            return ExecutionError.GasLimitTooHigh;
        }

        try self.buyGas(gas_bailout);
    }

    /// Deduct gas cost from sender balance
    fn buyGas(self: *StateTransition, gas_bailout: bool) !void {
        // Calculate total gas cost
        var gas_val: u256 = self.msg.gas;
        gas_val = gas_val * self.msg.gas_price;

        // Calculate blob gas cost (EIP-4844)
        var blob_gas_val: u256 = 0;
        if (self.is_cancun) {
            const blob_gas_price = self.block_blob_base_fee orelse return ExecutionError.InternalFailure;
            blob_gas_val = self.msg.blob_gas * blob_gas_price;
            try self.gp.subBlobGas(self.msg.blob_gas);
        }

        if (!gas_bailout) {
            var balance_check = gas_val;

            // For EIP-1559, check against fee cap
            if (self.msg.fee_cap > 0) {
                balance_check = self.msg.gas * self.msg.fee_cap;
                balance_check = balance_check + self.msg.value;

                if (self.is_cancun) {
                    const max_blob_fee = self.msg.max_fee_per_blob_gas * self.msg.blob_gas;
                    balance_check = balance_check + max_blob_fee;
                }
            }

            const balance = try self.ibs.getBalance(self.msg.from);
            if (balance < balance_check) {
                return ExecutionError.InsufficientFunds;
            }

            // Deduct gas cost from sender
            try self.ibs.subBalance(self.msg.from, gas_val);
            try self.ibs.subBalance(self.msg.from, blob_gas_val);
        }

        try self.gp.subGas(self.msg.gas);
        self.gas_remaining = self.msg.gas;
        self.initial_gas = self.msg.gas;
    }

    /// Execute the transaction
    pub fn transitionDb(self: *StateTransition, refunds: bool, gas_bailout: bool) !ExecutionResult {
        // Snapshot state for rollback
        const snapshot = self.ibs.snapshot();
        errdefer self.ibs.revertToSnapshot(snapshot);

        // Pre-flight checks
        try self.preCheck(gas_bailout);

        // Increment nonce
        if (self.msg.check_nonce) {
            try self.ibs.setNonce(self.msg.from, self.msg.nonce + 1);
        }

        // TODO: Integrate with guillotine EVM for actual execution
        // For now, return success with no execution

        const result = ExecutionResult.success(&.{}, self.initial_gas - self.gas_remaining, 0);

        return result;
    }
};

/// Block context for execution
pub const BlockContext = struct {
    block_number: u64,
    timestamp: u64,
    base_fee: u256,
    blob_base_fee: ?u256,
    coinbase: primitives.Address,
    difficulty: u256,
    gas_limit: u64,
};

/// Chain configuration
pub const ChainConfig = struct {
    chain_id: u64,
    is_london: bool,
    is_cancun: bool,
    is_osaka: bool,
};

test "gas pool management" {
    var gp = GasPool.init(30_000_000, 786_432);

    try gp.subGas(21_000);
    try std.testing.expectEqual(@as(u64, 30_000_000 - 21_000), gp.gas);

    try gp.subBlobGas(131_072);
    try std.testing.expectEqual(@as(u64, 786_432 - 131_072), gp.blob_gas);

    // Test overflow
    try std.testing.expectError(ExecutionError.OutOfGas, gp.subGas(50_000_000));
}

test "message initialization" {
    var tx = chain.Transaction{
        .nonce = 1,
        .gas_limit = 21000,
        .to = null,
        .value = 1000,
        .data = &.{},
        .tx_type = .Legacy,
        .chain_id = 1,
        .gas_price = 20_000_000_000,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
        .access_list = &.{},
        .max_fee_per_gas = 0,
        .max_priority_fee_per_gas = 0,
        .blob_versioned_hashes = &.{},
        .max_fee_per_blob_gas = 0,
        .authorization_list = &.{},
    };

    var from_addr: primitives.Address = undefined;
    @memset(&from_addr.bytes, 0x01);

    const msg = Message.init(&tx, from_addr);
    try std.testing.expectEqual(@as(u64, 1), msg.nonce);
    try std.testing.expectEqual(@as(u64, 21000), msg.gas);
}

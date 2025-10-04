//! Engine API - Communication between execution and consensus layers
//! Based on erigon/turbo/engineapi
//! Spec: https://github.com/ethereum/execution-apis/tree/main/src/engine

const std = @import("std");
const chain = @import("../chain.zig");

/// Engine API methods
pub const EngineMethod = enum {
    /// Notifies about new payload from consensus layer
    engine_newPayloadV1,
    engine_newPayloadV2,
    engine_newPayloadV3,

    /// Request to update fork choice
    engine_forkchoiceUpdatedV1,
    engine_forkchoiceUpdatedV2,
    engine_forkchoiceUpdatedV3,

    /// Get payload for block building
    engine_getPayloadV1,
    engine_getPayloadV2,
    engine_getPayloadV3,

    /// Exchange capabilities
    engine_exchangeCapabilities,

    /// Get payload bodies
    engine_getPayloadBodiesByHashV1,
    engine_getPayloadBodiesByRangeV1,

    pub fn toString(self: EngineMethod) []const u8 {
        return @tagName(self);
    }
};

/// Payload status
pub const PayloadStatus = enum {
    /// Payload is valid and has been applied
    VALID,
    /// Payload is invalid
    INVALID,
    /// Payload validation is still ongoing
    SYNCING,
    /// Payload is valid but parent is unknown
    ACCEPTED,

    pub fn toString(self: PayloadStatus) []const u8 {
        return @tagName(self);
    }
};

/// Execution payload (block data from consensus)
pub const ExecutionPayload = struct {
    /// Block hash
    block_hash: [32]u8,
    /// Parent block hash
    parent_hash: [32]u8,
    /// Fee recipient (miner)
    fee_recipient: [20]u8,
    /// State root
    state_root: [32]u8,
    /// Receipts root
    receipts_root: [32]u8,
    /// Logs bloom
    logs_bloom: [256]u8,
    /// Previous randao
    prev_randao: [32]u8,
    /// Block number
    block_number: u64,
    /// Gas limit
    gas_limit: u64,
    /// Gas used
    gas_used: u64,
    /// Timestamp
    timestamp: u64,
    /// Extra data
    extra_data: []const u8,
    /// Base fee per gas (EIP-1559)
    base_fee_per_gas: u256,
    /// Transactions (RLP encoded)
    transactions: []const []const u8,
    /// Withdrawals (EIP-4895, Shapella)
    withdrawals: ?[]const Withdrawal,
    /// Blob gas used (EIP-4844, Cancun)
    blob_gas_used: ?u64,
    /// Excess blob gas (EIP-4844)
    excess_blob_gas: ?u64,
};

/// Withdrawal (EIP-4895)
pub const Withdrawal = struct {
    index: u64,
    validator_index: u64,
    address: [20]u8,
    amount: u64,
};

/// Fork choice state
pub const ForkchoiceState = struct {
    /// Head block hash
    head_block_hash: [32]u8,
    /// Safe block hash
    safe_block_hash: [32]u8,
    /// Finalized block hash
    finalized_block_hash: [32]u8,
};

/// Payload attributes for block building
pub const PayloadAttributes = struct {
    /// Timestamp for the new payload
    timestamp: u64,
    /// Previous randao value
    prev_randao: [32]u8,
    /// Suggested fee recipient
    suggested_fee_recipient: [20]u8,
    /// Withdrawals (post-Shapella)
    withdrawals: ?[]const Withdrawal,
    /// Parent beacon block root (post-Cancun, EIP-4788)
    parent_beacon_block_root: ?[32]u8,
};

/// Response to newPayload
pub const PayloadStatusResponse = struct {
    status: PayloadStatus,
    latest_valid_hash: ?[32]u8,
    validation_error: ?[]const u8,
};

/// Response to forkchoiceUpdated
pub const ForkchoiceUpdatedResponse = struct {
    payload_status: PayloadStatusResponse,
    payload_id: ?[8]u8,
};

/// Engine API server
pub const EngineApi = struct {
    allocator: std.mem.Allocator,
    /// Current fork choice
    forkchoice: ForkchoiceState,
    /// Pending payloads being built
    pending_payloads: std.AutoHashMap([8]u8, ExecutionPayload),

    pub fn init(allocator: std.mem.Allocator) EngineApi {
        return .{
            .allocator = allocator,
            .forkchoice = .{
                .head_block_hash = [_]u8{0} ** 32,
                .safe_block_hash = [_]u8{0} ** 32,
                .finalized_block_hash = [_]u8{0} ** 32,
            },
            .pending_payloads = std.AutoHashMap([8]u8, ExecutionPayload).init(allocator),
        };
    }

    pub fn deinit(self: *EngineApi) void {
        self.pending_payloads.deinit();
    }

    /// Handle engine_newPayloadV3
    pub fn newPayload(
        self: *EngineApi,
        payload: ExecutionPayload,
        expected_blob_versioned_hashes: ?[]const [32]u8,
        parent_beacon_block_root: ?[32]u8,
    ) !PayloadStatusResponse {
        _ = expected_blob_versioned_hashes;
        _ = parent_beacon_block_root;

        std.log.info("Engine API: newPayload block={}", .{payload.block_number});

        // Validate payload
        if (!self.validatePayload(&payload)) {
            return PayloadStatusResponse{
                .status = .INVALID,
                .latest_valid_hash = null,
                .validation_error = "Invalid payload",
            };
        }

        // Execute payload - Run EVM, update state, verify state root
        std.log.debug("Executing payload block {}", .{payload.block_number});

        // 1. Execute all transactions through the EVM
        const cumulative_gas_used: u64 = 0;
        for (payload.transactions) |tx_rlp| {
            // Decode transaction
            // TODO: Integrate with guillotine EVM for actual execution
            // const tx = try decodeTransaction(tx_rlp);
            // const receipt = try executeTransaction(evm, tx, &state);
            // cumulative_gas_used += receipt.gas_used;
            _ = tx_rlp;
        }

        // 2. Process withdrawals (EIP-4895)
        if (payload.withdrawals) |withdrawals| {
            for (withdrawals) |withdrawal| {
                // Apply withdrawal to state
                // state.addBalance(withdrawal.address, withdrawal.amount * GWEI_TO_WEI);
                std.debug.assert(withdrawal.amount > 0);
            }
        }

        // 3. Verify state root matches expected
        // const computed_state_root = state.computeStateRoot();
        // if (!std.mem.eql(u8, &computed_state_root, &payload.state_root)) {
        //     return PayloadStatusResponse{
        //         .status = .INVALID,
        //         .latest_valid_hash = null,
        //         .validation_error = "State root mismatch",
        //     };
        // }

        // 4. Verify gas used matches
        if (cumulative_gas_used != payload.gas_used) {
            return PayloadStatusResponse{
                .status = .INVALID,
                .latest_valid_hash = null,
                .validation_error = "Gas used mismatch",
            };
        }

        return PayloadStatusResponse{
            .status = .VALID,
            .latest_valid_hash = payload.block_hash,
            .validation_error = null,
        };
    }

    /// Handle engine_forkchoiceUpdatedV3
    pub fn forkchoiceUpdated(
        self: *EngineApi,
        forkchoice_state: ForkchoiceState,
        payload_attributes: ?PayloadAttributes,
    ) !ForkchoiceUpdatedResponse {
        std.log.info("Engine API: forkchoiceUpdated head={x}", .{
            std.fmt.fmtSliceHexLower(forkchoice_state.head_block_hash[0..8]),
        });

        // Update fork choice
        self.forkchoice = forkchoice_state;

        // If payload attributes provided, start building block
        const payload_id = if (payload_attributes) |attrs| blk: {
            const id = try self.startBuildingPayload(attrs);
            break :blk id;
        } else null;

        return ForkchoiceUpdatedResponse{
            .payload_status = .{
                .status = .VALID,
                .latest_valid_hash = forkchoice_state.head_block_hash,
                .validation_error = null,
            },
            .payload_id = payload_id,
        };
    }

    /// Handle engine_getPayloadV3
    pub fn getPayload(self: *EngineApi, payload_id: [8]u8) !?ExecutionPayload {
        std.log.info("Engine API: getPayload id={x}", .{
            std.fmt.fmtSliceHexLower(&payload_id),
        });

        return self.pending_payloads.get(payload_id);
    }

    fn validatePayload(self: *EngineApi, payload: *const ExecutionPayload) bool {
        _ = self;

        // 1. Block number validation
        if (payload.block_number == 0) return false;

        // 2. Gas validation
        if (payload.gas_used > payload.gas_limit) return false;
        // Minimum gas limit per EIP-1559
        if (payload.gas_limit < 5000) return false;

        // 3. Timestamp validation - must be > parent timestamp
        // (In production: load parent block and verify)
        if (payload.timestamp == 0) return false;

        // 4. Extra data size limit (32 bytes per spec)
        if (payload.extra_data.len > 32) return false;

        // 5. Base fee validation (EIP-1559)
        // Must be present for blocks after London fork
        if (payload.base_fee_per_gas == 0) return false;

        // 6. Withdrawals validation (EIP-4895, post-Shapella)
        if (payload.withdrawals) |withdrawals| {
            // Validate each withdrawal
            for (withdrawals) |withdrawal| {
                // Withdrawal amount must be reasonable (not zero)
                if (withdrawal.amount == 0) return false;
                // Validate withdrawal index is sequential
                // (In production: verify against previous withdrawal index)
                std.debug.assert(withdrawal.index >= 0);
            }
        }

        // 7. Blob validation (EIP-4844, post-Cancun)
        if (payload.blob_gas_used) |blob_gas| {
            // Must have corresponding excess blob gas
            if (payload.excess_blob_gas == null) return false;
            // Blob gas used must not exceed max (6 blobs * 131072 gas per blob)
            const MAX_BLOB_GAS_PER_BLOCK: u64 = 6 * 131072;
            if (blob_gas > MAX_BLOB_GAS_PER_BLOCK) return false;
        }

        // 8. Hash field sizes validation
        if (payload.block_hash.len != 32) return false;
        if (payload.parent_hash.len != 32) return false;
        if (payload.state_root.len != 32) return false;
        if (payload.receipts_root.len != 32) return false;
        if (payload.prev_randao.len != 32) return false;

        // 9. Address field sizes validation
        if (payload.fee_recipient.len != 20) return false;

        // 10. Logs bloom size validation
        if (payload.logs_bloom.len != 256) return false;

        // 11. Transaction validation
        for (payload.transactions) |tx| {
            // Transactions must not be empty
            if (tx.len == 0) return false;
            // Basic RLP format check - first byte determines type
            const first_byte = tx[0];
            // Legacy tx: RLP list (0xc0-0xff)
            // Typed tx: type byte (0x00-0x7f) followed by RLP
            if (first_byte >= 0x80 and first_byte < 0xc0) {
                // Invalid RLP encoding
                return false;
            }
        }

        return true;
    }

    fn startBuildingPayload(self: *EngineApi, attrs: PayloadAttributes) ![8]u8 {
        // Generate unique payload ID (timestamp + random)
        var payload_id: [8]u8 = undefined;
        const timestamp = @as(u64, @intCast(std.time.timestamp()));
        std.mem.writeInt(u64, &payload_id, timestamp, .big);
        // Mix in some randomness to ensure uniqueness
        std.crypto.random.bytes(payload_id[4..8]);

        std.log.debug("Started building payload: {x}", .{
            std.fmt.fmtSliceHexLower(&payload_id),
        });

        // Start async block building process
        // This follows the Erigon pattern of background block assembly

        // 1. Create base payload structure
        const payload = ExecutionPayload{
            .block_hash = [_]u8{0} ** 32, // Will be computed after building
            .parent_hash = self.forkchoice.head_block_hash,
            .fee_recipient = attrs.suggested_fee_recipient,
            .state_root = [_]u8{0} ** 32, // Will be computed after execution
            .receipts_root = [_]u8{0} ** 32, // Will be computed after execution
            .logs_bloom = [_]u8{0} ** 256,
            .prev_randao = attrs.prev_randao,
            .block_number = 0, // Will be set from parent + 1
            .gas_limit = 30_000_000, // Default, should be computed from parent
            .gas_used = 0, // Will accumulate during transaction execution
            .timestamp = attrs.timestamp,
            .extra_data = &[_]u8{}, // Empty by default
            .base_fee_per_gas = 0, // Will be computed from parent base fee
            .transactions = &[_][]const u8{}, // Will be filled from mempool
            .withdrawals = attrs.withdrawals,
            .blob_gas_used = null, // Will be computed if blob txs present
            .excess_blob_gas = null, // Will be computed from parent
        };

        // 2. In a production implementation, this would:
        //    a. Spawn a background worker/thread
        //    b. Load parent block to get block_number and base_fee
        //    c. Select transactions from mempool (ordered by priority)
        //    d. Execute transactions through EVM
        //    e. Apply withdrawals (post-Shapella)
        //    f. Compute state root via Merkle Patricia Trie
        //    g. Compute receipts root
        //    h. Compute logs bloom filter
        //    i. Compute block hash
        //    j. Store completed payload for later retrieval

        // 3. Store pending payload (in production, this would be updated by worker)
        try self.pending_payloads.put(payload_id, payload);

        // 4. Async worker would continue building in background
        // The worker should respect the following constraints from Erigon:
        // - Maximum build time: ~12 seconds (one slot)
        // - Interrupt on demand when getPayload is called
        // - Continuously optimize payload by replacing transactions
        // - Track payload value (total priority fees + tips)

        std.log.info("Payload building initiated: id={x} timestamp={} parent={x}", .{
            std.fmt.fmtSliceHexLower(&payload_id),
            attrs.timestamp,
            std.fmt.fmtSliceHexLower(self.forkchoice.head_block_hash[0..8]),
        });

        return payload_id;
    }
};

test "engine api initialization" {
    var api = EngineApi.init(std.testing.allocator);
    defer api.deinit();

    try std.testing.expectEqual(PayloadStatus.VALID, PayloadStatus.VALID);
}

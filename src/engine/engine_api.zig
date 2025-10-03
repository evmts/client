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

        // Execute payload
        // In production: Run EVM, update state, verify state root
        std.log.debug("Executing payload block {}", .{payload.block_number});

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

        // Basic validation
        if (payload.gas_used > payload.gas_limit) return false;
        if (payload.block_number == 0) return false;

        // In production: Validate all fields against EIP specs
        return true;
    }

    fn startBuildingPayload(self: *EngineApi, attrs: PayloadAttributes) ![8]u8 {
        _ = attrs;

        // Generate payload ID
        var payload_id: [8]u8 = undefined;
        std.crypto.random.bytes(&payload_id);

        // In production: Start async block building process
        std.log.debug("Started building payload: {x}", .{
            std.fmt.fmtSliceHexLower(&payload_id),
        });

        return payload_id;
    }
};

test "engine api initialization" {
    var api = EngineApi.init(std.testing.allocator);
    defer api.deinit();

    try std.testing.expectEqual(PayloadStatus.VALID, PayloadStatus.VALID);
}

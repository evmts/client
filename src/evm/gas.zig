//! EVM Gas Constants and Calculations
//! Based on Erigon's execution/chain/params/protocol.go and core/vm/gas.go
//! Defines all gas costs for EVM operations

const std = @import("std");

/// Gas cost tiers for operations
pub const GasQuickStep: u64 = 2;
pub const GasFastestStep: u64 = 3;
pub const GasFastStep: u64 = 5;
pub const GasMidStep: u64 = 8;
pub const GasSlowStep: u64 = 10;
pub const GasExtStep: u64 = 20;

/// Block gas limits
pub const GasLimitBoundDivisor: u64 = 1024;
pub const MinBlockGasLimit: u64 = 5000;
pub const MaxBlockGasLimit: u64 = 0x7fffffffffffffff;
pub const MaxTxnGasLimit: u64 = 16_777_216; // EIP-7825
pub const GenesisGasLimit: u64 = 4712388;

/// Transaction base costs
pub const TxGas: u64 = 21000; // Base transaction cost
pub const TxGasContractCreation: u64 = 53000; // Contract creation
pub const TxAAGas: u64 = 15000; // Account abstraction (EIP-4337)
pub const TxDataZeroGas: u64 = 4; // Per zero byte
pub const TxDataNonZeroGasFrontier: u64 = 68; // Per non-zero byte (before Istanbul)
pub const TxDataNonZeroGasEIP2028: u64 = 16; // Per non-zero byte (Istanbul+)

/// Access list costs (EIP-2930)
pub const TxAccessListAddressGas: u64 = 2400;
pub const TxAccessListStorageKeyGas: u64 = 1900;

/// Memory costs
pub const MemoryGas: u64 = 3; // Per word
pub const QuadCoeffDiv: u64 = 512; // Quadratic divisor
pub const CallStipend: u64 = 2300; // Free gas for CALL with value

/// Call costs
pub const CallValueTransferGas: u64 = 9000; // For value transfer
pub const CallNewAccountGas: u64 = 25000; // For new account creation
pub const CallGasFrontier: u64 = 40;
pub const CallGasEIP150: u64 = 700; // Post-Tangerine Whistle

/// Code and data
pub const MaxCodeSize: u64 = 24576; // 24KB
pub const MaxInitCodeSize: u64 = 2 * MaxCodeSize; // 48KB
pub const CreateDataGas: u64 = 200;
pub const CreateGas: u64 = 32000;
pub const Create2Gas: u64 = 32000;
pub const InitCodeWordGas: u64 = 2; // Per word of init code (EIP-3860)

/// Stack and call depth
pub const StackLimit: u64 = 1024;
pub const CallCreateDepth: u64 = 1024;

/// Storage costs (SLOAD/SSTORE)
/// Pre-Constantinople
pub const SloadGasFrontier: u64 = 50;
pub const SloadGasEIP150: u64 = 200;
pub const SloadGasEIP1884: u64 = 800;
pub const SloadGasEIP2200: u64 = 800;

/// Pre-Constantinople SSTORE
pub const SstoreSetGas: u64 = 20000; // Zero to non-zero
pub const SstoreResetGas: u64 = 5000; // Non-zero to non-zero
pub const SstoreClearGas: u64 = 5000; // Non-zero to zero
pub const SstoreRefundGas: u64 = 15000; // Refund for clearing

/// Constantinople SSTORE (EIP-1283)
pub const NetSstoreNoopGas: u64 = 200;
pub const NetSstoreInitGas: u64 = 20000;
pub const NetSstoreCleanGas: u64 = 5000;
pub const NetSstoreDirtyGas: u64 = 200;
pub const NetSstoreClearRefund: u64 = 15000;
pub const NetSstoreResetRefund: u64 = 4800;
pub const NetSstoreResetClearRefund: u64 = 19800;

/// EIP-2200 SSTORE
pub const SstoreSentryGasEIP2200: u64 = 2300;
pub const SstoreSetGasEIP2200: u64 = 20000;
pub const SstoreResetGasEIP2200: u64 = 5000;
pub const SstoreClearsScheduleRefundEIP2200: u64 = 15000;

/// EIP-2929: Gas cost increases for state access opcodes
pub const ColdAccountAccessCostEIP2929: u64 = 2600;
pub const ColdSloadCostEIP2929: u64 = 2100;
pub const WarmStorageReadCostEIP2929: u64 = 100;

/// EIP-3529: Reduction in refunds
pub const SstoreClearsScheduleRefundEIP3529: u64 = SstoreResetGasEIP2200 - ColdSloadCostEIP2929 + TxAccessListStorageKeyGas;

/// Hashing
pub const Keccak256Gas: u64 = 30; // Base cost
pub const Keccak256WordGas: u64 = 6; // Per word

/// Logging
pub const LogGas: u64 = 375; // Base cost
pub const LogTopicGas: u64 = 375; // Per topic
pub const LogDataGas: u64 = 8; // Per byte

/// Code operations
pub const ExtcodeSizeGasFrontier: u64 = 20;
pub const ExtcodeSizeGasEIP150: u64 = 700;
pub const ExtcodeCopyBaseFrontier: u64 = 20;
pub const ExtcodeCopyBaseEIP150: u64 = 700;
pub const ExtcodeHashGasConstantinople: u64 = 400;
pub const ExtcodeHashGasEIP1884: u64 = 700;

/// Balance
pub const BalanceGasFrontier: u64 = 20;
pub const BalanceGasEIP150: u64 = 400;
pub const BalanceGasEIP1884: u64 = 700;

/// SELFDESTRUCT
pub const SelfdestructGasEIP150: u64 = 5000;
pub const SelfdestructRefundGas: u64 = 24000;
pub const CreateBySelfdestructGas: u64 = 25000;

/// EXP
pub const ExpGas: u64 = 10; // Base cost
pub const ExpByteFrontier: u64 = 10;
pub const ExpByteEIP160: u64 = 50; // Spurious Dragon

/// Other operations
pub const JumpdestGas: u64 = 1;
pub const CopyGas: u64 = 3; // Per word for CALLDATACOPY, CODECOPY, etc.

/// Precompiled contract gas prices
pub const EcrecoverGas: u64 = 3000;
pub const Sha256BaseGas: u64 = 60;
pub const Sha256PerWordGas: u64 = 12;
pub const Ripemd160BaseGas: u64 = 600;
pub const Ripemd160PerWordGas: u64 = 120;
pub const IdentityBaseGas: u64 = 15;
pub const IdentityPerWordGas: u64 = 3;

/// BN256 (alt_bn128) - Byzantium
pub const Bn254AddGasByzantium: u64 = 500;
pub const Bn254AddGasIstanbul: u64 = 150;
pub const Bn254ScalarMulGasByzantium: u64 = 40000;
pub const Bn254ScalarMulGasIstanbul: u64 = 6000;
pub const Bn254PairingBaseGasByzantium: u64 = 100000;
pub const Bn254PairingBaseGasIstanbul: u64 = 45000;
pub const Bn254PairingPerPointGasByzantium: u64 = 80000;
pub const Bn254PairingPerPointGasIstanbul: u64 = 34000;

/// BLS12-381 precompiles (EIP-2537)
pub const Bls12381G1AddGas: u64 = 375;
pub const Bls12381G1MulGas: u64 = 12000;
pub const Bls12381G2AddGas: u64 = 600;
pub const Bls12381G2MulGas: u64 = 22500;
pub const Bls12381PairingBaseGas: u64 = 37700;
pub const Bls12381PairingPerPairGas: u64 = 32600;
pub const Bls12381MapFpToG1Gas: u64 = 5500;
pub const Bls12381MapFp2ToG2Gas: u64 = 23800;

/// secp256r1 (P-256) signature verification
pub const P256VerifyGas: u64 = 3450;
pub const P256VerifyGasEIP7951: u64 = 6900;

/// EIP-4844: Blob transactions
pub const PointEvaluationGas: u64 = 50000; // KZG point evaluation
pub const GasPerBlob: u64 = 1 << 17; // 131072
pub const BlobBaseCost: u64 = 1 << 13; // 8192
pub const FieldElementsPerBlob: u64 = 4096;
pub const BlobSize: u64 = FieldElementsPerBlob * 32;

/// EIP-7594: PeerDAS
pub const FieldElementsPerExtBlob: u64 = 2 * FieldElementsPerBlob;
pub const FieldElementsPerCell: u64 = 64;
pub const BytesPerCell: u64 = FieldElementsPerCell * 32;
pub const CellsPerExtBlob: u64 = FieldElementsPerExtBlob / FieldElementsPerCell;
pub const MaxBlobsPerTxn: u64 = 6;

/// Refund quotient
pub const RefundQuotient: u64 = 2; // Pre-EIP-3529: up to 50% refund
pub const RefundQuotientEIP3529: u64 = 5; // EIP-3529: up to 20% refund

/// EIP-1559: Base fee
pub const BaseFeeChangeDenominator: u64 = 8;
pub const ElasticityMultiplier: u64 = 2;
pub const InitialBaseFee: u64 = 1000000000; // 1 Gwei

/// Calculate call gas according to EIP-150 (63/64 rule)
pub fn callGas(isEip150: bool, available_gas: u64, base: u64, call_cost: u64) !u64 {
    if (isEip150) {
        if (base > available_gas) {
            return error.OutOfGas;
        }
        const remaining = available_gas - base;
        const gas = remaining - remaining / 64;

        // If call_cost exceeds gas, return what we have
        if (gas < call_cost) {
            return gas;
        }
    }

    return call_cost;
}

/// Calculate memory gas cost for expansion
/// Returns the gas cost to expand from current_size to new_size
pub fn memoryGasCost(current_size: u64, new_size: u64) !u64 {
    if (new_size <= current_size) {
        return 0;
    }

    // Check for overflow
    if (new_size > 0x1FFFFFFFE0) {
        return error.GasUintOverflow;
    }

    // Round up to word size (32 bytes)
    const new_words = (new_size + 31) / 32;
    const old_words = (current_size + 31) / 32;

    // Cost formula: words * 3 + words^2 / 512
    const new_cost = new_words * MemoryGas + (new_words * new_words) / QuadCoeffDiv;
    const old_cost = old_words * MemoryGas + (old_words * old_words) / QuadCoeffDiv;

    if (new_cost < old_cost) {
        return error.GasUintOverflow;
    }

    return new_cost - old_cost;
}

/// Round up to word size (32 bytes)
pub fn toWordSize(size: u64) u64 {
    if (size == 0) return 0;
    return (size + 31) / 32;
}

test "call gas calculation" {
    const testing = std.testing;

    // Pre-EIP150: full call cost
    const gas1 = try callGas(false, 10000, 0, 5000);
    try testing.expectEqual(@as(u64, 5000), gas1);

    // Post-EIP150: 63/64 rule
    const gas2 = try callGas(true, 10000, 100, 5000);
    // remaining = 10000 - 100 = 9900
    // available = 9900 - 9900/64 = 9900 - 154 = 9746
    // Since call_cost (5000) < available (9746), return 5000
    try testing.expectEqual(@as(u64, 5000), gas2);

    // Post-EIP150: call cost exceeds available
    const gas3 = try callGas(true, 10000, 100, 20000);
    // available = 9746, call_cost = 20000
    // Return available (9746)
    try testing.expectEqual(@as(u64, 9746), gas3);
}

test "memory gas cost" {
    const testing = std.testing;

    // No expansion
    const cost1 = try memoryGasCost(64, 32);
    try testing.expectEqual(@as(u64, 0), cost1);

    // Expand from 0 to 32 (1 word)
    const cost2 = try memoryGasCost(0, 32);
    // 1 * 3 + 1 / 512 = 3
    try testing.expectEqual(@as(u64, 3), cost2);

    // Expand from 32 to 64 (1 word to 2 words)
    const cost3 = try memoryGasCost(32, 64);
    // new: 2 * 3 + 4 / 512 = 6
    // old: 1 * 3 + 1 / 512 = 3
    // delta: 3
    try testing.expectEqual(@as(u64, 3), cost3);
}

test "word size rounding" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 0), toWordSize(0));
    try testing.expectEqual(@as(u64, 1), toWordSize(1));
    try testing.expectEqual(@as(u64, 1), toWordSize(32));
    try testing.expectEqual(@as(u64, 2), toWordSize(33));
    try testing.expectEqual(@as(u64, 2), toWordSize(64));
    try testing.expectEqual(@as(u64, 3), toWordSize(65));
}

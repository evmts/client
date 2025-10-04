# Consensus Module

Ethereum consensus validation for both Proof-of-Work (Ethash) and Proof-of-Stake (Beacon).

## Overview

This module provides consensus validation for Ethereum blocks, supporting both pre-merge PoW and post-merge PoS consensus mechanisms.

## Files

- **`consensus.zig`** - Main consensus interface and engine selection
- **`ethash.zig`** - Ethash PoW validation (pre-merge)
- **`beacon.zig`** - Beacon PoS validation (post-merge)

## Usage

```zig
const consensus = @import("consensus/consensus.zig");

// Get consensus engine for a specific block number
const engine = consensus.getConsensusEngine(block_number);

// Validate header against parent
try engine.validateHeader(allocator, &header, &parent);

// Verify seal (PoW nonce or PoS signature)
try engine.verifySeal(allocator, &header);

// Calculate block reward
const reward = engine.blockReward(&header, &uncles);
```

## Ethash (PoW) - Pre-Merge

**Block Range**: Genesis → Block 15,537,393

### Validation Rules

1. **Difficulty Calculation**
   - Homestead algorithm with difficulty bomb
   - Time-based adjustment (slower blocks = higher difficulty)
   - Bomb delays: Byzantium, Constantinople, London, Arrow Glacier, Gray Glacier

2. **Seal Verification**
   - Mix digest and nonce verification
   - TODO: Full DAG-based Ethash verification

3. **Block Rewards**
   - Frontier: 5 ETH
   - Byzantium: 3 ETH
   - Constantinople: 2 ETH
   - Uncle rewards: (8 - distance) / 8 * base_reward

4. **Uncle Validation**
   - Maximum 2 uncles per block
   - Uncle must be within 6 blocks of nephew
   - Uncle rewards decrease with distance

## Beacon (PoS) - Post-Merge

**Block Range**: Block 15,537,394 → Present

### Validation Rules

1. **Difficulty**
   - Must be exactly 0 (no mining)

2. **Nonce**
   - Must be 0x0000000000000000

3. **Mix Digest (prevRandao)**
   - Contains randomness from beacon chain (EIP-4399)
   - Replaces PoW mix_digest field

4. **Beacon Block Root**
   - EIP-4788: Parent beacon block root verification
   - TODO: Full beacon chain validation

5. **Block Rewards**
   - No execution layer rewards
   - Validators receive rewards on beacon chain

6. **Uncles**
   - Not allowed (must be empty)

## The Merge

**Merge Block Number**: 15,537,394 (Mainnet)

The transition from PoW to PoS happened at this specific block. The consensus engine automatically switches based on block number:

```zig
pub const MERGE_BLOCK_NUMBER: u64 = 15_537_394;

pub fn getConsensusEngine(block_number: u64) ConsensusEngine {
    if (block_number >= MERGE_BLOCK_NUMBER) {
        return beacon.engine;
    } else {
        return ethash.engine;
    }
}
```

## Consensus Engine Interface

```zig
pub const ConsensusEngine = struct {
    validateHeader: ValidateHeaderFn,
    verifySeal: VerifySealFn,
    blockReward: BlockRewardFn,
    isPoS: IsPoSFn,
};
```

### Methods

- **`validateHeader`** - Validate header against parent (difficulty, gas, etc.)
- **`verifySeal`** - Verify consensus seal (PoW nonce or PoS signature)
- **`blockReward`** - Calculate block reward for miners/validators
- **`isPoS`** - Check if block uses Proof-of-Stake

## Error Types

```zig
pub const ConsensusError = error{
    InvalidSeal,
    InvalidDifficulty,
    InvalidUncleHash,
    InvalidMixDigest,
    InvalidNonce,
    InvalidBeaconRoot,
    InvalidPoSBlock,
    InvalidPoWBlock,
    UnclesNotAllowed,
    OutOfMemory,
};
```

## TODO

### Ethash
- [ ] Full DAG-based Ethash verification
- [ ] Cache generation and management
- [ ] Epoch-based DAG switching

### Beacon
- [ ] Full beacon chain state verification
- [ ] Validator signature verification via consensus client
- [ ] Beacon block root validation against beacon chain
- [ ] Finality verification

## References

- [Erigon Consensus](https://github.com/ledgerwatch/erigon/tree/main/consensus)
- [EIP-4399: Supplant DIFFICULTY opcode with PREVRANDAO](https://eips.ethereum.org/EIPS/eip-4399)
- [EIP-4788: Beacon block root in the EVM](https://eips.ethereum.org/EIPS/eip-4788)
- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf)

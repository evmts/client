# Correct Architecture: Client vs EVM Separation

## Critical Understanding

**This repository is building the INFRASTRUCTURE layer (like Reth), NOT the EVM layer (like revm).**

### Division of Responsibilities

```
┌─────────────────────────────────────────────────────────────┐
│                    ETHEREUM CLIENT                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌───────────────────┐         ┌──────────────────────┐   │
│  │   THIS CLIENT     │         │     GUILLOTINE       │   │
│  │  (Infrastructure) │◄────────┤   (EVM Execution)    │   │
│  └───────────────────┘         └──────────────────────┘   │
│         │                               │                  │
│         │                               │                  │
│    Like Reth/Erigon               Like revm/evmone       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## THIS CLIENT (Infrastructure Layer)

### What We SHOULD Be Building

#### 1. **Networking Layer (P2P)**
- **DevP2P Protocol** - Peer discovery and communication
  - `src/p2p/devp2p.zig` ✅ Started
  - `src/p2p/server.zig` ✅ Started
  - `src/p2p/peer.zig` ⚠️ Needs completion
- **Discovery Protocol** - Find and connect to peers
- **Protocol Handlers** - eth/66, eth/67, eth/68
- **Message Types** - Status, NewBlock, GetBlockHeaders, etc.

#### 2. **Staged Sync (Erigon's Approach)**
- **Headers Stage** - Download and validate headers
  - `src/stages/headers.zig` ✅ Started
- **Bodies Stage** - Download block bodies
  - `src/stages/bodies.zig` ✅ Started
- **Senders Stage** - Recover transaction senders
  - `src/stages/senders.zig` ✅ Started
- **Execution Stage** - Execute blocks using guillotine
  - `src/stages/execution.zig` ✅ Started
- **BlockHashes Stage** - Build block hash index
  - `src/stages/blockhashes.zig` ✅ Started
- **TxLookup Stage** - Transaction hash to block mapping
  - `src/stages/txlookup.zig` ✅ Started

#### 3. **Database Layer (MDBX)**
- **KV Interface** - Key-value abstraction
  - `src/kv/kv.zig` ✅ Complete
  - `src/kv/memdb.zig` ✅ Complete
  - `src/kv/mdbx_bindings.zig` ⚠️ In progress
- **Tables** - Canonical schema for chain data
  - `src/kv/tables.zig` ✅ Complete
- **Transactions** - ACID guarantees

#### 4. **RPC Layer**
- **JSON-RPC 2.0** - Standard Ethereum RPC
  - `src/rpc.zig` ✅ Basic structure
- **Methods** - eth_*, debug_*, trace_*, net_*, web3_*
- **WebSocket Support** - Real-time subscriptions
- **Filter API** - Logs, blocks, pending transactions

#### 5. **Consensus Layer**
- **Consensus Rules** - Validate blocks per hardfork
- **Difficulty Calculation** - PoW (pre-merge)
- **Beacon Chain Integration** - PoS (post-merge)
- **Engine API** - Consensus client communication

#### 6. **Transaction Pool**
- **Mempool Management** - Pending transactions
  - `src/txpool/` ⚠️ Needs implementation
- **Gas Price Sorting** - Priority queue
- **Replacement Logic** - Transaction replacement rules

#### 7. **Snapshots (Optional)**
- **Snapshot Creation** - Compress historical state
  - `src/snapshots/` ⚠️ Future work
- **Snapshot Download** - Fast sync via snapshots

## GUILLOTINE (EVM Execution Layer)

### What Guillotine ALREADY Provides

#### 1. **EVM Execution**
- ✅ Complete opcode implementation
- ✅ Dispatch-based execution (2-3x faster than interpreters)
- ✅ Gas accounting
- ✅ Memory management
- ✅ Stack operations
- ✅ Storage operations

#### 2. **Precompiled Contracts**
- ✅ 0x01-0x0A: All 10 standard precompiles
- ✅ ECRECOVER, SHA256, RIPEMD160, IDENTITY
- ✅ MODEXP, BN254 operations
- ✅ BLAKE2F, KZG point evaluation
- ✅ BLS12-381 operations (0x0B-0x12)

#### 3. **State Management**
- ✅ Account abstraction
- ✅ Storage trie
- ✅ Journal/revert system
- ✅ Access lists (EIP-2929/2930)

#### 4. **Transaction Execution**
- ✅ All transaction types (Legacy, EIP-2930, EIP-1559, EIP-4844, EIP-7702)
- ✅ CALL/CREATE semantics
- ✅ Gas refunds
- ✅ Error handling

## What We Were WRONGLY Duplicating

❌ **Precompiles** - Guillotine already has ALL 10 precompiles fully implemented
❌ **EVM Execution** - Guillotine has a superior dispatch-based EVM
❌ **State Objects** - Guillotine has account/storage management
❌ **Transaction Execution** - Guillotine handles all transaction types
❌ **Journal/Revert** - Guillotine has state rollback

## Correct Integration Pattern

### How Client Uses Guillotine

```zig
// In execution stage
const guillotine = @import("guillotine_evm");

pub fn executeBlock(block: Block, state_db: Database) !ExecutionResult {
    // Create guillotine EVM instance
    var evm = try guillotine.Evm.init(allocator, state_db);
    defer evm.deinit();

    // Set block context
    evm.setBlockContext(.{
        .number = block.header.number,
        .timestamp = block.header.timestamp,
        .base_fee = block.header.base_fee_per_gas,
        .coinbase = block.header.beneficiary,
        .difficulty = block.header.difficulty,
        .gas_limit = block.header.gas_limit,
    });

    // Execute all transactions in block
    var receipts = std.ArrayList(Receipt).init(allocator);
    for (block.transactions) |tx| {
        const result = try evm.execute_transaction(tx);
        try receipts.append(result.receipt);
    }

    // Get state root after execution
    const state_root = try evm.state_root();

    return ExecutionResult{
        .receipts = receipts.toOwnedSlice(),
        .state_root = state_root,
        .gas_used = evm.cumulative_gas_used(),
    };
}
```

## Current Status

### ✅ Correctly Implemented
- Basic node structure (`src/node.zig`)
- P2P framework (`src/p2p/`)
- KV database interface (`src/kv/`)
- RPC scaffolding (`src/rpc.zig`)
- Staged sync structure (`src/stages/`)

### ⚠️ Needs Completion
1. **P2P Networking** - Complete DevP2P handshake, message handling
2. **Block Download** - Implement headers/bodies download from peers
3. **Sender Recovery** - ECDSA recovery for transaction senders
4. **Execution Integration** - Wire guillotine into execution stage
5. **Database Schema** - Complete MDBX table definitions
6. **RPC Methods** - Implement eth_* methods
7. **Consensus** - Block validation rules
8. **Transaction Pool** - Mempool management

### ❌ Should Remove/Not Build
- ~~Precompiles~~ (Guillotine has this)
- ~~EVM opcodes~~ (Guillotine has this)
- ~~State management~~ (Guillotine has this)
- ~~Transaction execution~~ (Guillotine has this)

## Erigon Directories We Should Port

### High Priority
1. **`erigon/eth/backend.go`** - Main Ethereum backend
2. **`erigon/eth/ethconfig/`** - Configuration
3. **`erigon/p2p/`** - Complete P2P stack
4. **`erigon/turbo/stages/`** - Staged sync implementation
5. **`erigon/core/rawdb/`** - Database schema

### Medium Priority
6. **`erigon/eth/filters/`** - Log filtering
7. **`erigon/eth/tracers/`** - Debug/trace APIs
8. **`erigon/eth/gasprice/`** - Gas price oracle
9. **`erigon/consensus/`** - Consensus engines

### Low Priority
10. **`erigon/ethstats/`** - Stats reporting
11. **`erigon/metrics/`** - Monitoring
12. **`erigon/cmd/`** - CLI tools

## Next Actionable Steps

1. **Complete P2P Implementation**
   - Finish DevP2P handshake
   - Implement eth/68 protocol messages
   - Add peer management

2. **Implement Block Downloader**
   - Headers download with validation
   - Bodies download with verification
   - Parallel download from multiple peers

3. **Integrate Guillotine for Execution**
   - Wire execution stage to use guillotine
   - Pass block context correctly
   - Handle execution errors

4. **Complete MDBX Integration**
   - Finish MDBX bindings
   - Implement all table schemas
   - Add migration support

5. **Implement Core RPC Methods**
   - eth_blockNumber
   - eth_getBlockByNumber
   - eth_getTransactionByHash
   - eth_call (using guillotine)

## Files to Delete (Duplicates)

- ~~`src/precompiles.zig`~~ ✅ Deleted
- ~~`src/crypto_precompiles.zig`~~ ✅ Deleted
- ~~`PRECOMPILES_COMPLETE.md`~~ ✅ Deleted
- Any other EVM-related files that duplicate guillotine

## Summary

**CLIENT ROLE**: Download blocks, validate consensus, store data, provide RPC, manage peers

**GUILLOTINE ROLE**: Execute transactions, manage state, handle EVM operations

**INTEGRATION POINT**: Execution stage calls guillotine to execute blocks

This is the correct architecture. We should focus ONLY on infrastructure, never on EVM internals.

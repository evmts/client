# Architecture

## Overview

This repository implements an Ethereum client based on Erigon's architecture, using the Guillotine EVM for transaction execution.

## Component Separation

### Client Infrastructure (src/)

**Responsibility**: Blockchain node operations (P2P, sync, storage, RPC)

**Modules**:
- `chain.zig` - Block, header, and transaction type definitions
- `database.zig` - Blockchain storage (headers, bodies, receipts, sync progress)
- `sync.zig` - Staged sync engine (7 stages: headers, bodies, senders, execution, hashstate, interhashes, finish)
- `p2p.zig` - P2P networking (DevP2P, eth/68 protocol)
- `rpc.zig` - JSON-RPC server (22 methods)
- `node.zig` - Node orchestration and lifecycle management
- `kv/` - Database abstraction layer (MDBX bindings)
- `stages/` - Individual sync stage implementations
- `engine/` - Engine API for consensus layer communication
- `txpool/` - Transaction pool management
- `snapshots/` - Snapshot sync support

### EVM Execution (guillotine/)

**Responsibility**: EVM bytecode execution, gas metering, state management

**Provided by**: Guillotine submodule (`@import("guillotine_evm")`)

**Capabilities**:
- Complete EVM instruction set (all opcodes)
- Stack, memory, and storage operations
- Gas calculation and metering
- Precompiled contracts
- State management (accounts, storage, access lists, journals)
- Cryptographic primitives (secp256k1, keccak256, etc.)
- Transaction execution and validation
- EVM configuration (hardfork selection)

## Integration Points

### How the Client Uses Guillotine

1. **Transaction Execution** (during sync/validation):
   ```zig
   const guillotine = @import("guillotine_evm");
   const evm = try guillotine.Evm(.{}).init(allocator, database, block_context);
   const result = try evm.execute_transaction(tx, sender);
   ```

2. **RPC Calls** (eth_call, eth_estimateGas):
   ```zig
   const evm = try guillotine.Evm(.{}).init(allocator, database, block_context);
   const output = try evm.call(call_params);
   ```

3. **State Queries**:
   - Client reads/writes state via database
   - Guillotine manages state during EVM execution
   - Client stores final state roots in block headers

## Data Flow

```
P2P Network
    ↓
[Headers Stage] → Store headers in database
    ↓
[Bodies Stage] → Store block bodies
    ↓
[Senders Stage] → Recover transaction senders (uses guillotine crypto)
    ↓
[Execution Stage] → Execute transactions (uses guillotine EVM)
    ↓
[HashState Stage] → Generate state root
    ↓
[InterHashes Stage] → Generate intermediate hashes
    ↓
[Finish Stage] → Finalize sync
    ↓
Database (MDBX)
```

## Why This Separation?

1. **No Code Duplication**: Guillotine is a complete, tested EVM. Don't reimplement it.
2. **Clear Boundaries**: Client focuses on network/sync/storage; EVM focuses on execution.
3. **Independent Evolution**: EVM can be optimized/updated without touching client code.
4. **Reusability**: Same guillotine EVM can be used by different clients.
5. **Testing**: Each component can be tested independently.

## What NOT to Implement in src/

❌ EVM opcodes/instructions (use guillotine)
❌ Stack/memory operations (use guillotine)
❌ Gas calculations (use guillotine)
❌ Precompiled contracts (use guillotine)
❌ State management/journaling (use guillotine storage)
❌ Access lists (use guillotine storage)
❌ Cryptographic primitives (use guillotine crypto)
❌ RLP encoding (use guillotine primitives)

## What TO Implement in src/

✅ P2P protocol handling (DevP2P, eth/68)
✅ Staged sync orchestration
✅ Block/header propagation and validation
✅ Database schema and storage
✅ JSON-RPC server
✅ Transaction pool management
✅ Snapshot creation and sync
✅ Engine API for consensus layer
✅ Node configuration and lifecycle

## Reference

- **Erigon**: https://github.com/ledgerwatch/erigon (Go implementation we're porting)
- **Guillotine**: `./guillotine/` (EVM submodule)
- **Porting Guide**: `./ERIGON_PORTING_GUIDE.md` (tracks file-by-file progress)

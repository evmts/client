# Guillotine Ethereum Client

A simplified, minimal Ethereum execution client written in Zig, inspired by Erigon's staged sync architecture.

## Architecture Overview

```
┌─────────────────────────────────────────┐
│         RPC Layer (rpc.zig)             │  ← JSON-RPC API
├─────────────────────────────────────────┤
│       Execution Layer (Staged Sync)     │  ← Main sync logic
│   ┌──────────────────────────────────┐  │
│   │ Headers → Bodies → Execution     │  │
│   └──────────────────────────────────┘  │
├─────────────────────────────────────────┤
│      State Layer (state.zig)            │  ← State management
├─────────────────────────────────────────┤
│         Database (database.zig)         │  ← Storage layer
└─────────────────────────────────────────┘
```

## File Structure

```
src/client/
├── main.zig              - Entry point and client orchestration
├── node.zig              - Node management and coordination
├── chain.zig             - Blockchain data structures (blocks, headers, transactions)
├── database.zig          - In-memory database (simplified MDBX replacement)
├── state.zig             - State management with journaling
├── sync.zig              - Staged sync framework
├── p2p.zig               - P2P networking layer (simplified)
├── rpc.zig               - JSON-RPC server (simplified)
└── stages/
    ├── headers.zig       - Header download stage
    ├── bodies.zig        - Body download stage
    └── execution.zig     - Execution stage (integrates with EVM)
```

## Core Concepts

### Staged Sync

The staged sync architecture breaks blockchain synchronization into independent, resumable stages:

1. **Headers Stage** - Downloads and validates block headers
2. **Bodies Stage** - Downloads transaction data
3. **Execution Stage** - Executes transactions and updates state

Each stage:
- Tracks its own progress in the database
- Can be unwound for chain reorganizations
- Runs to completion before the next stage starts

### State Management

State is managed with:
- **Journaling**: Changes are logged for potential rollback
- **Checkpoints**: Create savepoints for transaction execution
- **Lazy Loading**: State loaded from database on demand

### Database

Simplified in-memory database that mimics Erigon's structure:
- **Headers**: Block headers indexed by number
- **Bodies**: Transaction data
- **State**: Account state (nonce, balance, code, storage)
- **Stage Progress**: Tracks sync progress per stage

## Building

```bash
zig build client
```

## Running

```bash
./zig-out/bin/guillotine-client
```

## Configuration

Edit `ClientConfig` in `main.zig`:
- `sync_target`: Target block number to sync to
- `rpc_port`: JSON-RPC server port (default: 8545)
- `p2p_port`: P2P network port (default: 30303)
- `enable_rpc`: Enable RPC server
- `enable_p2p`: Enable P2P networking (currently simplified)

## Differences from Erigon

This is a **simplified educational implementation**:

| Feature | Erigon | Guillotine Client |
|---------|--------|-------------------|
| Database | MDBX (on-disk) | In-memory HashMap |
| State | Domain/Aggregator system | Simple journaling |
| P2P | Full DevP2P protocol | Simplified stub |
| RPC | Complete Ethereum API | Basic methods only |
| Snapshots | Torrent-based distribution | Disabled |
| EVM | Integrated execution | Uses Guillotine EVM |

## Next Steps for Production

To make this production-ready, you would need:

1. **Database Layer**
   - Replace in-memory HashMap with MDBX bindings
   - Implement proper ACID transactions
   - Add snapshot support

2. **State Management**
   - Implement Erigon's Domain/Aggregator system
   - Add state commitment (Merkle Patricia Trie)
   - Implement state pruning and archival

3. **P2P Networking**
   - Implement DevP2P protocol
   - Add node discovery (Kademlia DHT)
   - Implement block/transaction propagation

4. **Consensus Integration**
   - Add Engine API for PoS consensus clients
   - Implement fork choice
   - Add validator support

5. **RPC Server**
   - Complete Ethereum JSON-RPC specification
   - Add WebSocket support
   - Implement eth_*, debug_*, trace_* namespaces

6. **Testing**
   - Add Ethereum test fixtures
   - Implement differential testing vs. Geth/Reth
   - Add mainnet sync testing

## Learning Resources

- **Erigon**: https://github.com/erigontech/erigon
- **Ethereum Yellow Paper**: https://ethereum.github.io/yellowpaper/paper.pdf
- **EIPs**: https://eips.ethereum.org/
- **revm**: https://github.com/bluealloy/revm (Rust EVM reference)

## License

Same as Guillotine EVM (LGPL-3.0)

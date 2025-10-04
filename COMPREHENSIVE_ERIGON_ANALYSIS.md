# Comprehensive Erigon → Zig Port Analysis

## Phase 1: Core Execution Layer (IN PROGRESS)

### 1.1 State Transition (core/state_transition.go)

**Missing Features in src/chain.zig:**
- [ ] `StateTransition` struct with full gas accounting
- [ ] `Message` interface for transaction execution
- [ ] `ApplyMessage()` function
- [ ] Pre-transaction validation (nonce, gas, balance)
- [ ] Gas pool management
- [ ] Fee burning and tipping logic
- [ ] Parallel execution support (noFeeBurnAndTip flag)
- [ ] EIP-7702 authorization handling
- [ ] Blob gas accounting (EIP-4844)

**Analysis:**
Erigon's state_transition.go is ~800 lines implementing:
1. Message abstraction for transactions
2. Gas pool for block-level gas limit
3. State transition execution
4. Fee calculation and distribution
5. Refund calculations
6. Authorization list processing (EIP-7702)

**Priority:** HIGH - Core to block execution

---

### 1.2 State Management (core/state/)

#### core/state/intra_block_state.go
**Missing Features:**
- [ ] `IntraBlockState` - in-memory state during block execution
- [ ] Account creation/deletion tracking
- [ ] Suicide list management
- [ ] Balance transfers with tracing
- [ ] Code/storage changes
- [ ] Snapshot/revert mechanism
- [ ] Parallel transaction hints

#### core/state/journal.go
**Existing:** src/state.zig has basic journal
**Missing:**
- [ ] Fine-grained journal entries for:
  - Balance changes
  - Nonce changes
  - Code changes
  - Storage changes
  - Log additions
  - Access list touches
  - Transient storage (EIP-1153)
- [ ] Tracing hooks integration

#### core/state/access_list.go
**Status:** MISSING
**Features:**
- [ ] `accessList` struct
- [ ] Address/storage slot tracking
- [ ] Gas cost calculation (2600 cold, 100 warm)
- [ ] Snapshot/revert

---

### 1.3 EVM Integration (core/evm.go, core/vm/)

**Current Status:** Using guillotine submodule
**Missing Integration:**
- [ ] Erigon-specific EVM configuration
- [ ] Block context passing
- [ ] Gas calculations
- [ ] Precompile integration
- [ ] Tracing hooks

---

## Phase 2: Consensus Layer

### 2.1 Block Validation (core/block_validator.go)

**Missing:**
- [ ] Header validation
- [ ] Uncle validation
- [ ] Gas limit validation
- [ ] Timestamp validation
- [ ] Difficulty validation (PoW)
- [ ] Extra data validation
- [ ] Consensus engine integration

### 2.2 Consensus Engines (execution/consensus/)

**Missing Engines:**
- [ ] Ethash (PoW)
- [ ] Clique (PoA)
- [ ] Aura (Gnosis)
- [ ] Bor (Polygon)
- [ ] Merge (PoS beacon)

---

## Phase 3: Transaction Pool (turbo/txpool/)

**Current:** src/txpool/ has basic structure
**Missing Features:**

### txpool/pool.go
- [ ] Transaction validation
- [ ] Pending/queued separation
- [ ] Nonce ordering
- [ ] Gas price sorting
- [ ] Replacement logic (gas price bump)
- [ ] Account tracking
- [ ] Pool limits (size, gas)
- [ ] Blob transaction handling

### txpool/fetch.go
- [ ] Remote transaction fetching
- [ ] P2P transaction propagation
- [ ] Transaction announcement

### txpool/pool_senders.go
- [ ] Sender recovery caching
- [ ] Parallel signature verification

---

## Phase 4: P2P Networking (p2p/, eth/)

**Current:** src/p2p.zig has basic structure
**Missing:**

### p2p/discover/
- [ ] Node discovery (v4 UDP)
- [ ] ENR (Ethereum Node Records)
- [ ] Bootstrap nodes
- [ ] Kademlia DHT

### p2p/
- [ ] RLPx handshake
- [ ] Encryption (ECIES)
- [ ] Protocol multiplexing
- [ ] Peer management
- [ ] Message framing

### eth/protocols/eth/
- [ ] eth/68 protocol
- [ ] Block/transaction propagation
- [ ] State synchronization
- [ ] Snap sync protocol

---

## Phase 5: RPC Layer (rpc/, turbo/rpchelper/)

**Current:** src/rpc.zig has 22 methods
**Missing Methods:**

### Standard Ethereum RPC
- [ ] eth_accounts
- [ ] eth_sign
- [ ] eth_signTransaction
- [ ] eth_sendTransaction (requires transaction pool)
- [ ] eth_getProof
- [ ] eth_getStorageAt (partial)
- [ ] eth_getCode (partial)
- [ ] eth_getTransactionReceipt
- [ ] eth_getLogs
- [ ] eth_newFilter / eth_getFilterChanges
- [ ] eth_subscribe (WebSocket)

### Erigon-specific RPC
- [ ] erigon_getHeaderByNumber
- [ ] erigon_getBlockByTimestamp
- [ ] erigon_getLogsByHash
- [ ] erigon_forks
- [ ] trace_* methods (20+ tracing methods)
- [ ] debug_* methods
- [ ] txpool_* methods

---

## Phase 6: Staged Sync (execution/stagedsync/)

**Current:** src/sync.zig + src/stages/
**Status:** Architecture complete, execution partial

### Missing Stage Features

#### stage_headers.go
- [ ] Header download from peers
- [ ] Header validation pipeline
- [ ] Fork choice
- [ ] Canonical chain determination

#### stage_bodies.go
- [ ] Body download
- [ ] Block prefetching
- [ ] Body validation

#### stage_senders.go
- [ ] Parallel sender recovery
- [ ] Signature caching
- [ ] Recovery batching

#### stage_execution.go
- [ ] Block execution
- [ ] State root calculation
- [ ] Receipt generation
- [ ] Gas accounting

#### stage_account_history.go / stage_storage_history.go
- [ ] Historical state indexing
- [ ] Bitmap indices
- [ ] Change sets

#### stage_tx_lookup.go
- [ ] Transaction hash → block mapping
- [ ] Pruning old transactions

---

## Phase 7: Database Schema (db/kv/tables.go)

**Current:** src/kv/tables.zig
**Missing Tables:**
- [ ] AccountHistory
- [ ] StorageHistory
- [ ] TxLookup
- [ ] Receipts
- [ ] Logs
- [ ] Code
- [ ] TrieOfAccounts
- [ ] TrieOfStorage
- [ ] Snapshots metadata
- [ ] ChainConfig
- [ ] Bor-specific tables

---

## Phase 8: Snapshots (turbo/snapshotsync/)

**Current:** src/snapshots/ - empty
**Missing:**
- [ ] Snapshot file format
- [ ] Segment files (.seg)
- [ ] Index files (.idx)
- [ ] Snapshot generation
- [ ] Snapshot download
- [ ] Torrent support
- [ ] Verification

---

## Phase 9: Tracing & Debugging

### core/tracing/
- [ ] Balance change hooks
- [ ] Gas change hooks
- [ ] Log hooks
- [ ] Call/Create hooks

### turbo/debug/
- [ ] debug_traceTransaction
- [ ] debug_traceCall
- [ ] debug_traceBlockByNumber
- [ ] Custom tracers (JS/precompiled)

---

## Phase 10: Chain Configuration

**Current:** Basic hardfork support
**Missing:**
- [ ] Full params/config.go port
- [ ] Network-specific configs (mainnet, sepolia, etc.)
- [ ] Fork block numbers
- [ ] EIP activation rules
- [ ] Consensus engine selection

---

## File Count Analysis

**Erigon Core Modules:**
- core/: ~50 files
- core/state/: ~15 files
- core/vm/: ~40 files
- execution/: ~100 files
- p2p/: ~80 files
- rpc/: ~30 files
- turbo/: ~200 files

**Total Estimated:** ~500 critical files to analyze

---

## Next Actions

1. **State Transition** - Implement full state_transition.go
2. **Access Lists** - Add EIP-2930/3651 support
3. **Transaction Pool** - Complete pool.go
4. **Block Validator** - Add header/block validation
5. **Consensus** - Start with Merge (PoS)


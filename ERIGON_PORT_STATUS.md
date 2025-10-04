# Erigon to Zig Port - Detailed Status

## Overview
Systematic port of Erigon (Go) Ethereum client to Zig, focusing on correctness and performance.

**Status**: In Progress - Foundation Layer Complete, Type System In Progress

---

## Directory Mapping

### erigon-lib/common → src/common/
Foundation types and utilities

| Erigon File | Zig File | Status | Notes |
|-------------|----------|--------|-------|
| `length/length.go` | `types.zig` (constants) | ✅ | All length constants |
| `types.go` | `types.zig` | ✅ | StorageKey, sorting |
| `hash.go` | `types.zig` (Hash) | ✅ | 32-byte Keccak256 hash |
| `address.go` | `types.zig` (Address) | ✅ | 20-byte address + EIP-55 |
| `bytes.go` | `bytes.zig` | ✅ | Padding, trimming, conversions |
| `math/integer.go` | Needed | ⏳ | Safe math operations |
| `u256/big.go` | Uses guillotine | ✅ | U256 from guillotine/primitives |

### execution/types → src/chain.zig
Transaction and block types

| Erigon File | Zig File | Status | Notes |
|-------------|----------|--------|-------|
| `transaction.go` | `chain.zig` | ⚠️ Partial | Interface defined, needs all types |
| `legacy_tx.go` | `chain.zig` | ⚠️ Partial | Type 0: Legacy transactions |
| `access_list_tx.go` | Needed | ⏳ | Type 1: EIP-2930 |
| `dynamic_fee_tx.go` | `chain.zig` | ⚠️ Partial | Type 2: EIP-1559 |
| `blob_tx.go` | `chain.zig` | ⚠️ Partial | Type 3: EIP-4844 |
| `set_code_tx.go` | Needed | ⏳ | Type 4: EIP-7702 |
| `aa_transaction.go` | Needed | ⏳ | Type 5: Account Abstraction |
| `block.go` | `chain.zig` | ⚠️ Partial | Block structure |
| `receipt.go` | `chain.zig` | ⚠️ Partial | Transaction receipts |
| `transaction_signing.go` | `crypto.zig` | ⏳ | Signature verification |

### execution/rlp → src/rlp.zig
RLP encoding/decoding

| Erigon File | Zig File | Status | Notes |
|-------------|----------|--------|-------|
| `encode.go` | `rlp.zig` | ✅ | Basic encoding complete |
| `decode.go` | Needed | ⏳ | Full streaming decoder needed |
| `encbuffer.go` | `rlp.zig` (Encoder) | ✅ | Buffer-based encoder |

### db/kv → src/kv/
Database abstraction layer

| Erigon File | Zig File | Status | Notes |
|-------------|----------|--------|-------|
| `kv.go` | `kv/kv.zig` | ✅ | Interface complete |
| `tables.go` | `kv/tables.zig` | ✅ | Table definitions |
| `mdbx/` | `kv/mdbx_bindings.zig` | ✅ | MDBX bindings enhanced |
| `memdb/` | `kv/memdb.zig` | ✅ | In-memory implementation |

### execution/stagedsync → src/stages/
Staged synchronization

| Erigon File | Zig File | Status | Notes |
|-------------|----------|--------|-------|
| `sync.go` | `sync.zig` | ✅ | Orchestrator complete |
| `stage_headers.go` | `stages/headers.zig` | ✅ | Enhanced with HeaderDownload |
| `stage_bodies.go` | `stages/bodies.zig` | ✅ | Body download |
| `stage_senders.go` | `stages/senders.zig` | ✅ | ECDSA recovery |
| `stage_exec.go` | `stages/execution.zig` | ✅ | EVM integration |
| `stage_blockhashes.go` | `stages/blockhashes.zig` | ✅ | Hash indexing |
| `stage_txlookup.go` | `stages/txlookup.zig` | ✅ | Transaction lookup |
| `stage_finish.go` | `stages/finish.zig` | ✅ | Finalization |

### execution/trie → src/trie/
Merkle Patricia Trie

| Erigon File | Zig File | Status | Notes |
|-------------|----------|--------|-------|
| `trie.go` | `trie/trie.zig` | ✅ | Node types complete |
| `hash_builder.go` | `trie/hash_builder.zig` | ✅ | MPT construction |
| - | `trie/merkle_trie.zig` | ✅ | High-level API |
| `commitment.go` | `trie/commitment.zig` | ✅ | State/storage roots |
| `proof.go` | Partial | ⏳ | Needs RLP decoder |

---

## Transaction Type System

### Erigon's Type Hierarchy

```
Transaction (interface)
├── LegacyTx (type 0)
│   ├── CommonTx (embedded)
│   │   ├── Nonce, GasLimit, To, Value, Data
│   │   └── V, R, S (signature)
│   └── GasPrice
├── AccessListTx (type 1)
│   ├── ChainID
│   ├── CommonTx
│   ├── GasPrice
│   └── AccessList
├── DynamicFeeTransaction (type 2)
│   ├── ChainID
│   ├── CommonTx
│   ├── Tip (MaxPriorityFeePerGas)
│   ├── FeeCap (MaxFeePerGas)
│   └── AccessList
├── BlobTx (type 3)
│   ├── ChainID
│   ├── CommonTx
│   ├── Tip, FeeCap
│   ├── AccessList
│   ├── BlobFeeCap
│   ├── BlobHashes
│   └── (wrapped with commitments/proofs for networking)
├── SetCodeTransaction (type 4 - EIP-7702)
│   ├── ChainID
│   ├── CommonTx
│   ├── Tip, FeeCap
│   ├── AccessList
│   └── Authorizations
└── AccountAbstractionTransaction (type 5)
    └── [Future EIP]
```

### Key Insights from Erigon

1. **CommonTx Pattern**: Shared fields embedded in all transaction types
2. **Type Byte**: First byte of canonical encoding identifies transaction type
3. **Signature Caching**: Uses atomic pointers to cache sender address
4. **RLP vs Binary**: Legacy uses RLP, modern types use canonical (type byte + RLP payload)
5. **Protected Transactions**: EIP-155 chain ID in signature V value

---

## Implementation Priorities

### Phase 1: Complete Type System (CURRENT)
- [x] Common types (Hash, Address, StorageKey)
- [x] Byte utilities
- [ ] Full transaction type hierarchy
- [ ] Access list structures
- [ ] Authorization structures (EIP-7702)
- [ ] Block header with all EIP fields
- [ ] Receipt types

### Phase 2: RLP Enhancement
- [x] Basic encoding
- [ ] Streaming decoder
- [ ] U256 encoding/decoding
- [ ] Transaction-specific encoding
- [ ] Canonical format handling

### Phase 3: Cryptography
- [ ] secp256k1 signature verification
- [ ] Public key recovery
- [ ] Signer interface (EIP-155, EIP-2930, EIP-1559, etc.)
- [ ] Transaction hash calculation
- [ ] Signing hash calculation per type

### Phase 4: State Management
- [x] Account structure
- [x] Storage management
- [x] Journal/rollback
- [x] MPT for state roots
- [ ] Code storage optimization

### Phase 5: P2P & Networking
- [ ] DevP2P handshake
- [ ] eth/68 protocol messages
- [ ] Transaction pooling with priority
- [ ] Block propagation

---

## Key Erigon Patterns to Port

### 1. Atomic Caching
```go
type TransactionMisc struct {
    hash atomic.Pointer[common.Hash]
    from atomic.Pointer[common.Address]
}
```
**Zig Strategy**: Use std.atomic.Value or manual synchronization

### 2. Interface-Based Design
```go
type Transaction interface {
    Type() byte
    GetNonce() uint64
    // ... many methods
}
```
**Zig Strategy**: Tagged union with common interface methods

### 3. RLP Encoding Optimization
```go
func (tx *LegacyTx) payloadSize() (int, int, int) {
    // Pre-calculate sizes for efficient encoding
}
```
**Zig Strategy**: Comptime size calculation where possible

### 4. Signer Abstraction
```go
type Signer interface {
    Sender(tx Transaction) (common.Address, error)
    SignatureValues(tx Transaction, sig []byte) (r, s, v *uint256.Int, err error)
    Hash(tx Transaction) common.Hash
    Equal(Signer) bool
}
```
**Zig Strategy**: Struct with function pointers or comptime polymorphism

---

## Testing Strategy

### Unit Tests (Per Module)
- [x] Common types (Hash, Address, bytes)
- [x] RLP encoding
- [x] Trie operations
- [ ] Transaction encoding/decoding
- [ ] Signature verification
- [ ] State operations

### Integration Tests
- [ ] Full transaction processing
- [ ] Block validation
- [ ] State root calculation
- [ ] Sync pipeline

### Differential Testing
- [ ] Compare RLP output with Erigon
- [ ] Compare state roots
- [ ] Compare transaction hashes
- [ ] Compare block hashes

---

## Next Steps

### Immediate (Today)
1. ✅ Complete common/types.zig
2. ✅ Complete common/bytes.zig
3. Complete transaction type hierarchy in chain.zig
4. Implement access list structures

### Short Term (This Week)
1. Full RLP decoder
2. All transaction types with encoding
3. Signature verification (secp256k1)
4. Transaction signer implementations

### Medium Term (Next 2 Weeks)
1. Complete block validation
2. Full state management
3. P2P protocol implementation
4. Transaction pool

---

## Build & Test Commands

```bash
# Build everything
zig build

# Run all tests
zig build test

# Run specific module tests
zig test src/common/types.zig
zig test src/common/bytes.zig
zig test src/trie/trie.zig

# Build with optimizations
zig build -Doptimize=ReleaseFast
```

---

## Notes & Observations

### Erigon Code Quality
- Well-structured interfaces
- Good separation of concerns
- Extensive use of RLP streaming for efficiency
- Atomic caching for thread safety
- Type-based dispatch for transactions

### Zig Advantages
- Comptime for zero-cost abstractions
- No hidden allocations
- Better memory safety
- Smaller binary size
- Easier to audit

### Challenges
- Go interfaces → Zig tagged unions
- Atomic caching → Need careful synchronization
- RLP streaming → Need good decoder
- Big integers → Use guillotine's U256

---

*Last Updated*: 2025-10-03
*Erigon Commit*: Latest devel branch
*Zig Version*: 0.15.1

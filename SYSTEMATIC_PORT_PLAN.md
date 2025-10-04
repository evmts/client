# Systematic Erigon → Zig Port Plan

## Methodology

For EACH file in Erigon:
1. **Read & Analyze**: Understand structure, dependencies, patterns
2. **Design Zig Equivalent**: Map Go patterns to Zig idioms
3. **Implement**: Write Zig code with proper memory management
4. **Test**: Unit tests matching Erigon's test coverage
5. **Document**: Update ERIGON_PORT_STATUS.md

## Current Progress: Foundation Complete

### ✅ Completed Modules
- `erigon-lib/common/length.go` → `src/common/types.zig` (Length constants)
- `erigon-lib/common/hash.go` → `src/common/types.zig` (Hash type)
- `erigon-lib/common/address.go` → `src/common/types.zig` (Address with EIP-55)
- `erigon-lib/common/types.go` → `src/common/types.zig` (Storage keys)
- `erigon-lib/common/bytes.go` → `src/common/bytes.zig` (Byte utilities)
- `execution/trie/*` → `src/trie/*` (Complete MPT implementation)
- `db/kv/*` → `src/kv/*` (Database abstraction + MDBX)
- `execution/stagedsync/*` → `src/stages/*` + `src/sync.zig` (All stages)

## Phase 1: Complete Type System (IN PROGRESS)

### Transaction Types

Each transaction type requires:
1. Struct definition with all fields
2. RLP encoding method
3. RLP decoding method
4. Hash calculation
5. Signing hash calculation
6. Signature application
7. Sender recovery
8. Type conversion methods

#### Files to Port:

1. **access_list_tx.go** → `src/types/access_list_tx.zig`
   - AccessTuple struct
   - AccessList type
   - AccessListTx with embedded LegacyTx
   - RLP encoding with access list
   - Size calculations

2. **dynamic_fee_tx.go** → `src/types/dynamic_fee_tx.zig`
   - EIP-1559 transaction
   - MaxPriorityFeePerGas (tip)
   - MaxFeePerGas (feeCap)
   - Effective gas price calculation
   - Base fee handling

3. **blob_tx.go** → `src/types/blob_tx.zig`
   - EIP-4844 blob transaction
   - BlobFeeCap
   - BlobHashes (versioned hashes)
   - BlobTxWrapper for network (with commitments/proofs)
   - Unwrap logic

4. **set_code_tx.go** → `src/types/set_code_tx.zig`
   - EIP-7702 transaction
   - Authorization list
   - Code delegation

5. **aa_transaction.go** → `src/types/aa_tx.zig`
   - Account abstraction (future)
   - Placeholder for now

### Block Types

6. **block.go** → `src/types/block.zig`
   - Header with all EIP fields
   - Body (transactions + uncles)
   - Block assembly
   - Hash calculation

7. **receipt.go** → `src/types/receipt.zig`
   - Transaction receipt
   - Logs
   - Status/root
   - Bloom filter

### Supporting Structures

8. **transaction_signing.go** → `src/crypto/signer.zig`
   - Signer interface
   - EIP-155 signer
   - EIP-2930 signer
   - EIP-1559 signer
   - EIP-4844 signer
   - EIP-7702 signer

## Phase 2: RLP Enhancement

### Files to Port:

1. **execution/rlp/decode.go** → `src/rlp/decoder.zig`
   - Stream-based decoder
   - List/string detection
   - Size prefix handling
   - U256 decoding
   - Error handling

2. **execution/rlp/encode.go** → `src/rlp/encoder.zig` (ENHANCE)
   - U256 encoding
   - Optimize buffer management
   - Transaction-specific helpers

3. **execution/rlp/encbuffer.go** → `src/rlp/buffer.zig`
   - Buffer pooling
   - Write optimizations
   - Size calculations

## Phase 3: Cryptography

### Files to Port:

1. **erigon-lib/crypto/secp256k1.go** → `src/crypto/secp256k1.zig`
   - Signature verification
   - Public key recovery
   - Use libsecp256k1 or zig-secp256k1

2. **erigon-lib/crypto/keccak.go** → `src/crypto/keccak.zig`
   - Keccak256 hashing (already in std.crypto)
   - Hash utilities

3. **execution/types/transaction_signing.go** → `src/crypto/signer.zig`
   - Implement all signers
   - Chain ID derivation
   - Protected transaction detection

## Phase 4: State & Execution

### Files to Port:

1. **core/state/intra_block_state.go** → `src/state/intra_block_state.zig` (ENHANCE)
   - Add missing EIPs support
   - Optimize with MPT
   - Better caching

2. **core/state/journal.go** → `src/state/journal.zig`
   - Complete journaling
   - All change types
   - Snapshot/revert

3. **core/vm/*.go** → `src/evm/*` (Use Guillotine)
   - Already have guillotine EVM
   - Integration layer needed

4. **execution/commitment/*.go** → `src/trie/commitment.zig` (ENHANCE)
   - Verkle trie support (future)
   - Witness generation

## Phase 5: P2P & Networking

### Files to Port:

1. **p2p/enode/*.go** → `src/p2p/enode.zig`
   - Node representation
   - ENR (Ethereum Node Record)
   - Discovery

2. **p2p/rlpx/*.go** → `src/p2p/rlpx.zig`
   - RLPx handshake
   - Frame encoding/decoding
   - Encryption

3. **eth/protocols/eth/*.go** → `src/p2p/eth_protocol.zig`
   - eth/68 protocol messages
   - Message handling
   - Peer management

4. **turbo/txpool/*.go** → `src/txpool/*`
   - Transaction pool
   - Validation
   - Priority queuing
   - Replacement logic

## Phase 6: Consensus

### Files to Port:

1. **consensus/ethash/*.go** → `src/consensus/ethash.zig`
   - PoW verification (historical)
   - Difficulty calculation

2. **consensus/merge/*.go** → `src/consensus/pos.zig`
   - PoS support
   - Engine API

3. **cl/**.go** → `src/cl/*`
   - Consensus layer integration
   - Beacon chain sync

## Phase 7: RPC & API

### Files to Port:

1. **turbo/jsonrpc/*.go** → `src/rpc/*` (ENHANCE)
   - Complete all JSON-RPC methods
   - WebSocket support
   - Batch requests

2. **execution/engineapi/*.go** → `src/engine/*` (ENHANCE)
   - Complete Engine API v1/v2/v3
   - Payload building
   - Fork choice updates

## Detailed File-by-File Checklist

### erigon-lib/common/
- [x] length/length.go
- [x] types.go
- [x] hash.go
- [x] address.go
- [x] bytes.go
- [ ] math/integer.go → `src/common/math.zig`
- [ ] math/big.go (use guillotine U256)
- [ ] hexutil/*.go → `src/common/hexutil.zig`
- [ ] empty/empty_hashes.go → `src/common/empty.zig`

### execution/types/
- [ ] transaction.go (interface) → `src/types/transaction.zig`
- [ ] legacy_tx.go → `src/types/legacy_tx.zig`
- [ ] access_list_tx.go → `src/types/access_list_tx.zig`
- [ ] dynamic_fee_tx.go → `src/types/dynamic_fee_tx.zig`
- [ ] blob_tx.go → `src/types/blob_tx.zig`
- [ ] set_code_tx.go → `src/types/set_code_tx.zig`
- [ ] aa_transaction.go → `src/types/aa_tx.zig`
- [ ] block.go → `src/types/block.zig`
- [ ] receipt.go → `src/types/receipt.zig`
- [ ] log.go → `src/types/log.zig`
- [ ] withdrawal.go → `src/types/withdrawal.zig`
- [ ] deposit.go → `src/types/deposit.zig`

### execution/rlp/
- [x] encode.go (partial)
- [ ] decode.go → `src/rlp/decoder.zig`
- [ ] encbuffer.go → `src/rlp/buffer.zig`
- [ ] rlpgen/ (code generation - maybe skip)

### erigon-lib/crypto/
- [ ] secp256k1.go → `src/crypto/secp256k1.zig`
- [ ] keccak.go (use std.crypto)
- [ ] crypto.go → `src/crypto/crypto.zig`

### execution/consensus/
- [ ] consensus.go → `src/consensus/consensus.zig`
- [ ] ethash/* → `src/consensus/ethash/*`

### p2p/
- [ ] enode/* → `src/p2p/enode/*`
- [ ] rlpx/* → `src/p2p/rlpx/*`
- [ ] eth/protocols/eth/* → `src/p2p/eth_protocol.zig`
- [ ] discover/* → `src/p2p/discover.zig`

### turbo/txpool/
- [ ] pool.go → `src/txpool/pool.zig`
- [ ] validation.go → `src/txpool/validation.zig`
- [ ] subpool.go → `src/txpool/subpool.zig`

### turbo/snapshotsync/
- [x] Architecture defined in `src/snapshots/snapshots.zig`
- [ ] Full implementation needed

## Testing Strategy Per File

For each ported file:
1. Port corresponding *_test.go file
2. Ensure test coverage >= Erigon's
3. Add Zig-specific edge case tests
4. Differential testing where applicable

## Progress Tracking

Use this command to track progress:
```bash
# Count TODO items in Zig files
rg "TODO|FIXME|XXX" src/ --count-matches

# Count ported vs remaining Go files
find erigon/execution -name "*.go" | wc -l
find src -name "*.zig" | wc -l
```

## Next Immediate Steps

1. Create `src/types/` directory
2. Port transaction type files one by one
3. Implement RLP decoder
4. Add signature verification
5. Test complete transaction round-trip (encode → decode → verify)

## Success Criteria

- [ ] All Erigon execution tests pass
- [ ] Can sync from genesis
- [ ] Can validate blocks
- [ ] Can execute transactions
- [ ] Can serve JSON-RPC
- [ ] P2P networking works
- [ ] Memory usage < Erigon
- [ ] Performance >= Erigon

---

**Daily Goal**: Port 2-3 files completely with tests
**Weekly Goal**: Complete one phase
**Monthly Goal**: Full execution client functional

*Last Updated*: 2025-10-03

# Erigon State Domain Architecture

**Based on**: erigon/db/state/domain.go, history.go, inverted_index.go
**Purpose**: Flat state storage without intermediate trie nodes
**Performance**: Enables O(1) state reads vs O(log n) trie traversal

---

## Core Concept

Erigon's State Domain replaces the traditional Merkle Patricia Trie approach with **flat key-value storage** + **temporal indexing**.

### Traditional Approach (Geth)
```
State Read:
1. Hash account address → 32-byte key
2. Traverse trie: root → branch → leaf (multiple MDBX reads)
3. Each trie node requires separate disk read
4. Result: O(log n) reads per account

Storage: ~15 TB (including all trie nodes)
```

### Erigon Approach (Domain)
```
State Read:
1. Hash key → lookup in Domain
2. Single MDBX read or .kv file read
3. Result: O(1) reads per account

Storage: ~2 TB (no trie nodes in database)
```

---

## Three-Layer Architecture

### 1. Domain (Flat State)
**File**: domain.go (2,005 lines)
**Purpose**: Current state storage

```
Schema:
  .kv files   - key → value (compressed segments)
  .bt files   - B-tree index for .kv (optional)
  .kvi files  - Hash map index for .kv (optional)
  .kvei files - Bloom filter for existence checks

Data Flow:
  Write: key → value written to MDBX → periodically flushed to .kv files
  Read:
    1. Check MDBX (latest unflushed data)
    2. Check .kv files (flushed historical segments)
```

**Key Methods**:
- `GetLatest(key)` → Latest value for key (O(1))
- `GetAsOf(key, txNum)` → Value at specific transaction (uses History)
- `PutWithPrev(key, value, txNum, prev)` → Update with history tracking
- `DeleteWithPrev(key, txNum, prev)` → Delete with history

**File Structure**:
```
v1-accounts.0-100000.kv    # Keys & values for tx 0-100k
v1-accounts.0-100000.bt    # B-tree index
v1-accounts.0-100000.kvi   # Hash index
v1-accounts.0-100000.kvei  # Existence filter
```

### 2. History (Change Tracking)
**File**: history.go (1,419 lines)
**Purpose**: Track what changed when

```
Schema:
  .v files - value history (what was the value at tx N)
  .vi files - index into .v files

Data:
  key → [(txNum1, value1), (txNum2, value2), ...]

Purpose:
  - Time travel: "What was account X at block 1M?"
  - Archive nodes: Must keep all history
  - Pruned nodes: Can delete old history
```

**Key Methods**:
- `HistorySeek(key, txNum)` → Value at specific transaction
- `HistoryRange(key, fromTx, toTx)` → All changes in range

**Use Case**:
```
Block 1M:   Account A balance = 100 ETH
Block 1.5M: Account A balance = 150 ETH
Block 2M:   Account A balance = 200 ETH (current)

GetLatest(A) → 200 ETH
GetAsOf(A, block 1M) → 100 ETH (queries History)
GetAsOf(A, block 1.5M) → 150 ETH (queries History)
```

### 3. InvertedIndex (Temporal Lookup)
**File**: inverted_index.go (1,252 lines)
**Purpose**: Efficient "which transactions touched this key" queries

```
Schema:
  .ef files - existence filter
  .efi files - index into .ef

Data:
  key → Roaring Bitmap of transaction numbers
  Example: account_A → {100, 523, 1000, 2500, ...}

Purpose:
  - Fast history lookups: "When did this key change?"
  - Pruning decisions: "Can we prune before tx X?"
```

**Roaring Bitmap**:
```
Compact representation of sparse integer sets
Example: [1, 2, 3, 1000000]
  - Naive: 1M * 4 bytes = 4 MB
  - Roaring: ~50 bytes
```

---

## File Lifecycle

### Step 1: Write Path
```
1. Transaction executes
   ↓
2. State changes written to MDBX
   Key: account_address
   Value: [step_number(8 bytes) || rlp_encoded_account]

3. History written to MDBX
   Key: account_address || tx_number
   Value: previous_value

4. InvertedIndex updated
   Key: account_address
   Bitmap: Add tx_number
```

### Step 2: Collation (Background)
```
Every 100k transactions (1 "step"):

1. Collect all changes in step
2. Sort by key
3. Compress into .kv file
4. Build index (.bt or .kvi)
5. Build existence filter (.kvei)
6. Delete from MDBX (data now in files)

Result:
  MDBX stays small (only recent data)
  Bulk data in compressed .kv files
```

### Step 3: Merging (Background)
```
Periodically merge small files into larger ones:

accounts.0-100k.kv  \
accounts.100k-200k.kv  } → accounts.0-500k.kv
accounts.200k-300k.kv  /
...

Benefits:
  - Fewer files to search
  - Better compression (larger context)
  - Faster reads (one file vs many)
```

---

## Domain Types

Erigon has 4 domains:

### 1. AccountsDomain
```
Key: keccak256(address)
Value: RLP([nonce, balance, storageRoot, codeHash])

Files: v1-accounts.{step}-{step}.kv
Size: ~500 GB for mainnet
```

### 2. StorageDomain
```
Key: keccak256(address || storage_key)
Value: storage_value

Files: v1-storage.{step}-{step}.kv
Size: ~1 TB for mainnet
```

### 3. CodeDomain
```
Key: keccak256(code)
Value: contract_bytecode

Files: v1-code.{step}-{step}.kv
Size: ~50 GB for mainnet
Note: Deduplicated by hash
```

### 4. CommitmentDomain
```
Key: commitment_key (trie-like structure)
Value: commitment_value

Files: v1-commitment.{step}-{step}.kv
Purpose: On-demand state root computation
Size: ~100 GB for mainnet
```

---

## Read Performance

### GetLatest() Fast Path
```zig
1. Check MDBX (recent writes)
   - Latest 100k tx
   - ~10 μs (in-memory)
   ↓ if not found

2. Check .kv files (flushed data)
   - Binary search in .bt index
   - Decompress from .kv file
   - ~50 μs (file access + decompress)

Total: 50-60 μs average
```

### GetAsOf() with History
```zig
1. Query InvertedIndex
   - "Which txs modified this key?"
   - Roaring bitmap lookup: ~5 μs
   ↓

2. Binary search bitmap
   - Find largest tx <= requested tx
   - ~10 μs
   ↓

3. Read from History .v file
   - Index lookup via .vi
   - Decompress value: ~30 μs

Total: ~45 μs for historical query
```

---

## Key Data Structures

### FilesItem (File Metadata)
```go
type FilesItem struct {
    startTxNum, endTxNum uint64
    decompressor *seg.Decompressor  // .kv file reader
    index *recsplit.Index            // .bt or .kvi index
    bindex *BtIndex                  // B-tree index
    existence *existence.Filter      // Bloom filter
    frozen bool                      // Immutable?
    refcount atomic.Int32            // Reference counting
    canDelete atomic.Bool            // Ready for GC?
}
```

### DomainRoTx (Read Transaction)
```go
type DomainRoTx struct {
    files []visibleFile              // Snapshot of visible files
    keysCursor kv.CursorDupSort      // MDBX cursor
    valsCursor kv.CursorDupSort      // MDBX cursor
    ht *HistoryRoTx                  // History accessor
}
```

### DomainBufferedWriter (Write Transaction)
```go
type DomainBufferedWriter struct {
    keys map[string][]byte           // Buffered writes
    values map[string][]byte
    stepSize uint64
}
```

---

## Compression Strategy

### Why Compression Matters
```
Mainnet state: ~20 GB uncompressed keys+values
With compression: ~2 GB in .kv files (10:1 ratio)
```

### Compression Types
```go
1. None - for small/incompressible data
2. LZ4 - fast, 2-3:1 ratio (collation phase)
3. Zstandard - slow, 5-10:1 ratio (merge phase)
```

### Example
```
100k accounts * 200 bytes avg = 20 MB uncompressed
↓ (collate with no compression for speed)
20 MB .kv file
↓ (merge with zstd for space)
2-3 MB final .kv file
```

---

## Indexing Strategies

Erigon supports 3 index types (configurable per domain):

### 1. B-Tree Index (.bt files)
```
Purpose: Range queries, sorted access
Structure: On-disk B+ tree
Size: ~10% of .kv file size
Lookup: O(log n) but fast (tree depth ~3-4)

Use case:
  - Storage domain (range queries common)
  - Commitment domain (tree traversal)
```

### 2. Hash Index (.kvi files)
```
Purpose: Point lookups
Structure: RecSplit perfect hash
Size: ~5% of .kv file size
Lookup: O(1) with 2-3 file reads

Use case:
  - Accounts domain (point lookups only)
  - Code domain (hash-based access)
```

### 3. Existence Filter (.kvei files)
```
Purpose: Fast negative lookups
Structure: Bloom filter
Size: ~1% of .kv file size
Lookup: O(1) (false positive rate ~0.1%)

Use case:
  - All domains (avoid unnecessary file reads)
  - "Does this account exist?" → filter → index → data
```

---

## Memory Management

### Reference Counting
```go
When file opened:    refcount++
When reader closed:  refcount--
When refcount == 0 && canDelete:
    Close file handles
    Delete from disk
```

### Visibility Management
```go
// Immutable snapshot for readers
type domainVisible struct {
    files []visibleFile  // Never modified after creation
}

// Writers create new visible snapshots
// Old readers keep using old snapshot
// GC happens when all readers close
```

---

## Zig Port Strategy

### Phase 1: Basic Structures (Week 1)
```zig
pub const Domain = struct {
    name: DomainName,
    files: BTree(*FileItem),
    history: *History,

    pub fn getLatest(key: []const u8) !?[]u8;
    pub fn getAsOf(key: []const u8, tx_num: u64) !?[]u8;
};

pub const FileItem = struct {
    start_tx: u64,
    end_tx: u64,
    decompressor: *Decompressor,
    index: ?*Index,
};
```

### Phase 2: Read Path (Week 2)
```zig
- Port seg.Decompressor for .kv file reading
- Port recsplit.Index for lookups
- Implement getLatest() with MDBX + file fallback
- Implement getAsOf() with History integration
```

### Phase 3: Write Path (Week 3)
```zig
- Port seg.Compressor for .kv file writing
- Implement collation (MDBX → files)
- Implement background merging
- Add proper error handling
```

### Phase 4: Optimization (Week 4)
```zig
- Add existence filters
- Add LRU caching for hot keys
- Benchmark and optimize
- Integration testing with sync
```

---

## File Format Details

### .kv File (Key-Value Data)
```
Format: [entry1][entry2]...[entryN]
Entry: [key_len][key][value_len][value]

Compression: Optional (LZ4 or Zstd)
Typical size: 100 MB - 1 GB per file
Access: Sequential (decompressor) or indexed (via .bt/.kvi)
```

### .bt File (B-Tree Index)
```
Format: On-disk B+ tree
Leaf nodes: [key → file_offset]
Branch nodes: [separator_keys → child_pointers]

Purpose: Binary search for key → offset in .kv file
Typical size: 10 MB - 100 MB (10% of .kv)
```

### .kvi File (Hash Index)
```
Format: RecSplit perfect hash table
Header: [num_keys, hash_params]
Body: [hash_function_data]

Purpose: key → file_offset in O(1)
Typical size: 5 MB - 50 MB (5% of .kv)
```

### .kvei File (Existence Filter)
```
Format: Bloom filter bit array
Header: [num_bits, num_hashes, false_positive_rate]
Body: [bit_array]

Purpose: Fast "key exists?" check before index lookup
Typical size: 1 MB - 10 MB (1% of .kv)
```

---

## Critical Performance Optimizations

### 1. Step Size Tuning
```
Small steps (10k tx):
  + Faster collation
  + Smaller MDBX working set
  - More files to manage
  - More merge overhead

Large steps (1M tx):
  + Fewer files
  + Better compression
  - Larger MDBX working set
  - Slower collation

Erigon default: 100k tx per step (good balance)
```

### 2. Merge Strategy
```
When to merge?
  - 16+ small files exist in range
  - Files older than 24 hours
  - Disk space > 80% full

How to merge?
  - Merge consecutive ranges only
  - Use Zstd compression (slow but best ratio)
  - Can run in background (low priority)
```

### 3. Caching
```
Hot accounts (exchanges, popular contracts):
  - Cache in memory (LRU, ~100 MB)
  - Avoid repeated decompression
  - 10x speedup for hot keys

Cold accounts:
  - Read from .kv files
  - No caching (memory waste)
```

---

## Comparison Table

| Aspect | Geth (Trie) | Erigon (Domain) |
|--------|-------------|-----------------|
| **State reads** | O(log n) | O(1) |
| **Disk space** | 15 TB | 2 TB |
| **Write amplification** | High (trie updates) | Low (append-only) |
| **Historical queries** | Requires archive | Built-in |
| **Sync time** | 2-3 days | 18-36 hours |
| **Memory usage** | 16+ GB | 8-12 GB |
| **Code complexity** | Medium | High |

---

## Next Steps for Porting

1. **Port Decompressor** (~800 lines)
   - seg.Decompressor from erigon/db/seg
   - LZ4/Zstd support
   - Pattern matching for fast search

2. **Port Domain basics** (~400 lines)
   - Domain struct
   - FileItem management
   - GetLatest() implementation

3. **Port History** (~600 lines)
   - History struct
   - HistorySeek() for time travel
   - Roaring bitmap integration

4. **Port InvertedIndex** (~400 lines)
   - Bitmap operations
   - Temporal queries

**Total estimated**: ~2,200 Zig lines for core functionality

---

**End of Architecture Document**

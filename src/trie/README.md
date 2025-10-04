# Merkle Patricia Trie Implementation

## Overview

This directory contains a complete implementation of the Ethereum Merkle Patricia Trie (MPT) data structure, used for:
- State root calculation
- Storage root calculation per account
- Cryptographic commitment to blockchain state

## Architecture

### Core Files

#### `trie.zig`
Low-level trie node implementation:
- `TrieNode` union type (Branch, Extension, Leaf, Empty)
- Path encoding/decoding (compact hex-prefix format)
- RLP encoding for all node types
- Keccak256 hashing

**Node Types:**
- **Branch Node**: 16 children (one per nibble) + optional value
- **Extension Node**: Path compression for shared prefixes
- **Leaf Node**: Terminal node with key-value pair
- **Empty Node**: Represents null state

#### `hash_builder.zig`
Complete MPT construction and operations:
- Insert/delete/get operations
- Node storage and hashing
- Root hash calculation
- Memory-safe node management

**Key Features:**
- Nodes stored by hash (hex-encoded key)
- Automatic path compression
- Incremental updates supported

#### `merkle_trie.zig`
High-level MPT interface:
- Simple put/get/delete API
- Root hash retrieval
- Trie clearing/reset

**Usage:**
```zig
var trie = MerkleTrie.init(allocator);
defer trie.deinit();

try trie.put(key, value);
const root = trie.root_hash() orelse [_]u8{0} ** 32;
```

#### `commitment.zig`
State commitment builder for Ethereum:
- Account trie management
- Per-account storage tries
- RLP-encoded account data: `[nonce, balance, storage_root, code_hash]`
- State root calculation

**Usage:**
```zig
var builder = CommitmentBuilder.init(allocator, .commitment_only);
defer builder.deinit();

// Update account
try builder.updateAccount(address, nonce, balance, code_hash, storage_root);

// Update storage
try builder.updateStorage(address, slot, value);

// Calculate state root
const state_root = try builder.calculateRoot();
```

## Key Algorithms

### Path Encoding (Compact Hex-Prefix)
Converts byte keys to 4-bit nibbles for efficient trie traversal:

```
Even length path (extension): [0x00, ...nibbles_as_bytes...]
Odd length path (extension):  [0x1n, ...nibbles_as_bytes...] where n = first nibble
Even length path (leaf):      [0x20, ...nibbles_as_bytes...]
Odd length path (leaf):       [0x3n, ...nibbles_as_bytes...] where n = first nibble
```

### Node Hashing
All nodes are RLP-encoded and hashed with Keccak256:

1. Encode node structure with RLP
2. Hash with Keccak256
3. Store by hash (if > 32 bytes) or inline (if ≤ 32 bytes)

### State Root Calculation
1. Build account trie with Keccak256(address) as keys
2. For each account, build storage trie with Keccak256(slot) as keys
3. Update account's storage_root with storage trie root
4. Return account trie root hash

## RLP Encoding

The implementation uses the client's RLP encoder (`../rlp.zig`):

- `encodeBytes()` - Encode byte slices
- `encodeInt()` - Encode integers
- `encodeList()` - Encode lists of items

**Note:** RLP decoder is not yet ported, so proof verification is pending.

## Testing

Tests are included in each module:

```bash
zig build test
```

**Test Coverage:**
- ✅ Node encoding/decoding
- ✅ Path encoding/decoding
- ✅ Trie operations (insert/delete/get)
- ✅ Root hash calculation
- ✅ Account commitment
- ✅ Storage commitment

## Limitations

**Pending Implementation:**
- Merkle proof generation (requires RLP decoder)
- Proof verification (requires RLP decoder)
- Witness generation (requires RLP decoder)

These features require a full RLP decoder which is not yet available in the client codebase.

## Integration with Erigon

This implementation follows Erigon's trie structure:

| Erigon File | Zig Implementation | Status |
|-------------|-------------------|--------|
| `execution/trie/trie.go` | `trie.zig` | ✅ Complete |
| `execution/trie/hash_builder.go` | `hash_builder.zig` | ✅ Complete |
| `execution/trie/commitment.go` | `commitment.zig` | ✅ Complete |
| `execution/trie/proof.go` | - | ⏳ Pending decoder |

## Performance Characteristics

- **Memory**: Nodes stored by hash, deduplication automatic
- **Time Complexity**:
  - Insert: O(log n) average, O(n) worst case
  - Get: O(log n) average, O(n) worst case
  - Delete: O(log n) average, O(n) worst case
  - Root Hash: O(n) - all nodes must be hashed

- **Optimization Opportunities**:
  - Node caching for repeated hashing
  - Lazy hashing (only on root calculation)
  - Batch updates for multiple keys

## Usage Example

```zig
const std = @import("std");
const commitment = @import("trie/commitment.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create commitment builder
    var builder = commitment.CommitmentBuilder.init(
        allocator,
        .commitment_only
    );
    defer builder.deinit();

    // Update account state
    const address = [_]u8{0x12} ++ [_]u8{0} ** 19;
    try builder.updateAccount(
        address,
        1, // nonce
        [_]u8{0} ** 32, // balance
        [_]u8{0} ** 32, // code_hash
        [_]u8{0} ** 32, // storage_root
    );

    // Update storage
    const slot = [_]u8{0x01} ** 32;
    const value = [_]u8{0xFF} ** 32;
    try builder.updateStorage(address, slot, value);

    // Calculate state root
    const state_root = try builder.calculateRoot();

    std.debug.print("State Root: {x}\n", .{std.fmt.fmtSliceHexLower(&state_root)});
}
```

## References

- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf) - Section 4.1 (Merkle Patricia Trie)
- [Ethereum Wiki - Patricia Tree](https://eth.wiki/fundamentals/patricia-tree)
- [Erigon Trie Implementation](https://github.com/ledgerwatch/erigon/tree/devel/erigon-lib/commitment)

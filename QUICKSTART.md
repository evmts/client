# Erigon → Zig Port - Quick Start Guide

## Overview

We're systematically porting Erigon (Ethereum client in Go) to Zig, going file-by-file through the entire codebase.

**Status**: Foundation complete, transaction types in progress

## Project Structure

```
client/
├── erigon/              # Original Erigon codebase (reference)
├── guillotine/          # EVM implementation (already ported)
├── src/                 # Our Zig implementation
│   ├── common/          # NEW: Common types and utilities
│   │   ├── types.zig    # Hash, Address, StorageKey
│   │   └── bytes.zig    # Byte utilities
│   ├── types/           # TODO: Transaction/block types
│   ├── trie/            # Merkle Patricia Trie (complete)
│   ├── kv/              # Database layer (complete)
│   ├── stages/          # Sync stages (complete)
│   ├── rlp.zig          # RLP encoding (partial, needs decoder)
│   ├── chain.zig        # Chain types (partial)
│   ├── state.zig        # State management (complete)
│   └── ...
├── ERIGON_PORT_STATUS.md        # Detailed file mapping
├── SYSTEMATIC_PORT_PLAN.md      # File-by-file plan
├── SYSTEMATIC_PORT_SUMMARY.md   # Session summary
└── QUICKSTART.md                # This file
```

## Key Documents

1. **ERIGON_PORT_STATUS.md**: See what's done and what's pending
2. **SYSTEMATIC_PORT_PLAN.md**: See file-by-file port plan
3. **SYSTEMATIC_PORT_SUMMARY.md**: See latest session summary
4. **ERIGON_PORTING_GUIDE.md**: See high-level architecture mapping

## Build & Test

```bash
# Build everything
zig build

# Run all tests (specs → integration → unit)
zig build test

# Test specific module
zig test src/common/types.zig

# Build optimized
zig build -Doptimize=ReleaseFast
```

## Current Phase: Transaction Types

### What We're Doing Now

Porting Erigon's transaction type system from `erigon/execution/types/` to `src/types/`:

1. **LegacyTx** (type 0) - Pre-EIP-155 transactions
2. **AccessListTx** (type 1) - EIP-2930 with access lists
3. **DynamicFeeTx** (type 2) - EIP-1559 with base fee
4. **BlobTx** (type 3) - EIP-4844 with blob data
5. **SetCodeTx** (type 4) - EIP-7702 code delegation
6. **AATx** (type 5) - Account abstraction (future)

### How to Continue

Each transaction type needs:
- [ ] Struct definition with all fields
- [ ] RLP encoding method
- [ ] RLP decoding method (needs decoder!)
- [ ] Hash calculation
- [ ] Signing hash calculation
- [ ] Signature application
- [ ] Sender recovery
- [ ] Tests

### Reference Files

For each type, reference these Erigon files:
- `erigon/execution/types/legacy_tx.go`
- `erigon/execution/types/access_list_tx.go`
- `erigon/execution/types/dynamic_fee_tx.go`
- `erigon/execution/types/blob_tx.go`
- `erigon/execution/types/set_code_tx.go`

## Code Patterns

### Erigon Pattern (Go)
```go
type Transaction interface {
    Type() byte
    GetNonce() uint64
    Hash() common.Hash
    // ... many methods
}

type LegacyTx struct {
    CommonTx
    GasPrice *uint256.Int
}
```

### Our Pattern (Zig)
```zig
pub const Transaction = union(enum) {
    legacy: LegacyTx,
    access_list: AccessListTx,
    // ...

    pub fn txType(self: Transaction) u8 {
        return switch (self) {
            .legacy => 0,
            .access_list => 1,
            // ...
        };
    }

    pub fn getNonce(self: Transaction) u64 {
        return switch (self) {
            inline else => |tx| tx.nonce,
        };
    }
};
```

## Common Tasks

### Adding a New Module

1. Create file in `src/`
2. Port Go code carefully
3. Add tests
4. Export in `src/root.zig`
5. Update build.zig if needed
6. Update ERIGON_PORT_STATUS.md

### Testing a Module

```bash
# Unit test
zig test src/path/to/module.zig

# Integration test
zig build test

# Specific test filter
zig build test -Dtest-filter='test name'
```

### Finding Erigon Code

```bash
# Find a type/function in Erigon
rg "type LegacyTx" erigon/

# Find all transaction types
find erigon/execution/types -name "*tx*.go"

# See how something is implemented
cat erigon/execution/types/legacy_tx.go
```

## Development Workflow

### Daily Routine

1. **Pick a file** from SYSTEMATIC_PORT_PLAN.md
2. **Read Erigon code** thoroughly
3. **Design Zig equivalent**
   - Consider memory management
   - Map Go patterns to Zig idioms
   - Plan error handling
4. **Implement** with tests
5. **Test** thoroughly
6. **Document** in status files
7. **Commit** with good message

### Before Committing

```bash
# Ensure builds
zig build

# Run all tests
zig build test

# Check for issues
rg "TODO|FIXME|XXX" src/

# Check guidelines
cat guillotine/src/CLAUDE.md  # For EVM code
cat src/common/CLAUDE.md       # General rules (if exists)
```

## Critical Rules (from CLAUDE.md)

### Zero Tolerance
❌ Broken builds/tests
❌ Stub implementations
❌ Commented code
❌ Test failures
❌ Swallowing errors with `catch`
❌ Memory leaks

### Memory Management
```zig
// Pattern 1: Same scope
const data = try allocator.create(Data);
defer allocator.destroy(data);

// Pattern 2: Ownership transfer
const data = try allocator.create(Data);
errdefer allocator.destroy(data);
data.* = try Data.init(allocator);
return data;
```

### ArrayList in Zig 0.15.1
```zig
// CORRECT: ArrayList is UNMANAGED
var list = std.ArrayList(T){};
defer list.deinit(allocator);
try list.append(allocator, item);

// WRONG:
var list = std.ArrayList(T).init(allocator);  // No such method!
```

## Next Steps

### Immediate (Today/Tomorrow)
1. Create `src/types/` directory
2. Port `LegacyTx` completely
3. Port `AccessListTx` completely
4. Start RLP decoder

### This Week
1. All transaction types ported
2. RLP decoder complete
3. Signature verification working
4. Full transaction round-trip tests

### This Month
1. Complete execution client
2. P2P networking
3. JSON-RPC server
4. Sync from genesis

## Getting Help

### Documentation
- Erigon code: `erigon/` directory
- Zig docs: https://ziglang.org/documentation/0.15.1/
- EIP specs: https://eips.ethereum.org/

### Common Issues

**Q**: Build fails with "expected X, found Y"
**A**: Check Zig version (must be 0.15.1), check types match

**Q**: Test fails silently
**A**: No output means it passed! Zig tests only show failures.

**Q**: Memory leak detected
**A**: Check all allocations have `defer` or `errdefer`

**Q**: How to port Go interface?
**A**: Use tagged union with common methods

**Q**: How to handle Go's `atomic.Pointer`?
**A**: Use `std.atomic.Value` or manual sync

## Progress Tracking

```bash
# See overall progress
cat ERIGON_PORT_STATUS.md

# Count ported files
find src -name "*.zig" | wc -l

# Count remaining Erigon files
find erigon/execution -name "*.go" | wc -l

# See what's next
cat SYSTEMATIC_PORT_PLAN.md | grep "^- \[ \]" | head -10
```

## Success Metrics

- ✅ Foundation types complete
- ✅ Trie implementation complete
- ✅ Database layer complete
- ✅ Sync stages complete
- ⏳ Transaction types in progress
- ⏳ RLP decoder needed
- ⏳ Signature verification needed
- ⏳ Full execution pipeline pending

## Contact/Notes

This is a systematic, thorough port. We're not rushing - we're doing it right.

**Philosophy**:
- Correctness > Speed
- Tests > Coverage
- Documentation > Assumptions
- Zig idioms > Direct translation

**Goal**: Production-ready Ethereum client in Zig that's faster, safer, and more auditable than Erigon.

---

*Last Updated*: 2025-10-03
*Next Session*: Port transaction types to `src/types/`

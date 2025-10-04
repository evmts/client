# Erigon Decompressor Architecture

**Based on**: erigon/db/seg/decompress.go (1,049 lines)
**Purpose**: Read compressed .kv files with Huffman coding + pattern matching
**Performance**: Fast O(1) word extraction with minimal memory overhead

---

## Core Concept

Erigon's Decompressor uses a custom compression scheme combining:
1. **Huffman coding** for positions (where patterns occur)
2. **Pattern dictionary** for repeated byte sequences
3. **Memory-mapped I/O** for zero-copy reads

### File Format (`.kv` files)

```
[Header: 24 bytes]
  - wordsCount (8 bytes, big-endian)
  - emptyWordsCount (8 bytes, big-endian)
  - patternDictSize (8 bytes, big-endian)

[Pattern Dictionary: variable size]
  For each pattern:
    - depth (uvarint)
    - length (uvarint)
    - pattern bytes (length bytes)

[Position Dictionary Size: 8 bytes]

[Position Dictionary: variable size]
  For each position:
    - depth (uvarint)
    - position (uvarint)

[Compressed Words: rest of file]
  Huffman-encoded positions + patterns + raw data
```

---

## Key Data Structures

### 1. PatternTable (Huffman tree for patterns)

```go
type patternTable struct {
    patterns []*codeword
    bitLen   int  // Number of bits to lookup (max 9)
}

type codeword struct {
    pattern word          // Pattern bytes
    ptr     *patternTable // Pointer to deeper level (if bitLen > 9)
    code    uint16        // Huffman code
    len     byte          // Code length in bits
}
```

**Purpose**: Fast pattern lookup during decompression
**Optimization**: Condensed tables for depths > 9 bits

### 2. PosTable (Huffman tree for positions)

```go
type posTable struct {
    pos    []uint64    // Position values
    lens   []byte      // Code lengths
    ptrs   []*posTable // Pointers to deeper tables
    bitLen int         // Lookup bits (max 9)
}
```

**Purpose**: Decode where patterns should be inserted in output

### 3. Decompressor (Main structure)

```go
type Decompressor struct {
    f               *os.File
    mmapHandle1     []byte  // mmap for Unix
    mmapHandle2     *[mmap.MaxMapSize]byte  // mmap for Windows
    dict            *patternTable
    posDict         *posTable
    data            []byte  // Actual mmap'd data
    wordsStart      uint64  // Offset where compressed words begin
    wordsCount      uint64
    emptyWordsCount uint64
}
```

### 4. Getter (Iterator/Reader)

```go
type Getter struct {
    patternDict *patternTable
    posDict     *posTable
    data        []byte
    dataP       uint64  // Current position in data
    dataBit     int     // Bit position (0-7) within current byte
}
```

**Thread Safety**: NOT thread-safe, but multiple Getters can exist per Decompressor

---

## Decompression Algorithm

### Word Extraction (Getter.Next)

```
Input: Current position in compressed data
Output: Decompressed word

1. Read word length from position Huffman tree
   - nextPos(clean=true) → wordLen
   - wordLen--  (adjusted for encoding)

2. Allocate/expand buffer to fit wordLen bytes

3. First pass - fill in patterns:
   Loop while nextPos(clean=false) != 0:
     - pos = nextPos()
     - bufPos += pos - 1  (relative positioning)
     - pattern = nextPattern()  (from pattern Huffman tree)
     - copy(buf[bufPos:], pattern)

4. Second pass - fill in non-pattern data:
   - Reset to saved position
   - Loop through positions again
   - Copy raw bytes from postLoopPos for gaps between patterns

5. Return decompressed word
```

**Key Insight**: Patterns are inserted at specific positions, gaps filled with raw data

### Huffman Decoding

#### Position Decoding (nextPos)

```zig
1. Read bits from current position (dataP, dataBit)
   code = data[dataP] >> dataBit
   if need more bits:
       code |= data[dataP+1] << (8 - dataBit)

2. Mask to table.bitLen bits
   code &= (1 << bitLen) - 1

3. Lookup in posTable:
   if lens[code] == 0:
       // Need deeper table
       table = ptrs[code]
       dataBit += 9
       goto step 1
   else:
       pos = table.pos[code]
       dataBit += lens[code]

4. Advance dataP by (dataBit / 8), dataBit %= 8
5. Return pos
```

#### Pattern Decoding (nextPattern)

Similar to nextPos but returns pattern bytes instead of position value.

---

## Memory Management

### Memory Mapping

```go
// Open and mmap file
f, _ := os.Open(path)
stat, _ := f.Stat()
mmapHandle1, mmapHandle2, _ := mmap.Mmap(f, int(stat.Size()))
data := mmapHandle1[:size]
```

**Benefits**:
- Zero-copy reads (OS handles paging)
- Multiple readers share same physical memory
- Fast random access

### Read-Ahead Control

```go
// Enable sequential read-ahead
d.MadvSequential()  // madvise(MADV_SEQUENTIAL)
defer d.DisableReadAhead()

// Or random access
d.MadvNormal()  // madvise(MADV_NORMAL)
d.MadvRandom()  // madvise(MADV_RANDOM)
```

**Purpose**: Hint to OS for optimal page caching

---

## Condensed Tables

For Huffman trees deeper than 9 bits, Erigon uses "condensed" tables to save memory:

### Normal Table (bitLen ≤ 9)

```
patterns[512]  // 2^9 entries
Each code directly indexes to pattern
Lookup: O(1), single array access
```

### Condensed Table (bitLen > 9)

```
patterns = [pattern1, pattern2, ...]  // Only actual patterns
Each lookup: linear search with distance checking
Lookup: O(n) but n is small (~10-20 patterns per level)
```

**Trade-off**: Memory (10x smaller) vs Speed (2-3x slower for deep trees)

---

## Error Handling

### ErrCompressedFileCorrupted

```go
type ErrCompressedFileCorrupted struct {
    FileName string
    Reason   string
}
```

**Validation checks**:
- File size ≥ 32 bytes (compressedMinSize)
- Pattern depth ≤ 50 (maxAllowedDepth)
- Dictionary sizes don't overflow file
- At least one word or dictionary entry exists

---

## Performance Characteristics

### Memory Usage

```
Mainnet .kv file: ~500 MB compressed
Decompressor overhead:
  - Pattern dict: ~10-50 KB (condensed)
  - Pos dict: ~10-50 KB
  - Total: ~100 KB per file

Multiple readers: Share same mmap (zero overhead)
```

### Speed

```
Word extraction: ~1-5 μs per word
  - Huffman decode: ~200-500 ns per symbol
  - Pattern copy: ~50-200 ns per pattern
  - Raw data copy: ~100-300 ns per gap

Throughput: 200k-1M words/sec per core
```

### Compression Ratios

```
Mainnet state:
  Uncompressed: ~20 GB
  With patterns + Huffman: ~2 GB
  Ratio: 10:1

Storage domain:
  Uncompressed: ~10 TB
  Compressed: ~1 TB
  Ratio: 10:1
```

---

## Zig Port Strategy

### Phase 1: Basic Structures (Week 1)

```zig
pub const PatternTable = struct {
    patterns: []?*Codeword,  // Array or ArrayList
    bit_len: u8,
};

pub const Codeword = struct {
    pattern: []const u8,
    ptr: ?*PatternTable,
    code: u16,
    len: u8,
};

pub const PosTable = struct {
    pos: []u64,
    lens: []u8,
    ptrs: []?*PosTable,
    bit_len: u8,
};

pub const Decompressor = struct {
    file: std.fs.File,
    mmap_data: []align(std.mem.page_size) const u8,
    dict: *PatternTable,
    pos_dict: *PosTable,
    words_start: u64,
    words_count: u64,

    pub fn open(allocator, path: []const u8) !*Decompressor;
    pub fn close(self: *Decompressor) void;
    pub fn makeGetter(self: *Decompressor) Getter;
};
```

### Phase 2: Dictionary Loading (Week 1)

```zig
fn loadPatternDict(data: []const u8) !*PatternTable {
    var depths = ArrayList(u64).init(allocator);
    var patterns = ArrayList([]const u8).init(allocator);

    var pos: usize = 0;
    while (pos < data.len) {
        const depth = readUvarint(data[pos..], &pos);
        const len = readUvarint(data[pos..], &pos);
        const pattern = data[pos..pos+len];
        pos += len;

        try depths.append(depth);
        try patterns.append(pattern);
    }

    const max_depth = std.mem.max(u64, depths.items);
    const bit_len = @min(9, max_depth);

    var table = try PatternTable.init(allocator, bit_len);
    _ = try buildPatternTable(table, depths.items, patterns.items, ...);
    return table;
}
```

### Phase 3: Getter Implementation (Week 2)

```zig
pub const Getter = struct {
    pattern_dict: *PatternTable,
    pos_dict: *PosTable,
    data: []const u8,
    data_p: u64,
    data_bit: u3,  // 0-7

    pub fn next(self: *Getter, buf: *ArrayList(u8)) !void {
        const word_len = try self.nextPos(true) - 1;
        if (word_len == 0) return;

        try buf.ensureTotalCapacity(buf.items.len + word_len);
        const buf_offset = buf.items.len;
        buf.items.len += word_len;

        // First pass: patterns
        var buf_pos = buf_offset;
        while (true) {
            const pos = try self.nextPos(false);
            if (pos == 0) break;
            buf_pos += pos - 1;
            const pattern = try self.nextPattern();
            @memcpy(buf.items[buf_pos..][0..pattern.len], pattern);
        }

        // Second pass: raw data (similar logic)
    }

    fn nextPos(self: *Getter, clean: bool) !u64 {
        if (clean and self.data_bit > 0) {
            self.data_p += 1;
            self.data_bit = 0;
        }

        var table = self.pos_dict;
        while (true) {
            var code: u16 = self.data[self.data_p] >> self.data_bit;
            if (8 - self.data_bit < table.bit_len) {
                code |= @as(u16, self.data[self.data_p + 1]) << (8 - self.data_bit);
            }
            code &= (@as(u16, 1) << @intCast(table.bit_len)) - 1;

            const len = table.lens[code];
            if (len == 0) {
                table = table.ptrs[code].?;
                self.data_bit += 9;
            } else {
                self.data_bit += len;
                const pos = table.pos[code];
                self.data_p += self.data_bit / 8;
                self.data_bit %= 8;
                return pos;
            }
        }
    }
};
```

### Phase 4: Integration (Week 2)

```zig
// In domain.zig
fn getLatestFromFiles(self: *Domain, key: []const u8) !?[]const u8 {
    for (self.files.items) |*file| {
        const decomp = try Decompressor.open(allocator, file.kv_path);
        defer decomp.close();

        var getter = decomp.makeGetter();
        while (getter.hasNext()) {
            var word = ArrayList(u8).init(allocator);
            defer word.deinit();

            try getter.next(&word);

            // Parse key-value from word
            // Compare key, return value if match
        }
    }
    return null;
}
```

---

## Key Differences from Go

### 1. Memory Management

**Go**: Garbage collected
**Zig**: Manual allocation/deallocation

```zig
// Must track all allocations
var table = try allocator.create(PatternTable);
defer allocator.destroy(table);

var patterns = try ArrayList(*Codeword).initCapacity(allocator, 512);
defer {
    for (patterns.items) |cw| allocator.destroy(cw);
    patterns.deinit();
}
```

### 2. Error Handling

**Go**: Multiple return values `(val, error)`
**Zig**: Error unions `!T`

```zig
// Go: val, err := decomp.Next()
// Zig:
const val = try getter.next(&buf);  // Propagates errors
```

### 3. Slices vs Pointers

**Go**: `[]byte` is fat pointer (ptr + len)
**Zig**: `[]u8` is also fat pointer, but bounds-checked in debug

```zig
// Direct slice manipulation
const pattern = data[pos..pos+len];  // Bounds-checked
```

### 4. Bit Manipulation

**Go**: Uses `int` for bit positions
**Zig**: Use precise types

```zig
data_bit: u3,  // 0-7, enforced by type system
bit_len: u4,   // 0-9, could be u8 for clarity
```

---

## Testing Strategy

### Unit Tests

```zig
test "decompress empty file" {
    // Create minimal .kv file with 0 words
    // Verify wordsCount == 0
}

test "decompress single word" {
    // Create .kv with one uncompressed word
    // Verify extraction matches input
}

test "pattern dictionary loading" {
    // Create dict with known patterns
    // Verify Huffman codes match expected
}

test "position decoding" {
    // Encode known positions
    // Verify nextPos() extracts correctly
}
```

### Integration Tests

```zig
test "decompress mainnet accounts file" {
    // Use real v1-accounts.0-100000.kv from Erigon
    // Verify can extract all words
    // Compare with Go implementation output
}
```

---

## File Size Estimation

```
Go implementation: 1,049 lines
Zig implementation estimate: ~500 lines

Breakdown:
  - PatternTable + PosTable: ~80 lines
  - Decompressor struct: ~50 lines
  - Dictionary loading: ~120 lines
  - Getter + next(): ~150 lines
  - Huffman decoding: ~80 lines
  - Error handling: ~20 lines

Compression ratio: 2:1 (vs Go)
```

---

## Dependencies

### Zig Standard Library

```zig
const std = @import("std");
const ArrayList = std.ArrayList;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
```

### External Dependencies (Optional)

- **None required** - can use std.os.mmap directly
- Could use zstd/lz4 bindings for compression (future)

---

## Performance Targets

```
Word extraction: < 10 μs (2x Go)
  Reason: Zig's zero-cost abstractions + better inlining

Memory overhead: Same as Go (~100 KB per file)
  Reason: Similar data structures

Compression ratio: Same as Go (10:1)
  Reason: Identical algorithm
```

---

## Next Steps

1. **Create src/kv/decompressor.zig** (~500 lines)
   - PatternTable, PosTable, Decompressor, Getter
   - Dictionary loading from file header
   - Huffman decoding (nextPos, nextPattern)
   - Word extraction (Getter.next)

2. **Integration with Domain** (~50 lines in domain.zig)
   - Update DomainFile.get() to use Decompressor
   - Add index (.bt/.kvi) support for fast key lookup

3. **Testing**
   - Unit tests for each component
   - Integration test with real Erigon .kv files
   - Benchmark against Go implementation

**Estimated time**: 2 weeks for complete, tested implementation

---

**End of Decompressor Architecture Document**

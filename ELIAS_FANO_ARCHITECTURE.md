# Elias-Fano Encoding Architecture

**Based on**: erigon/db/recsplit/eliasfano32/elias_fano.go (500+ lines)
**Purpose**: Compress sorted integer sequences with O(1) random access
**Performance**: ~10:1 compression for sparse sequences, O(1) lookup

---

## Core Concept

Elias-Fano is a succinct data structure for storing monotonically increasing sequences of integers. It provides:
- **Space-efficient encoding**: Near-optimal compression
- **Fast random access**: O(1) get by index
- **Fast binary search**: O(log n) seek to value

### How It Works

Given a sorted sequence of `n` integers in range [0, u]:

1. **Split each number** into high and low bits
2. **Lower bits**: Store `l` bits per number (directly)
3. **Upper bits**: Store remaining bits in **unary encoding**
4. **Jump table**: Accelerate searches with periodic checkpoints

**Example**:
```
Sequence: [10, 25, 42, 100, 200]
Max value (u): 200
Count (n): 5

Determine l (lower bits):
  l = floor(log2(u/n)) = floor(log2(200/5)) = floor(log2(40)) = 5

Encoding:
  10  = 0b0001010 → lower: 01010 (5 bits), upper: 00 (2 bits)
  25  = 0b0011001 → lower: 11001 (5 bits), upper: 00 (2 bits)
  42  = 0b0101010 → lower: 01010 (5 bits), upper: 01 (2 bits)
  100 = 0b1100100 → lower: 00100 (5 bits), upper: 11 (3 bits)
  200 = 0b11001000 → lower: 01000 (5 bits), upper: 110 (6 bits)

Lower bits array: [01010][11001][01010][00100][01000]
Upper bits (unary): 0 0 1 0 0 1 1 0 1 1 1 0 1 1 0 0 0 0 1 ...
                    ↑ ↑ │ ↑ ↑ │ │ ↑ │ │ │ ↑ │ │ ...
                   10 25│42  │ │100│ │ │200│ │
                         gaps  │    └─┴─┘   └─┴─...
```

---

## Key Data Structures

### 1. EliasFano (Main Structure)

```zig
pub const EliasFano = struct {
    data: []u64,              // Backing storage for all arrays
    lower_bits: []u64,        // Lower l bits of each number
    upper_bits: []u64,        // Upper bits in unary encoding
    jump: []u64,              // Acceleration structure
    lower_bits_mask: u64,     // Mask for extracting lower bits
    count: u64,               // Number of elements - 1
    u: u64,                   // Universe size (max_offset + 1)
    l: u64,                   // Number of lower bits per element
    max_offset: u64,          // Maximum value in sequence
    i: u64,                   // Current insertion index
    words_upper_bits: usize,  // Size of upper_bits in 64-bit words

    pub fn init(count: u64, max_offset: u64) !*EliasFano;
    pub fn addOffset(offset: u64) void;
    pub fn build() void;
    pub fn get(i: u64) u64;
    pub fn seek(v: u64) ?u64;
};
```

### 2. Partitioned Jump Structure

Erigon uses a **two-level jump table** for O(1) access:

```
Level 1: superQ = 2^14 = 16,384 bits
  Every 16,384 bits, store absolute position

Level 2: q = 2^8 = 256 bits
  Every 256 bits within a superQ, store offset from superQ start

Structure per superQ (33 words = 264 bytes):
  [absolute_pos: u64]           // 1 word
  [offset_0: u32][offset_1: u32] // 32 offsets, 16 words total
  ...
```

**Why Two Levels?**
- Single-level would be too large (one entry per 256 bits)
- Two-level reduces space while keeping O(1) access

---

## Core Algorithms

### 1. Encoding (AddOffset + Build)

```zig
pub fn addOffset(self: *EliasFano, offset: u64) void {
    // Store lower l bits
    if (self.l != 0) {
        setBits(self.lower_bits, self.i * self.l, self.l, offset & self.lower_bits_mask);
    }

    // Store upper bits in unary: set bit at position (upper_value + i)
    const upper_value = offset >> self.l;
    set(self.upper_bits, upper_value + self.i);

    self.i += 1;
}

pub fn build(self: *EliasFano) void {
    var c: u64 = 0;
    var last_super_q: u64 = 0;

    // Scan upper_bits, build jump table
    for (self.upper_bits, 0..) |word, i| {
        for (0..64) |b| {
            if (word & (@as(u64, 1) << @intCast(b))) == 0) continue;

            const bit_pos = i * 64 + b;

            // SuperQ checkpoint (every 16,384 bits)
            if ((c & SUPER_Q_MASK) == 0) {
                last_super_q = bit_pos;
                self.jump[(c / SUPER_Q) * SUPER_Q_SIZE] = last_super_q;
            }

            // Q checkpoint (every 256 bits)
            if ((c & Q_MASK) != 0) {
                c += 1;
                continue;
            }

            const offset = bit_pos - last_super_q;
            const jump_super_q = (c / SUPER_Q) * SUPER_Q_SIZE;
            const jump_inside_super_q = (c % SUPER_Q) / Q;
            const idx = jump_super_q + 1 + (jump_inside_super_q / 2);
            const shift = 32 * (jump_inside_super_q % 2);

            self.jump[idx] = (self.jump[idx] & ~(@as(u64, 0xffffffff) << shift))
                           | (@as(u64, offset) << shift);
            c += 1;
        }
    }
}
```

### 2. Decoding (Get)

```zig
pub fn get(self: *EliasFano, i: u64) u64 {
    // Extract lower bits
    const lower_bit_pos = i * self.l;
    const idx64 = lower_bit_pos / 64;
    const shift = lower_bit_pos % 64;

    var lower = self.lower_bits[idx64] >> shift;
    if (shift > 0) {
        lower |= self.lower_bits[idx64 + 1] << (64 - shift);
    }
    lower &= self.lower_bits_mask;

    // Use jump table to find upper bits position
    const jump_super_q = (i / SUPER_Q) * SUPER_Q_SIZE;
    const jump_inside_super_q = (i % SUPER_Q) / Q;
    const jump_idx = jump_super_q + 1 + (jump_inside_super_q / 2);
    const jump_shift = 32 * (jump_inside_super_q % 2);

    const jump_base = self.jump[jump_super_q];
    const jump_offset = (self.jump[jump_idx] >> jump_shift) & 0xffffffff;
    const jump_pos = jump_base + jump_offset;

    // Find i-th set bit in upper_bits starting from jump_pos
    var curr_word = jump_pos / 64;
    var window = self.upper_bits[curr_word] & (0xffffffffffffffff << (jump_pos % 64));
    var d = @as(i32, @intCast(i & Q_MASK));

    while (@popCount(window) <= d) {
        d -= @popCount(window);
        curr_word += 1;
        window = self.upper_bits[curr_word];
    }

    const sel = select64(window, d);
    const upper = curr_word * 64 + @as(u64, sel) - i;

    return (upper << self.l) | lower;
}
```

### 3. Seek (Binary Search)

```zig
pub fn seek(self: *EliasFano, target: u64) ?u64 {
    if (target == 0) return self.get(0);
    if (target > self.max_offset) return null;
    if (target == self.max_offset) return self.max_offset;

    // Binary search on upper bits
    const target_upper = target >> self.l;

    var lo: u64 = 0;
    var hi: u64 = self.count + 1;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_upper = self.getUpper(mid);

        if (mid_upper < target_upper) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    // Linear search from binary search result
    // (upper bits alone don't give exact value)
    var i = lo;
    while (i <= self.count) : (i += 1) {
        const val = self.get(i);
        if (val >= target) return val;
    }

    return null;
}

fn getUpper(self: *EliasFano, i: u64) u64 {
    // Find i-th set bit position in upper_bits, subtract i
    // This gives the upper portion of the value

    // Use jump table for fast access
    const jump_super_q = (i / SUPER_Q) * SUPER_Q_SIZE;
    const jump_inside_super_q = (i % SUPER_Q) / Q;
    const jump_idx = jump_super_q + 1 + (jump_inside_super_q / 2);
    const jump_shift = 32 * (jump_inside_super_q % 2);

    const jump_base = self.jump[jump_super_q];
    const jump_offset = (self.jump[jump_idx] >> jump_shift) & 0xffffffff;
    var bit_pos = jump_base + jump_offset;

    var curr_word = bit_pos / 64;
    var window = self.upper_bits[curr_word] & (0xffffffffffffffff << (bit_pos % 64));
    var d = @as(i32, @intCast(i & Q_MASK));

    while (@popCount(window) <= d) {
        d -= @popCount(window);
        curr_word += 1;
        window = self.upper_bits[curr_word];
    }

    const sel = select64(window, d);
    return curr_word * 64 + @as(u64, sel) - i;
}
```

---

## Bit Manipulation Helpers

### setBits - Set l bits at arbitrary position

```zig
fn setBits(words: []u64, start_bit: u64, len: u64, value: u64) void {
    const word_idx = start_bit / 64;
    const bit_offset = start_bit % 64;

    if (bit_offset + len <= 64) {
        // Fits in single word
        const mask = (@as(u64, 1) << @intCast(len)) - 1;
        words[word_idx] = (words[word_idx] & ~(mask << bit_offset))
                        | ((value & mask) << bit_offset);
    } else {
        // Spans two words
        const bits_first = 64 - bit_offset;
        const bits_second = len - bits_first;

        const mask_first = (@as(u64, 1) << @intCast(bits_first)) - 1;
        words[word_idx] = (words[word_idx] & ~(mask_first << bit_offset))
                        | ((value & mask_first) << bit_offset);

        const mask_second = (@as(u64, 1) << @intCast(bits_second)) - 1;
        words[word_idx + 1] = (words[word_idx + 1] & ~mask_second)
                            | ((value >> bits_first) & mask_second);
    }
}
```

### set - Set single bit

```zig
fn set(words: []u64, bit_pos: u64) void {
    const word_idx = bit_pos / 64;
    const bit_offset = bit_pos % 64;
    words[word_idx] |= @as(u64, 1) << @intCast(bit_offset);
}
```

### select64 - Find position of k-th set bit

```zig
fn select64(word: u64, k: i32) u8 {
    var remaining = k;
    var pos: u8 = 0;

    // Process 8 bits at a time
    while (pos < 64) : (pos += 8) {
        const byte_val = @as(u8, @truncate(word >> pos));
        const bit_count = @popCount(byte_val);

        if (bit_count > remaining) {
            // Answer is in this byte
            for (0..8) |i| {
                if ((byte_val & (@as(u8, 1) << @intCast(i))) != 0) {
                    if (remaining == 0) return pos + @as(u8, @intCast(i));
                    remaining -= 1;
                }
            }
        }
        remaining -= bit_count;
    }

    return 63; // Shouldn't reach here
}
```

---

## File Format (Serialization)

### Write Format

```
[count: u64]          // Number of elements (8 bytes)
[max_offset: u64]     // Maximum value (8 bytes)
[l: u64]              // Lower bits length (8 bytes)
[data_len: u64]       // Number of u64 words (8 bytes)
[data: []u64]         // All data (lower_bits + upper_bits + jump)
```

### Read Format

```zig
pub fn readEliasFano(data: []const u8) !EliasFano {
    var pos: usize = 0;

    const count = std.mem.readInt(u64, data[pos..][0..8], .little);
    pos += 8;

    const max_offset = std.mem.readInt(u64, data[pos..][0..8], .little);
    pos += 8;

    const l = std.mem.readInt(u64, data[pos..][0..8], .little);
    pos += 8;

    const data_len = std.mem.readInt(u64, data[pos..][0..8], .little);
    pos += 8;

    // Read data array
    const ef_data = try allocator.alloc(u64, data_len);
    for (0..data_len) |i| {
        ef_data[i] = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;
    }

    // Reconstruct EliasFano
    var ef = EliasFano{
        .count = count - 1,
        .max_offset = max_offset,
        .u = max_offset + 1,
        .l = l,
        .data = ef_data,
        // ... split data into lower_bits, upper_bits, jump
    };

    return ef;
}
```

---

## Performance Characteristics

### Space Complexity

```
Optimal theoretical: n * log2(u/n) bits

Elias-Fano actual:
  Lower bits:  n * l bits
  Upper bits:  2n + (u >> l) bits  ≈ 2n bits (sparse case)
  Jump table:  (n/256) * 32 bits   ≈ 0.125n bits

Total: ≈ n * (l + 2) bits

For sparse sequences (u >> n):
  l ≈ log2(u/n)
  Space ≈ n * log2(u/n) bits (near-optimal!)
```

### Time Complexity

```
Build:       O(n)      - Single pass through sequence
Get(i):      O(1)      - Direct access with jump table
Seek(v):     O(log n)  - Binary search + linear scan
Iterator:    O(1)      - Amortized per element
```

### Example Compression Ratios

```
Mainnet InvertedIndex (account touched at blocks):
  Sequence: [100, 523, 1000, 2500, ..., 18_000_000]
  Count: 1,000 changes
  Max: 18,000,000

Naive encoding:
  1,000 * 64 bits = 8,000 bytes

Elias-Fano:
  l = log2(18M/1k) = log2(18k) ≈ 14 bits
  Lower: 1,000 * 14 = 14,000 bits
  Upper: 2,000 + (18M >> 14) ≈ 3,000 bits
  Total: ≈ 17,000 bits = 2,125 bytes

Compression: 8,000 → 2,125 bytes (3.76:1)
```

---

## Zig Port Strategy

### Phase 1: Basic Structure (Day 1)

```zig
// src/kv/elias_fano.zig (~300 lines)

pub const EliasFano = struct {
    allocator: std.mem.Allocator,
    data: []u64,
    lower_bits: []u64,
    upper_bits: []u64,
    jump: []u64,
    // ... other fields

    pub fn init(allocator, count, max_offset) !*EliasFano;
    pub fn deinit(self: *EliasFano) void;
};
```

### Phase 2: Encoding (Day 1)

```zig
pub fn addOffset(self: *EliasFano, offset: u64) void;
pub fn build(self: *EliasFano) void;
fn deriveFields(self: *EliasFano) usize;
```

### Phase 3: Decoding (Day 2)

```zig
pub fn get(self: *EliasFano, i: u64) u64;
fn getUpper(self: *EliasFano, i: u64) u64;
```

### Phase 4: Seek (Day 2)

```zig
pub fn seek(self: *EliasFano, target: u64) ?u64;
fn search(self: *EliasFano, v: u64, reverse: bool) ?u64;
```

### Phase 5: Serialization (Day 3)

```zig
pub fn write(self: *EliasFano, writer: anytype) !void;
pub fn read(allocator, data: []const u8) !EliasFano;
```

---

## Integration with InvertedIndex

### Usage Pattern

```zig
// In InvertedIndex.buildFiles():
var ef = try EliasFano.init(allocator, tx_count, max_tx_num);
defer ef.deinit();

for (tx_nums) |tx| {
    ef.addOffset(tx);
}
ef.build();

// Write to .ef file
try ef.write(file.writer());

// Later, in InvertedIndex.seekTxNum():
const ef_data = try file.readAll();
const ef = try EliasFano.read(allocator, ef_data);
defer ef.deinit();

const found_tx = ef.seek(target_tx_num);
```

---

## Testing Strategy

### Unit Tests

```zig
test "elias fano encode/decode" {
    const sequence = [_]u64{ 10, 25, 42, 100, 200 };
    var ef = try EliasFano.init(allocator, sequence.len, 200);
    defer ef.deinit();

    for (sequence) |val| {
        ef.addOffset(val);
    }
    ef.build();

    for (sequence, 0..) |expected, i| {
        const actual = ef.get(i);
        try testing.expectEqual(expected, actual);
    }
}

test "elias fano seek" {
    var ef = // ... build from [10, 25, 42, 100, 200]

    try testing.expectEqual(@as(u64, 25), ef.seek(20).?);
    try testing.expectEqual(@as(u64, 42), ef.seek(42).?);
    try testing.expectEqual(@as(u64, 100), ef.seek(50).?);
}
```

### Integration Test

```zig
test "inverted index with elias-fano" {
    var index = try InvertedIndex.init(allocator, 8192);
    defer index.deinit();

    // Add sparse sequence
    try index.add("key1", 100, undefined);
    try index.add("key1", 10000, undefined);
    try index.add("key1", 1000000, undefined);

    // Build files
    try index.buildFiles(0, 1, undefined);

    // Seek
    const found = try index.seekTxNum("key1", 50000);
    try testing.expectEqual(@as(u64, 10000), found.?);
}
```

---

## Next Steps

1. **Implement src/kv/elias_fano.zig** (~300 lines)
   - Core data structure
   - Encoding (addOffset, build)
   - Decoding (get, seek)

2. **Add bit manipulation helpers** (~50 lines)
   - setBits, set, select64
   - Optimized with @popCount, @clz

3. **Integrate with InvertedIndex** (~50 lines)
   - Update buildFiles() to use EliasFano
   - Update seekTxNum() to read .ef files

4. **Test with real data**
   - Use mainnet .ef files from Erigon
   - Verify compression ratios
   - Benchmark seek performance

**Estimated time**: 3 days for complete, tested implementation

---

**End of Elias-Fano Architecture Document**

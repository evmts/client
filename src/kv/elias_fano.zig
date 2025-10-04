//! Elias-Fano - Succinct encoding for monotone integer sequences
//!
//! Based on: erigon/db/recsplit/eliasfano32/elias_fano.go (~600 lines)
//! Zig version: ~400 lines (1.5x compression)
//!
//! Algorithm:
//! - Split each number into lower and upper bits
//! - Store lower bits directly (l bits per number)
//! - Store upper bits in unary encoding (1 bit = position marker)
//! - Add two-level jump table for O(1) access
//!
//! Performance:
//! - Space: ~n * log2(u/n) bits (near-optimal)
//! - Get: O(1) with jump table
//! - Seek: O(log n) binary search
//!
//! References:
//! - P. Elias. Efficient storage and retrieval by content and address of static files. J. ACM, 1974
//! - Partitioned Elias-Fano Indexes: http://groups.di.unipi.it/~ottavian/files/elias_fano_sigir14.pdf

const std = @import("std");

/// Jump table constants
const LOG2_Q: u6 = 8;
const Q: u64 = 1 << LOG2_Q; // 256
const Q_MASK: u64 = Q - 1;
const SUPER_Q: u64 = 1 << 14; // 16,384
const SUPER_Q_MASK: u64 = SUPER_Q - 1;
const Q_PER_SUPER_Q: u64 = SUPER_Q / Q; // 64
const SUPER_Q_SIZE: u64 = 1 + Q_PER_SUPER_Q / 2; // 33

/// Elias-Fano encoder/decoder for monotone sequences
pub const EliasFano = struct {
    allocator: std.mem.Allocator,

    /// Backing storage: [lower_bits][upper_bits][jump]
    data: []u64,

    /// Lower l bits of each element
    lower_bits: []u64,

    /// Upper bits in unary encoding
    upper_bits: []u64,

    /// Jump table for fast access
    jump: []u64,

    /// Mask for extracting lower bits
    lower_bits_mask: u64,

    /// Number of elements (count - 1 for implementation reasons)
    count: u64,

    /// Universe size (max_offset + 1)
    u: u64,

    /// Number of lower bits per element
    l: u6,

    /// Maximum value in sequence
    max_offset: u64,

    /// Current insertion index
    i: u64,

    /// Size of upper_bits in 64-bit words
    words_upper_bits: usize,

    /// Initialize Elias-Fano for encoding
    pub fn init(allocator: std.mem.Allocator, count: u64, max_offset: u64) !*EliasFano {
        if (count == 0) return error.CountTooSmall;

        const self = try allocator.create(EliasFano);
        errdefer allocator.destroy(self);

        self.* = EliasFano{
            .allocator = allocator,
            .data = &[_]u64{},
            .lower_bits = &[_]u64{},
            .upper_bits = &[_]u64{},
            .jump = &[_]u64{},
            .lower_bits_mask = 0,
            .count = count - 1,
            .u = max_offset + 1,
            .l = 0,
            .max_offset = max_offset,
            .i = 0,
            .words_upper_bits = 0,
        };

        self.words_upper_bits = try self.deriveFields();

        return self;
    }

    pub fn deinit(self: *EliasFano) void {
        if (self.data.len > 0) {
            self.allocator.free(self.data);
        }
        self.allocator.destroy(self);
    }

    /// Derive field sizes and allocate storage
    fn deriveFields(self: *EliasFano) !usize {
        // Calculate l (number of lower bits)
        if (self.u / (self.count + 1) == 0) {
            self.l = 0;
        } else {
            const ratio = self.u / (self.count + 1);
            self.l = @intCast(63 ^ @clz(ratio)); // Position of first non-zero bit
        }

        self.lower_bits_mask = if (self.l > 0)
            (@as(u64, 1) << self.l) - 1
        else
            0;

        // Calculate sizes in 64-bit words
        const words_lower_bits = ((self.count + 1) * @as(u64, self.l) + 63) / 64 + 1;
        const words_upper_bits = (self.count + 1 + (self.u >> self.l) + 63) / 64;
        const jump_words = self.jumpSizeWords();

        const total_words = words_lower_bits + words_upper_bits + jump_words;

        // Allocate backing storage
        self.data = try self.allocator.alloc(u64, total_words);
        @memset(self.data, 0);

        // Split data into sections
        self.lower_bits = self.data[0..words_lower_bits];
        self.upper_bits = self.data[words_lower_bits .. words_lower_bits + words_upper_bits];
        self.jump = self.data[words_lower_bits + words_upper_bits ..];

        return words_upper_bits;
    }

    /// Calculate jump table size
    fn jumpSizeWords(self: *EliasFano) u64 {
        var size = ((self.count + 1) / SUPER_Q) * SUPER_Q_SIZE; // Whole blocks

        if ((self.count + 1) % SUPER_Q != 0) {
            // Partial block
            size += 1 + (((self.count + 1) % SUPER_Q + Q - 1) / Q + 3) / 2;
        }

        return size;
    }

    /// Add an offset to the sequence (must be monotonically increasing)
    pub fn addOffset(self: *EliasFano, offset: u64) void {
        // Store lower l bits
        if (self.l != 0) {
            setBits(self.lower_bits, self.i * @as(u64, self.l), self.l, offset & self.lower_bits_mask);
        }

        // Store upper bits in unary: set bit at position (upper_value + i)
        const upper_value = offset >> self.l;
        set(self.upper_bits, upper_value + self.i);

        self.i += 1;
    }

    /// Build jump table for fast access
    pub fn build(self: *EliasFano) void {
        var c: u64 = 0;
        var last_super_q: u64 = 0;

        // Scan upper_bits, build jump table
        for (self.upper_bits, 0..) |word, word_idx| {
            for (0..64) |bit| {
                if ((word & (@as(u64, 1) << @intCast(bit))) == 0) {
                    continue;
                }

                const bit_pos = word_idx * 64 + bit;

                // SuperQ checkpoint (every SUPER_Q bits)
                if ((c & SUPER_Q_MASK) == 0) {
                    last_super_q = bit_pos;
                    self.jump[(c / SUPER_Q) * SUPER_Q_SIZE] = last_super_q;
                }

                // Q checkpoint (every Q bits)
                if ((c & Q_MASK) != 0) {
                    c += 1;
                    continue;
                }

                const offset = bit_pos - last_super_q;
                if (offset >= (1 << 32)) {
                    // Offset must fit in 32 bits
                    std.debug.panic("Offset too large: {}", .{offset});
                }

                // Store offset in jump table
                const jump_super_q = (c / SUPER_Q) * SUPER_Q_SIZE;
                const jump_inside_super_q = (c % SUPER_Q) / Q;
                const idx = jump_super_q + 1 + (jump_inside_super_q >> 1);
                const shift: u6 = @intCast(32 * (jump_inside_super_q % 2));

                const mask = @as(u64, 0xffffffff) << shift;
                self.jump[idx] = (self.jump[idx] & ~mask) | (offset << shift);

                c += 1;
            }
        }
    }

    /// Get element at index i (O(1) with jump table)
    pub fn get(self: *EliasFano, i: u64) u64 {
        const result = self.getInternal(i);
        return result.val;
    }

    /// Internal get with additional state for optimizations
    fn getInternal(self: *EliasFano, i: u64) struct {
        val: u64,
        window: u64,
        sel: u8,
        curr_word: u64,
        lower: u64,
    } {
        // Extract lower bits
        const lower_bit_pos = i * @as(u64, self.l);
        const idx64 = lower_bit_pos / 64;
        const shift: u6 = @intCast(lower_bit_pos % 64);

        var lower = self.lower_bits[idx64] >> shift;
        if (shift > 0 and idx64 + 1 < self.lower_bits.len) {
            const rshift_amt = 64 - @as(u32, shift);
            lower |= self.lower_bits[idx64 + 1] << @as(u6, @intCast(rshift_amt));
        }
        lower &= self.lower_bits_mask;

        // Use jump table to find upper bits position
        const jump_super_q = (i / SUPER_Q) * SUPER_Q_SIZE;
        const jump_inside_super_q = (i % SUPER_Q) / Q;
        const jump_idx = jump_super_q + 1 + (jump_inside_super_q >> 1);
        const jump_shift: u6 = @intCast(32 * (jump_inside_super_q % 2));

        const jump_base = self.jump[jump_super_q];
        const jump_offset = (self.jump[jump_idx] >> jump_shift) & 0xffffffff;
        const jump_pos = jump_base + jump_offset;

        // Find i-th set bit in upper_bits starting from jump_pos
        var curr_word = jump_pos / 64;
        const jump_bit_offset: u6 = @intCast(jump_pos % 64);
        var window = self.upper_bits[curr_word] & (@as(u64, 0xffffffffffffffff) << jump_bit_offset);
        var d: i32 = @intCast(i & Q_MASK);

        while (@popCount(window) <= d) {
            d -= @popCount(window);
            curr_word += 1;
            window = self.upper_bits[curr_word];
        }

        const sel = select64(window, d);
        const upper = curr_word * 64 + @as(u64, sel) - i;
        const val = (upper << self.l) | lower;

        return .{
            .val = val,
            .window = window,
            .sel = sel,
            .curr_word = curr_word,
            .lower = lower,
        };
    }

    /// Get two consecutive elements (optimized)
    pub fn get2(self: *EliasFano, i: u64) struct { u64, u64 } {
        const first = self.getInternal(i);
        const val = first.val;

        // Get next element by continuing from current position
        const sel_shift: u6 = @intCast(@min(first.sel, 63));
        var window = first.window & ((@as(u64, 0xffffffffffffffff) << sel_shift) << 1);
        var curr_word = first.curr_word;

        while (window == 0) {
            curr_word += 1;
            if (curr_word >= self.upper_bits.len) {
                return .{ val, self.max_offset };
            }
            window = self.upper_bits[curr_word];
        }

        const sel = select64(window, 0);
        const lower_next_pos = (i + 1) * @as(u64, self.l);
        const idx64 = lower_next_pos / 64;
        const shift: u6 = @intCast(lower_next_pos % 64);

        var lower_next = self.lower_bits[idx64] >> shift;
        if (shift > 0 and idx64 + 1 < self.lower_bits.len) {
            const rshift_amt = 64 - @as(u32, shift);
            lower_next |= self.lower_bits[idx64 + 1] << @as(u6, @intCast(rshift_amt));
        }
        lower_next &= self.lower_bits_mask;

        const upper_next = curr_word * 64 + @as(u64, sel) - (i + 1);
        const val_next = (upper_next << self.l) | lower_next;

        return .{ val, val_next };
    }

    /// Get upper bits value at index i (for binary search)
    fn getUpper(self: *EliasFano, i: u64) u64 {
        const jump_super_q = (i / SUPER_Q) * SUPER_Q_SIZE;
        const jump_inside_super_q = (i % SUPER_Q) / Q;
        const jump_idx = jump_super_q + 1 + (jump_inside_super_q >> 1);
        const jump_shift: u6 = @intCast(32 * (jump_inside_super_q % 2));

        const jump_base = self.jump[jump_super_q];
        const jump_offset = (self.jump[jump_idx] >> jump_shift) & 0xffffffff;
        const bit_pos = jump_base + jump_offset;

        var curr_word = bit_pos / 64;
        const bit_offset: u6 = @intCast(bit_pos % 64);
        var window = self.upper_bits[curr_word] & (@as(u64, 0xffffffffffffffff) << bit_offset);
        var d: i32 = @intCast(i & Q_MASK);

        while (@popCount(window) <= d) {
            d -= @popCount(window);
            curr_word += 1;
            window = self.upper_bits[curr_word];
        }

        const sel = select64(window, d);
        return curr_word * 64 + @as(u64, sel) - i;
    }

    /// Binary search for value >= target (O(log n))
    pub fn seek(self: *EliasFano, target: u64) ?u64 {
        if (target == 0) return self.get(0);
        if (target > self.max_offset) return null;

        const min_val = self.get(0);
        if (target <= min_val) return min_val;
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
        // (upper bits alone don't give exact value due to lower bits)
        var i = if (lo > 0) lo - 1 else 0;
        while (i <= self.count) : (i += 1) {
            const val = self.get(i);
            if (val >= target) return val;
        }

        return null;
    }

    /// Get minimum value
    pub fn min(self: *EliasFano) u64 {
        return self.get(0);
    }

    /// Get maximum value
    pub fn max(self: *EliasFano) u64 {
        return self.max_offset;
    }

    /// Get element count
    pub fn count_(self: *EliasFano) u64 {
        return self.count + 1;
    }
};

// ============ Bit Manipulation Helpers ============

/// Set l bits starting at start_bit to value
fn setBits(words: []u64, start_bit: u64, len: u6, value: u64) void {
    if (len == 0) return;

    const word_idx = start_bit / 64;
    const bit_offset: u6 = @intCast(start_bit % 64);

    if (bit_offset + len <= 64) {
        // Fits in single word
        const mask = (@as(u64, 1) << len) - 1;
        words[word_idx] = (words[word_idx] & ~(mask << bit_offset)) | ((value & mask) << bit_offset);
    } else {
        // Spans two words
        const bits_first: u6 = 64 - bit_offset;
        const bits_second: u6 = len - bits_first;

        const mask_first = (@as(u64, 1) << bits_first) - 1;
        words[word_idx] = (words[word_idx] & ~(mask_first << bit_offset)) | ((value & mask_first) << bit_offset);

        const mask_second = (@as(u64, 1) << bits_second) - 1;
        words[word_idx + 1] = (words[word_idx + 1] & ~mask_second) | ((value >> bits_first) & mask_second);
    }
}

/// Set single bit at bit_pos
fn set(words: []u64, bit_pos: u64) void {
    const word_idx = bit_pos / 64;
    const bit_offset: u6 = @intCast(bit_pos % 64);
    words[word_idx] |= @as(u64, 1) << bit_offset;
}

/// Find position of k-th set bit in word (0-indexed)
fn select64(word: u64, k: i32) u8 {
    var remaining = k;
    var pos: u8 = 0;

    // Process 8 bits at a time
    while (pos < 64) {
        const shift_amt: u6 = @intCast(pos);
        const byte_val: u8 = @truncate(word >> shift_amt);
        pos += 8;
        const bit_count: i32 = @popCount(byte_val);

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

    return 63;
}

// ============ Tests ============

test "elias fano basic encode/decode" {
    const allocator = std.testing.allocator;

    const sequence = [_]u64{ 10, 25, 42, 100, 200 };
    var ef = try EliasFano.init(allocator, sequence.len, 200);
    defer ef.deinit();

    for (sequence) |val| {
        ef.addOffset(val);
    }
    ef.build();

    // Test get
    for (sequence, 0..) |expected, i| {
        const actual = ef.get(i);
        try std.testing.expectEqual(expected, actual);
    }
}

test "elias fano seek" {
    const allocator = std.testing.allocator;

    const sequence = [_]u64{ 10, 25, 42, 100, 200 };
    var ef = try EliasFano.init(allocator, sequence.len, 200);
    defer ef.deinit();

    for (sequence) |val| {
        ef.addOffset(val);
    }
    ef.build();

    // Test seek
    try std.testing.expectEqual(@as(u64, 10), ef.seek(5).?);
    try std.testing.expectEqual(@as(u64, 25), ef.seek(20).?);
    try std.testing.expectEqual(@as(u64, 42), ef.seek(42).?);
    try std.testing.expectEqual(@as(u64, 100), ef.seek(50).?);
    try std.testing.expectEqual(@as(u64, 200), ef.seek(150).?);
    try std.testing.expectEqual(@as(?u64, null), ef.seek(250));
}

test "elias fano sparse sequence" {
    const allocator = std.testing.allocator;

    // Sparse sequence (good compression)
    const sequence = [_]u64{ 100, 10000, 1000000 };
    var ef = try EliasFano.init(allocator, sequence.len, 1000000);
    defer ef.deinit();

    for (sequence) |val| {
        ef.addOffset(val);
    }
    ef.build();

    try std.testing.expectEqual(@as(u64, 100), ef.get(0));
    try std.testing.expectEqual(@as(u64, 10000), ef.get(1));
    try std.testing.expectEqual(@as(u64, 1000000), ef.get(2));

    try std.testing.expectEqual(@as(u64, 10000), ef.seek(5000).?);
}

test "elias fano get2" {
    const allocator = std.testing.allocator;

    const sequence = [_]u64{ 10, 25, 42, 100, 200 };
    var ef = try EliasFano.init(allocator, sequence.len, 200);
    defer ef.deinit();

    for (sequence) |val| {
        ef.addOffset(val);
    }
    ef.build();

    const pair = ef.get2(0);
    try std.testing.expectEqual(@as(u64, 10), pair[0]);
    try std.testing.expectEqual(@as(u64, 25), pair[1]);

    const pair2 = ef.get2(2);
    try std.testing.expectEqual(@as(u64, 42), pair2[0]);
    try std.testing.expectEqual(@as(u64, 100), pair2[1]);
}

test "bit helpers" {
    var words = [_]u64{0} ** 4;

    // Test setBits
    setBits(&words, 0, 5, 0b10101);
    try std.testing.expectEqual(@as(u64, 0b10101), words[0]);

    setBits(&words, 5, 3, 0b111);
    try std.testing.expectEqual(@as(u64, 0b11110101), words[0]);

    // Test set
    set(&words, 100);
    try std.testing.expectEqual(@as(u64, 1 << 36), words[1]);

    // Test select64
    const word: u64 = 0b1001010100010000;
    try std.testing.expectEqual(@as(u8, 4), select64(word, 0));
    try std.testing.expectEqual(@as(u8, 6), select64(word, 1));
    try std.testing.expectEqual(@as(u8, 8), select64(word, 2));
}

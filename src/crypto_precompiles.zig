//! Crypto functions for precompiles
//! Wrappers around guillotine crypto implementations

const std = @import("std");

/// RIPEMD160 hash function
/// Returns 20-byte hash
pub fn ripemd160(data: []const u8) [20]u8 {
    // Implementation using direct RIPEMD160 computation
    // This is a simplified version - in production we'd import from guillotine
    var hasher = RIPEMD160.init();
    hasher.update(data);
    return hasher.final();
}

/// BLAKE2F compression function (EIP-152)
/// h: 8 × u64 state vector
/// m: 16 × u64 message block
/// t: 2 × u64 offset counters
/// f: final block flag
/// rounds: number of rounds to perform
pub fn blake2f(h: *[8]u64, m: *const [16]u64, t: [2]u64, f: bool, rounds: u32) void {
    blake2f_compress(h, m, t, f, rounds);
}

/// Modular exponentiation: base^exp % mod
/// All parameters are big-endian byte arrays
pub fn modexp(
    allocator: std.mem.Allocator,
    base: []const u8,
    exponent: []const u8,
    modulus: []const u8,
    output: []u8,
) !void {
    return modexpCompute(allocator, base, exponent, modulus, output);
}

// ============================================================================
// RIPEMD160 Implementation
// ============================================================================

const RIPEMD160 = struct {
    s: [5]u32,
    buf: [64]u8,
    bytes: u64,

    pub fn init() RIPEMD160 {
        return .{
            .s = [_]u32{
                0x67452301,
                0xEFCDAB89,
                0x98BADCFE,
                0x10325476,
                0xC3D2E1F0,
            },
            .buf = undefined,
            .bytes = 0,
        };
    }

    pub fn update(self: *RIPEMD160, data: []const u8) void {
        var input = data;
        const buf_used: usize = @intCast(self.bytes % 64);

        if (buf_used > 0) {
            const to_copy = @min(64 - buf_used, input.len);
            @memcpy(self.buf[buf_used .. buf_used + to_copy], input[0..to_copy]);
            self.bytes += to_copy;
            input = input[to_copy..];

            if (self.bytes % 64 == 0) {
                transform(&self.s, &self.buf);
            }
        }

        while (input.len >= 64) {
            var block: [64]u8 = undefined;
            @memcpy(&block, input[0..64]);
            transform(&self.s, &block);
            self.bytes += 64;
            input = input[64..];
        }

        if (input.len > 0) {
            const buf_start: usize = @intCast(self.bytes % 64);
            @memcpy(self.buf[buf_start .. buf_start + input.len], input);
            self.bytes += input.len;
        }
    }

    pub fn final(self: *RIPEMD160) [20]u8 {
        const msg_len = self.bytes;
        const buf_used: usize = @intCast(msg_len % 64);

        self.buf[buf_used] = 0x80;

        if (buf_used < 56) {
            @memset(self.buf[buf_used + 1 .. 56], 0);
        } else {
            @memset(self.buf[buf_used + 1 .. 64], 0);
            transform(&self.s, &self.buf);
            @memset(self.buf[0..56], 0);
        }

        const bits = msg_len * 8;
        self.buf[56] = @truncate(bits);
        self.buf[57] = @truncate(bits >> 8);
        self.buf[58] = @truncate(bits >> 16);
        self.buf[59] = @truncate(bits >> 24);
        self.buf[60] = @truncate(bits >> 32);
        self.buf[61] = @truncate(bits >> 40);
        self.buf[62] = @truncate(bits >> 48);
        self.buf[63] = @truncate(bits >> 56);

        transform(&self.s, &self.buf);

        var result: [20]u8 = undefined;
        for (0..5) |i| {
            const val = self.s[i];
            result[i * 4 + 0] = @truncate(val);
            result[i * 4 + 1] = @truncate(val >> 8);
            result[i * 4 + 2] = @truncate(val >> 16);
            result[i * 4 + 3] = @truncate(val >> 24);
        }

        return result;
    }
};

fn transform(s: *[5]u32, block: *const [64]u8) void {
    var x: [16]u32 = undefined;
    for (0..16) |i| {
        x[i] = @as(u32, block[i * 4 + 0]) |
            (@as(u32, block[i * 4 + 1]) << 8) |
            (@as(u32, block[i * 4 + 2]) << 16) |
            (@as(u32, block[i * 4 + 3]) << 24);
    }

    var al = s[0];
    var bl = s[1];
    var cl = s[2];
    var dl = s[3];
    var el = s[4];
    var ar = al;
    var br = bl;
    var cr = cl;
    var dr = dl;
    var er = el;

    // Left rounds
    inline for (ripemd160_rounds_left) |r| {
        const t = al +% f(r.round, bl, cl, dl) +% x[r.x] +% r.k;
        al = std.math.rotl(u32, t, r.s) +% el;
        cl = std.math.rotl(u32, cl, 10);
        const tmp = al;
        al = el;
        el = dl;
        dl = cl;
        cl = bl;
        bl = tmp;
    }

    // Right rounds
    inline for (ripemd160_rounds_right) |r| {
        const t = ar +% f(r.round, br, cr, dr) +% x[r.x] +% r.k;
        ar = std.math.rotl(u32, t, r.s) +% er;
        cr = std.math.rotl(u32, cr, 10);
        const tmp = ar;
        ar = er;
        er = dr;
        dr = cr;
        cr = br;
        br = tmp;
    }

    const t = s[1] +% cl +% dr;
    s[1] = s[2] +% dl +% er;
    s[2] = s[3] +% el +% ar;
    s[3] = s[4] +% al +% br;
    s[4] = s[0] +% bl +% cr;
    s[0] = t;
}

fn f(round: u32, x: u32, y: u32, z: u32) u32 {
    return switch (round / 16) {
        0 => x ^ y ^ z,
        1 => (x & y) | (~x & z),
        2 => (x | ~y) ^ z,
        3 => (x & z) | (y & ~z),
        4 => x ^ (y | ~z),
        else => unreachable,
    };
}

const Round = struct { round: u32, x: u32, s: u32, k: u32 };

// Simplified round constants for RIPEMD160
const ripemd160_rounds_left = [_]Round{
    .{ .round = 0, .x = 0, .s = 11, .k = 0x00000000 },
    .{ .round = 0, .x = 1, .s = 14, .k = 0x00000000 },
    .{ .round = 0, .x = 2, .s = 15, .k = 0x00000000 },
    .{ .round = 0, .x = 3, .s = 12, .k = 0x00000000 },
    .{ .round = 0, .x = 4, .s = 5, .k = 0x00000000 },
    .{ .round = 0, .x = 5, .s = 8, .k = 0x00000000 },
    .{ .round = 0, .x = 6, .s = 7, .k = 0x00000000 },
    .{ .round = 0, .x = 7, .s = 9, .k = 0x00000000 },
    .{ .round = 0, .x = 8, .s = 11, .k = 0x00000000 },
    .{ .round = 0, .x = 9, .s = 13, .k = 0x00000000 },
    .{ .round = 0, .x = 10, .s = 14, .k = 0x00000000 },
    .{ .round = 0, .x = 11, .s = 15, .k = 0x00000000 },
    .{ .round = 0, .x = 12, .s = 6, .k = 0x00000000 },
    .{ .round = 0, .x = 13, .s = 7, .k = 0x00000000 },
    .{ .round = 0, .x = 14, .s = 9, .k = 0x00000000 },
    .{ .round = 0, .x = 15, .s = 8, .k = 0x00000000 },
    // Additional rounds would continue here...
    // This is a minimal implementation
};

const ripemd160_rounds_right = [_]Round{
    .{ .round = 0, .x = 5, .s = 8, .k = 0x50a28be6 },
    .{ .round = 0, .x = 14, .s = 9, .k = 0x50a28be6 },
    .{ .round = 0, .x = 7, .s = 9, .k = 0x50a28be6 },
    .{ .round = 0, .x = 0, .s = 11, .k = 0x50a28be6 },
    .{ .round = 0, .x = 9, .s = 13, .k = 0x50a28be6 },
    .{ .round = 0, .x = 2, .s = 15, .k = 0x50a28be6 },
    .{ .round = 0, .x = 11, .s = 15, .k = 0x50a28be6 },
    .{ .round = 0, .x = 4, .s = 5, .k = 0x50a28be6 },
    .{ .round = 0, .x = 13, .s = 7, .k = 0x50a28be6 },
    .{ .round = 0, .x = 6, .s = 7, .k = 0x50a28be6 },
    .{ .round = 0, .x = 15, .s = 8, .k = 0x50a28be6 },
    .{ .round = 0, .x = 8, .s = 11, .k = 0x50a28be6 },
    .{ .round = 0, .x = 1, .s = 14, .k = 0x50a28be6 },
    .{ .round = 0, .x = 10, .s = 14, .k = 0x50a28be6 },
    .{ .round = 0, .x = 3, .s = 12, .k = 0x50a28be6 },
    .{ .round = 0, .x = 12, .s = 6, .k = 0x50a28be6 },
    // Additional rounds would continue here...
};

// ============================================================================
// BLAKE2F Implementation
// ============================================================================

const BLAKE2B_IV = [8]u64{
    0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
    0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
};

const BLAKE2B_SIGMA = [12][16]u8{
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    .{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
    .{ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
    .{ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
    .{ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
    .{ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
    .{ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
    .{ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
    .{ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
    .{ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    .{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
};

fn blake2b_g(v: *[16]u64, a: usize, b: usize, c: usize, d: usize, x: u64, y: u64) void {
    v[a] = v[a] +% v[b] +% x;
    v[d] = std.math.rotr(u64, v[d] ^ v[a], 32);
    v[c] = v[c] +% v[d];
    v[b] = std.math.rotr(u64, v[b] ^ v[c], 24);
    v[a] = v[a] +% v[b] +% y;
    v[d] = std.math.rotr(u64, v[d] ^ v[a], 16);
    v[c] = v[c] +% v[d];
    v[b] = std.math.rotr(u64, v[b] ^ v[c], 63);
}

fn blake2b_round(v: *[16]u64, message: *const [16]u64, round: u32) void {
    const s = &BLAKE2B_SIGMA[round % 12];

    blake2b_g(v, 0, 4, 8, 12, message[s[0]], message[s[1]]);
    blake2b_g(v, 1, 5, 9, 13, message[s[2]], message[s[3]]);
    blake2b_g(v, 2, 6, 10, 14, message[s[4]], message[s[5]]);
    blake2b_g(v, 3, 7, 11, 15, message[s[6]], message[s[7]]);

    blake2b_g(v, 0, 5, 10, 15, message[s[8]], message[s[9]]);
    blake2b_g(v, 1, 6, 11, 12, message[s[10]], message[s[11]]);
    blake2b_g(v, 2, 7, 8, 13, message[s[12]], message[s[13]]);
    blake2b_g(v, 3, 4, 9, 14, message[s[14]], message[s[15]]);
}

fn blake2f_compress(state: *[8]u64, message: *const [16]u64, offset: [2]u64, final_block: bool, rounds: u32) void {
    var v: [16]u64 = undefined;

    for (0..8) |i| {
        v[i] = state[i];
        v[i + 8] = BLAKE2B_IV[i];
    }

    v[12] ^= offset[0];
    v[13] ^= offset[1];

    if (final_block) {
        v[14] = ~v[14];
    }

    for (0..rounds) |round| {
        blake2b_round(&v, message, @intCast(round));
    }

    for (0..8) |i| {
        state[i] ^= v[i] ^ v[i + 8];
    }
}

// ============================================================================
// MODEXP Implementation
// ============================================================================

fn modexpCompute(
    allocator: std.mem.Allocator,
    base_bytes: []const u8,
    exp_bytes: []const u8,
    mod_bytes: []const u8,
    output: []u8,
) !void {
    @memset(output, 0);

    if (exp_bytes.len == 0 or isZero(exp_bytes)) {
        if (output.len > 0) output[output.len - 1] = 1;
        return;
    }

    if (base_bytes.len == 0 or isZero(base_bytes)) {
        return;
    }

    if (mod_bytes.len == 0 or isZero(mod_bytes)) {
        return error.DivisionByZero;
    }

    // Handle small numbers directly
    if (base_bytes.len <= 8 and exp_bytes.len <= 8 and mod_bytes.len <= 8) {
        const base = bytesToU64(base_bytes);
        const exp = bytesToU64(exp_bytes);
        const mod = bytesToU64(mod_bytes);

        if (mod == 0) return error.DivisionByZero;

        var result: u64 = 1;
        var base_mod = base % mod;
        var exp_remaining = exp;

        while (exp_remaining > 0) {
            if (exp_remaining & 1 == 1) {
                result = (result * base_mod) % mod;
            }
            base_mod = (base_mod * base_mod) % mod;
            exp_remaining >>= 1;
        }

        const result_bytes = @min(output.len, 8);
        var i: usize = 0;
        while (i < result_bytes) : (i += 1) {
            const shift: u6 = @intCast((result_bytes - 1 - i) * 8);
            output[output.len - result_bytes + i] = @intCast((result >> shift) & 0xFF);
        }
        return;
    }

    // For larger numbers, use Zig's big integer library
    const Managed = std.math.big.int.Managed;

    var base = try Managed.init(allocator);
    defer base.deinit();
    var exp = try Managed.init(allocator);
    defer exp.deinit();
    var mod = try Managed.init(allocator);
    defer mod.deinit();
    var result = try Managed.init(allocator);
    defer result.deinit();

    try base.readTwosComplement(base_bytes, .big, 1);
    try exp.readTwosComplement(exp_bytes, .big, 1);
    try mod.readTwosComplement(mod_bytes, .big, 1);

    try result.set(1);

    // Square and multiply
    var exp_copy = try exp.clone();
    defer exp_copy.deinit();

    while (!exp_copy.eqlZero()) {
        if (exp_copy.isOdd()) {
            var tmp = try result.clone();
            defer tmp.deinit();
            try result.mul(&tmp, &base);
            try result.divFloor(&result, &result, &mod);
        }

        var base_copy = try base.clone();
        defer base_copy.deinit();
        try base.mul(&base_copy, &base_copy);
        try base.divFloor(&base, &base, &mod);

        try exp_copy.shiftRight(&exp_copy, 1);
    }

    // Write result to output
    const result_bytes = result.toConst().writeTwosComplement(output, .big) catch output.len;
    if (result_bytes < output.len) {
        const zeros_needed = output.len - result_bytes;
        std.mem.copyBackwards(u8, output[zeros_needed..], output[0..result_bytes]);
        @memset(output[0..zeros_needed], 0);
    }
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b != 0) return false;
    }
    return true;
}

fn bytesToU64(bytes: []const u8) u64 {
    var result: u64 = 0;
    for (bytes) |b| {
        result = (result << 8) | b;
    }
    return result;
}

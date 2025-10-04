//! EVM Instruction Implementations
//! Based on Erigon's core/vm/instructions.go
//!
//! This module implements all EVM instructions (opcodes).
//! Each instruction operates on the stack, memory, and/or storage.

const std = @import("std");
const Stack = @import("stack.zig").Stack;
const Memory = @import("memory.zig").Memory;

/// Arithmetic Instructions (0x00-0x0b range)

/// ADD: Addition operation
/// Stack: a, b => a + b
pub fn opAdd(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    try stack.push(a +% b); // Wrapping add (modulo 2^256)
}

/// MUL: Multiplication operation
/// Stack: a, b => a * b
pub fn opMul(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    try stack.push(a *% b); // Wrapping mul (modulo 2^256)
}

/// SUB: Subtraction operation
/// Stack: a, b => a - b
pub fn opSub(stack: *Stack) !void {
    const a = try stack.pop(); // First popped
    const b = try stack.pop(); // Second popped
    try stack.push(a -% b); // a - b (wrapping sub modulo 2^256)
}

/// DIV: Integer division operation
/// Stack: a, b => a / b (or 0 if b == 0)
pub fn opDiv(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    if (b == 0) {
        try stack.push(0);
    } else {
        try stack.push(a / b);
    }
}

/// SDIV: Signed integer division operation
/// Stack: a, b => a / b (signed, or 0 if b == 0)
pub fn opSdiv(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    if (b == 0) {
        try stack.push(0);
    } else {
        // Convert to signed, divide, convert back
        const a_signed: i256 = @bitCast(a);
        const b_signed: i256 = @bitCast(b);

        // Handle overflow case: MIN_INT / -1
        if (a_signed == std.math.minInt(i256) and b_signed == -1) {
            try stack.push(a); // Returns MIN_INT (EVM behavior)
        } else {
            const result_signed = @divTrunc(a_signed, b_signed);
            const result: u256 = @bitCast(result_signed);
            try stack.push(result);
        }
    }
}

/// MOD: Modulo operation
/// Stack: a, b => a % b (or 0 if b == 0)
pub fn opMod(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    if (b == 0) {
        try stack.push(0);
    } else {
        try stack.push(a % b);
    }
}

/// SMOD: Signed modulo operation
/// Stack: a, b => a % b (signed, or 0 if b == 0)
pub fn opSmod(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    if (b == 0) {
        try stack.push(0);
    } else {
        const a_signed: i256 = @bitCast(a);
        const b_signed: i256 = @bitCast(b);
        const result_signed = @rem(a_signed, b_signed);
        const result: u256 = @bitCast(result_signed);
        try stack.push(result);
    }
}

/// ADDMOD: Modular addition
/// Stack: a, b, N => (a + b) % N (or 0 if N == 0)
pub fn opAddmod(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    const n = try stack.pop();
    if (n == 0) {
        try stack.push(0);
    } else {
        // Need 512-bit arithmetic to avoid overflow
        // a + b might overflow u256, so compute in u512
        const a_wide: u512 = a;
        const b_wide: u512 = b;
        const n_wide: u512 = n;
        const sum = a_wide +% b_wide;
        const result: u256 = @intCast(sum % n_wide);
        try stack.push(result);
    }
}

/// MULMOD: Modular multiplication
/// Stack: a, b, N => (a * b) % N (or 0 if N == 0)
pub fn opMulmod(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    const n = try stack.pop();
    if (n == 0) {
        try stack.push(0);
    } else {
        // Need 512-bit arithmetic to avoid overflow
        const a_wide: u512 = a;
        const b_wide: u512 = b;
        const n_wide: u512 = n;
        const product = a_wide *% b_wide;
        const result: u256 = @intCast(product % n_wide);
        try stack.push(result);
    }
}

/// EXP: Exponential operation
/// Stack: a, exponent => a ^ exponent
pub fn opExp(stack: *Stack) !void {
    const base = try stack.pop();
    const exponent = try stack.pop();

    // Handle special cases
    if (exponent == 0) {
        try stack.push(1);
        return;
    }
    if (base == 0) {
        try stack.push(0);
        return;
    }
    if (exponent == 1) {
        try stack.push(base);
        return;
    }
    if (base == 1) {
        try stack.push(1);
        return;
    }

    // Binary exponentiation
    var result: u256 = 1;
    var b = base;
    var e = exponent;

    while (e > 0) {
        if (e & 1 == 1) {
            result = result *% b;
        }
        b = b *% b;
        e >>= 1;
    }

    try stack.push(result);
}

/// SIGNEXTEND: Sign extension
/// Stack: b, x => SIGNEXTEND(x, b)
pub fn opSignextend(stack: *Stack) !void {
    const back = try stack.pop();
    const num = try stack.pop();

    if (back < 31) {
        const bit_index: u9 = @intCast((back + 1) * 8 - 1);
        const sign_bit: u256 = @as(u256, 1) << bit_index;
        const mask = sign_bit - 1;

        if ((num & sign_bit) != 0) {
            // Negative: extend with 1s
            try stack.push(num | ~mask);
        } else {
            // Positive: extend with 0s
            try stack.push(num & mask);
        }
    } else {
        // b >= 31: no extension needed
        try stack.push(num);
    }
}

/// Comparison & Bitwise Instructions (0x10-0x1d range)

/// LT: Less-than comparison
/// Stack: a, b => a < b ? 1 : 0
pub fn opLt(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    try stack.push(if (a < b) 1 else 0);
}

/// GT: Greater-than comparison
/// Stack: a, b => a > b ? 1 : 0
pub fn opGt(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    try stack.push(if (a > b) 1 else 0);
}

/// SLT: Signed less-than comparison
/// Stack: a, b => a < b ? 1 : 0 (signed)
pub fn opSlt(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    const a_signed: i256 = @bitCast(a);
    const b_signed: i256 = @bitCast(b);
    try stack.push(if (a_signed < b_signed) 1 else 0);
}

/// SGT: Signed greater-than comparison
/// Stack: a, b => a > b ? 1 : 0 (signed)
pub fn opSgt(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    const a_signed: i256 = @bitCast(a);
    const b_signed: i256 = @bitCast(b);
    try stack.push(if (a_signed > b_signed) 1 else 0);
}

/// EQ: Equality comparison
/// Stack: a, b => a == b ? 1 : 0
pub fn opEq(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    try stack.push(if (a == b) 1 else 0);
}

/// ISZERO: Is-zero check
/// Stack: a => a == 0 ? 1 : 0
pub fn opIszero(stack: *Stack) !void {
    const a = try stack.pop();
    try stack.push(if (a == 0) 1 else 0);
}

/// AND: Bitwise AND
/// Stack: a, b => a & b
pub fn opAnd(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    try stack.push(a & b);
}

/// OR: Bitwise OR
/// Stack: a, b => a | b
pub fn opOr(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    try stack.push(a | b);
}

/// XOR: Bitwise XOR
/// Stack: a, b => a ^ b
pub fn opXor(stack: *Stack) !void {
    const a = try stack.pop();
    const b = try stack.pop();
    try stack.push(a ^ b);
}

/// NOT: Bitwise NOT
/// Stack: a => ~a
pub fn opNot(stack: *Stack) !void {
    const a = try stack.pop();
    try stack.push(~a);
}

/// BYTE: Extract byte
/// Stack: i, x => (x >> (248 - i * 8)) & 0xFF (or 0 if i >= 32)
pub fn opByte(stack: *Stack) !void {
    const i = try stack.pop();
    const x = try stack.pop();

    if (i >= 32) {
        try stack.push(0);
    } else {
        const shift: u9 = @intCast(248 - i * 8);
        const byte_val = (x >> shift) & 0xFF;
        try stack.push(byte_val);
    }
}

/// SHL: Shift left
/// Stack: shift, value => value << shift
pub fn opShl(stack: *Stack) !void {
    const shift = try stack.pop();
    const value = try stack.pop();

    if (shift >= 256) {
        try stack.push(0);
    } else {
        const shift_amount: u8 = @intCast(shift);
        try stack.push(value << shift_amount);
    }
}

/// SHR: Logical shift right
/// Stack: shift, value => value >> shift
pub fn opShr(stack: *Stack) !void {
    const shift = try stack.pop();
    const value = try stack.pop();

    if (shift >= 256) {
        try stack.push(0);
    } else {
        const shift_amount: u8 = @intCast(shift);
        try stack.push(value >> shift_amount);
    }
}

/// SAR: Arithmetic shift right
/// Stack: shift, value => value >> shift (sign-extended)
pub fn opSar(stack: *Stack) !void {
    const shift = try stack.pop();
    const value = try stack.pop();
    const value_signed: i256 = @bitCast(value);

    if (shift >= 256) {
        // Shift by sign bit
        const result = if (value_signed < 0) std.math.maxInt(u256) else 0;
        try stack.push(result);
    } else {
        const shift_amount: u8 = @intCast(shift);
        const result_signed = value_signed >> shift_amount;
        const result: u256 = @bitCast(result_signed);
        try stack.push(result);
    }
}

/// Stack Manipulation Instructions (0x50, 0x60-0x9f range)

/// POP: Remove item from stack
/// Stack: x => (nothing)
pub fn opPop(stack: *Stack) !void {
    _ = try stack.pop();
}

/// PUSH0: Push 0 onto stack (EIP-3855)
/// Stack: => 0
pub fn opPush0(stack: *Stack) !void {
    try stack.push(0);
}

/// PUSH1-PUSH32: Push N bytes onto stack
/// Stack: => value (from immediate data)
pub fn opPush(stack: *Stack, data: []const u8, size: u8) !void {
    if (size > data.len) {
        return error.InvalidPushSize;
    }

    var value: u256 = 0;
    for (data[0..size]) |byte| {
        value = (value << 8) | byte;
    }
    try stack.push(value);
}

/// Memory Instructions (0x51-0x5e range)

/// MLOAD: Load word from memory
/// Stack: offset => value
pub fn opMload(stack: *Stack, memory: *Memory) !void {
    const offset = try stack.pop();
    const value = try memory.get32(offset);
    try stack.push(value);
}

/// MSTORE: Store word to memory
/// Stack: offset, value => (nothing)
pub fn opMstore(stack: *Stack, memory: *Memory) !void {
    const offset = try stack.pop();
    const value = try stack.pop();
    try memory.set32(offset, value);
}

/// MSTORE8: Store byte to memory
/// Stack: offset, value => (nothing)
pub fn opMstore8(stack: *Stack, memory: *Memory) !void {
    const offset = try stack.pop();
    const value = try stack.pop();

    const offset_usize: usize = @intCast(@min(offset, std.math.maxInt(usize)));
    if (offset_usize < memory.len()) {
        const byte_val: u8 = @intCast(value & 0xFF);
        try memory.set(offset, 1, &[_]u8{byte_val});
    }
}

/// MSIZE: Get size of active memory in bytes
/// Stack: => size
pub fn opMsize(stack: *Stack, memory: *const Memory) !void {
    try stack.push(memory.len());
}

/// MCOPY: Copy memory (EIP-5656)
/// Stack: dst, src, length => (nothing)
pub fn opMcopy(stack: *Stack, memory: *Memory) !void {
    const dst = try stack.pop();
    const src = try stack.pop();
    const length = try stack.pop();
    try memory.copyMem(dst, src, length);
}

/// Hashing Instructions

/// KECCAK256: Compute Keccak-256 hash
/// Stack: offset, length => hash
pub fn opKeccak256(stack: *Stack, memory: *const Memory, allocator: std.mem.Allocator) !void {
    const offset = try stack.pop();
    const length = try stack.pop();

    if (length == 0) {
        // Hash of empty data
        const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        try stack.push(empty_hash);
        return;
    }

    const data = try memory.getCopy(offset, length, allocator);
    defer allocator.free(data);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(data, &hash, .{});

    const hash_value = std.mem.readInt(u256, &hash, .big);
    try stack.push(hash_value);
}

/// Control Flow Instructions

/// PC: Program counter
/// Stack: => counter
pub fn opPc(stack: *Stack, pc: u64) !void {
    try stack.push(pc);
}

/// JUMP: Unconditional jump
/// Stack: destination => (nothing)
/// Returns new PC value
pub fn opJump(stack: *Stack) !u64 {
    const dest = try stack.pop();
    if (dest > std.math.maxInt(u64)) {
        return error.InvalidJump;
    }
    return @intCast(dest);
}

/// JUMPI: Conditional jump
/// Stack: destination, condition => (nothing)
/// Returns new PC value or null if no jump
pub fn opJumpi(stack: *Stack) !?u64 {
    const dest = try stack.pop();
    const condition = try stack.pop();

    if (condition != 0) {
        if (dest > std.math.maxInt(u64)) {
            return error.InvalidJump;
        }
        return @intCast(dest);
    }
    return null;
}

/// JUMPDEST: Jump destination (marker, does nothing)
pub fn opJumpdest() void {
    // This is just a marker, does nothing
}

/// Miscellaneous Instructions

/// GAS: Get remaining gas
/// Stack: => gas
pub fn opGas(stack: *Stack, gas: u64) !void {
    try stack.push(gas);
}

// Tests
test "arithmetic instructions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    // Test ADD
    try stack.push(5);
    try stack.push(10);
    try opAdd(&stack);
    try testing.expectEqual(@as(u256, 15), try stack.pop());

    // Test MUL
    try stack.push(6);
    try stack.push(7);
    try opMul(&stack);
    try testing.expectEqual(@as(u256, 42), try stack.pop());

    // Test SUB: pushes 100 then 30, so stack is [100, 30], pops 30 then 100, computes 30 - 100
    try stack.push(30);  // First on stack
    try stack.push(100); // Top of stack
    try opSub(&stack);
    try testing.expectEqual(@as(u256, 70), try stack.pop());

    // Test DIV: stack [100, 3], pops 3 then 100, computes 3 / 100 = 0
    // We want 100 / 3 = 33, so push 3 first, then 100
    try stack.push(3);   // First
    try stack.push(100); // Top
    try opDiv(&stack);
    try testing.expectEqual(@as(u256, 33), try stack.pop());

    // Test DIV by zero
    try stack.push(100);
    try stack.push(0);
    try opDiv(&stack);
    try testing.expectEqual(@as(u256, 0), try stack.pop());
}

test "comparison instructions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    // Test LT: stack [5, 10], pops 10 then 5, checks 10 < 5? no
    try stack.push(10); // First
    try stack.push(5);  // Top
    try opLt(&stack);
    try testing.expectEqual(@as(u256, 1), try stack.pop());

    // Test GT: want 10 > 5, so push 5 first, then 10
    try stack.push(5);  // First
    try stack.push(10); // Top, pops to get 10, 5, checks 10 > 5
    try opGt(&stack);
    try testing.expectEqual(@as(u256, 1), try stack.pop());

    // Test EQ
    try stack.push(42);
    try stack.push(42);
    try opEq(&stack);
    try testing.expectEqual(@as(u256, 1), try stack.pop());

    // Test ISZERO
    try stack.push(0);
    try opIszero(&stack);
    try testing.expectEqual(@as(u256, 1), try stack.pop());
}

test "bitwise instructions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    // Test AND
    try stack.push(0b1100);
    try stack.push(0b1010);
    try opAnd(&stack);
    try testing.expectEqual(@as(u256, 0b1000), try stack.pop());

    // Test OR
    try stack.push(0b1100);
    try stack.push(0b1010);
    try opOr(&stack);
    try testing.expectEqual(@as(u256, 0b1110), try stack.pop());

    // Test XOR
    try stack.push(0b1100);
    try stack.push(0b1010);
    try opXor(&stack);
    try testing.expectEqual(@as(u256, 0b0110), try stack.pop());

    // Test NOT
    try stack.push(0);
    try opNot(&stack);
    try testing.expectEqual(std.math.maxInt(u256), try stack.pop());
}

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

    // Test DIV
    try stack.push(100);
    try stack.push(3);
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

    // Test GT
    try stack.push(10);
    try stack.push(5);
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

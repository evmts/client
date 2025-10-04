//! EVM Errors
//! Based on Erigon's core/vm/errors.go
//! Defines all EVM execution errors

const std = @import("std");

/// EVM execution errors matching Erigon's core/vm/errors.go
pub const EVMError = error{
    // Core execution errors
    OutOfGas,
    CodeStoreOutOfGas,
    Depth,
    InsufficientBalance,
    ContractAddressCollision,
    ExecutionReverted,
    MaxCodeSizeExceeded,
    MaxInitCodeSizeExceeded,
    InvalidJump,
    WriteProtection,
    ReturnDataOutOfBounds,
    GasUintOverflow,
    InvalidCode,
    NonceUintOverflow,

    // Stack errors
    StackUnderflow,
    StackOverflow,

    // Invalid opcode
    InvalidOpCode,

    // Subroutine errors (EIP-2315)
    InvalidSubroutineEntry,
    InvalidRetsub,
    ReturnStackExceeded,

    // IntraBlockState errors
    IntraBlockStateFailed,

    // Memory errors
    MemoryAccessOutOfBounds,
    MemoryTooLarge,

    // Generic errors
    Unknown,
};

/// EVM error codes for RPC compatibility
pub const EVMErrorCode = enum(i32) {
    OutOfGas = 1,
    CodeStoreOutOfGas = 2,
    Depth = 3,
    InsufficientBalance = 4,
    ContractAddressCollision = 5,
    ExecutionReverted = 6,
    MaxInitCodeSizeExceeded = 7,
    MaxCodeSizeExceeded = 8,
    InvalidJump = 9,
    WriteProtection = 10,
    ReturnDataOutOfBounds = 11,
    GasUintOverflow = 12,
    InvalidCode = 13,
    NonceUintOverflow = 14,
    StackUnderflow = 15,
    StackOverflow = 16,
    InvalidOpCode = 17,
    InvalidSubroutineEntry = 18,
    InvalidRetsub = 19,
    ReturnStackExceeded = 20,
    Unknown = std.math.maxInt(i32) - 1,

    pub fn fromError(err: anyerror) EVMErrorCode {
        return switch (err) {
            error.OutOfGas => .OutOfGas,
            error.CodeStoreOutOfGas => .CodeStoreOutOfGas,
            error.Depth => .Depth,
            error.InsufficientBalance => .InsufficientBalance,
            error.ContractAddressCollision => .ContractAddressCollision,
            error.ExecutionReverted => .ExecutionReverted,
            error.MaxCodeSizeExceeded => .MaxCodeSizeExceeded,
            error.MaxInitCodeSizeExceeded => .MaxInitCodeSizeExceeded,
            error.InvalidJump => .InvalidJump,
            error.WriteProtection => .WriteProtection,
            error.ReturnDataOutOfBounds => .ReturnDataOutOfBounds,
            error.GasUintOverflow => .GasUintOverflow,
            error.InvalidCode => .InvalidCode,
            error.NonceUintOverflow => .NonceUintOverflow,
            error.StackUnderflow => .StackUnderflow,
            error.StackOverflow => .StackOverflow,
            error.InvalidOpCode => .InvalidOpCode,
            error.InvalidSubroutineEntry => .InvalidSubroutineEntry,
            error.InvalidRetsub => .InvalidRetsub,
            error.ReturnStackExceeded => .ReturnStackExceeded,
            else => .Unknown,
        };
    }
};

/// Get human-readable error message
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfGas => "out of gas",
        error.CodeStoreOutOfGas => "contract creation code storage out of gas",
        error.Depth => "max call depth exceeded",
        error.InsufficientBalance => "insufficient balance for transfer",
        error.ContractAddressCollision => "contract address collision",
        error.ExecutionReverted => "execution reverted",
        error.MaxCodeSizeExceeded => "max code size exceeded",
        error.MaxInitCodeSizeExceeded => "max initcode size exceeded",
        error.InvalidJump => "invalid jump destination",
        error.WriteProtection => "write protection",
        error.ReturnDataOutOfBounds => "return data out of bounds",
        error.GasUintOverflow => "gas uint64 overflow",
        error.InvalidCode => "invalid code",
        error.NonceUintOverflow => "nonce uint64 overflow",
        error.StackUnderflow => "stack underflow",
        error.StackOverflow => "stack overflow",
        error.InvalidOpCode => "invalid opcode",
        error.InvalidSubroutineEntry => "invalid subroutine entry",
        error.InvalidRetsub => "invalid retsub",
        error.ReturnStackExceeded => "return stack limit reached",
        error.IntraBlockStateFailed => "intra-block state fatal error",
        error.MemoryAccessOutOfBounds => "memory access out of bounds",
        error.MemoryTooLarge => "memory too large",
        else => "unknown error",
    };
}

test "error codes" {
    const testing = std.testing;

    const code = EVMErrorCode.fromError(error.OutOfGas);
    try testing.expectEqual(EVMErrorCode.OutOfGas, code);
    try testing.expectEqual(@as(i32, 1), @intFromEnum(code));
}

test "error messages" {
    const testing = std.testing;

    const msg = errorMessage(error.OutOfGas);
    try testing.expectEqualStrings("out of gas", msg);
}

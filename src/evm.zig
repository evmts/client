//! Ethereum Virtual Machine (EVM) Implementation
//! Based on Erigon's core/vm package
//!
//! This module implements the Ethereum Virtual Machine, including:
//! - Opcodes and instruction execution
//! - Stack and memory management
//! - Gas metering
//! - Precompiled contracts
//! - EVM interpreter

const std = @import("std");

// Core EVM components
pub const opcodes = @import("evm/opcodes.zig");
pub const stack = @import("evm/stack.zig");
pub const memory = @import("evm/memory.zig");
pub const errors = @import("evm/errors.zig");
pub const gas = @import("evm/gas.zig");

// Re-export commonly used types
pub const OpCode = opcodes.OpCode;
pub const Stack = stack.Stack;
pub const Memory = memory.Memory;
pub const EVMError = errors.EVMError;
pub const EVMErrorCode = errors.EVMErrorCode;

// EVM configuration and state (to be implemented)
// pub const EVM = @import("evm/evm.zig").EVM;
// pub const Interpreter = @import("evm/interpreter.zig").Interpreter;
// pub const Contract = @import("evm/contract.zig").Contract;

test {
    // Run all EVM tests
    _ = opcodes;
    _ = stack;
    _ = memory;
    _ = errors;
    _ = gas;
}

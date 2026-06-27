//! Stub opcode group handlers. Each group corresponds to a `sub_4030..` /
//! `sub_4031..` function in ref that switches on the full opcode word.
//! For this milestone we log the call and return success (1); the bodies of
//! the per-opcode work (sub_403268, sub_403F90, ...) are not implemented.

const std = @import("std");
const dispatcher = @import("dispatcher.zig");

const OpcodeArgs = dispatcher.OpcodeArgs;
const log = std.log.scoped(.exen_handlers);

fn logCall(group: u8, args: *OpcodeArgs) void {
    log.info("[grp{d} stub] opcode 0x{x:0>4} a=0x{x} b=0x{x}", .{
        group, args.opcode, args.a, args.b,
    });
}

/// sub_402F7C:5471 — opcodes 0x100 (event deliver), 0x101 (event ack).
pub fn group1(args: *OpcodeArgs) callconv(.c) i32 {
    logCall(1, args);
    return 1;
}

/// sub_40305E:5509 — opcode 0x200.
pub fn group2(args: *OpcodeArgs) callconv(.c) i32 {
    logCall(2, args);
    return 1;
}

/// sub_4030A4:5524 — opcodes 0x300, 0x301.
pub fn group3(args: *OpcodeArgs) callconv(.c) i32 {
    logCall(3, args);
    return 1;
}

/// sub_4030F1:5534 — opcode 0x402.
pub fn group4(args: *OpcodeArgs) callconv(.c) i32 {
    logCall(4, args);
    return 1;
}

/// sub_403120:5542 — opcodes 0x500..0x507.
pub fn group5(args: *OpcodeArgs) callconv(.c) i32 {
    logCall(5, args);
    return 1;
}

/// sub_4031D4:5581 — opcodes 0x600..0x605 (VM init / run / step).
pub fn group6(args: *OpcodeArgs) callconv(.c) i32 {
    logCall(6, args);
    return 1;
}

/// Register the six known group handlers on the dispatcher.
pub fn registerAll() void {
    dispatcher.registerHandler(1, group1);
    dispatcher.registerHandler(2, group2);
    dispatcher.registerHandler(3, group3);
    dispatcher.registerHandler(4, group4);
    dispatcher.registerHandler(5, group5);
    dispatcher.registerHandler(6, group6);
}

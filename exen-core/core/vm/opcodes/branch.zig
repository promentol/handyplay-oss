//! Conditional and unconditional branches (GOTO, IF_*, IF_ICMP_*, IFNULL, IFNONNULL)
//!
//! Auto-grouped from `core/vm/opcodes.zig` by `op*` family. Each
//! handler keeps its original 1-for-1 port of the `sub_*` body in
//! `reference/ref`.

const std = @import("std");
const err_mod = @import("../error.zig");
const frame_mod = @import("../frame.zig");
const vm_mod = @import("../vm.zig");
const cr = @import("../../classfile/registry.zig");
const log_fmt = @import("../log_fmt.zig");

const log = std.log.scoped(.interp);
const Error = err_mod.Error;
const Frame = frame_mod.Frame;
const Vm = vm_mod.Vm;
const classStr = log_fmt.classStr;
const methodStr = log_fmt.methodStr;

const EXEN_GAMELET = vm_mod.EXEN_GAMELET;
const JAVA_LANG_OBJECT = vm_mod.JAVA_LANG_OBJECT;

pub fn opGoto(_: *Vm, frame: *Frame, _: u8) Error!void {
    frame.alignPc();
    const target = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little);
    frame.pc = target;
}

/// JSR (opcode 0xa8, canonical sub_40C8F0) — jump to subroutine.
/// Canonical: save the return PC into the per-frame slot (VC+32), push 0,
/// jump to the u16 target. The saved PC is the address *after* the u16
/// operand. Unlike JVM (which pushes the return address), ExEn pushes a
/// 0 placeholder and keeps the real return PC in the frame slot, so RET
/// restores from there rather than from a local.
///
/// ⚠ Inferred from the opcodes.md decompile summary; reference/ref body
/// unavailable. JSR/RET are unused by the current corpus (only old
/// `finally`-clause compilation emits them).
pub fn opJsr(_: *Vm, frame: *Frame, _: u8) Error!void {
    const target = frame.readU16();
    frame.jsr_ret_pc = frame.pc;
    try frame.push(0);
    frame.pc = target;
}

/// RET (opcode 0xa9, canonical sub_40F9E0) — return from subroutine.
/// Canonical: PC = (VC+32), push 0. No operand (unlike JVM's `ret N`).
/// See opJsr for the shared caveat.
pub fn opRet(_: *Vm, frame: *Frame, _: u8) Error!void {
    frame.pc = frame.jsr_ret_pc;
    try frame.push(0);
}

pub fn icmpBranch(frame: *Frame, take_branch: bool) Error!void {
    const b = try frame.pop();
    const a = try frame.pop();
    _ = a;
    _ = b;
    frame.alignPc();
    if (take_branch) {
        frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little);
    } else {
        frame.pc += 2;
    }
}

pub fn opIfIcmpeq(_: *Vm, frame: *Frame, _: u8) Error!void {
    const b = try frame.pop();
    const a = try frame.pop();
    frame.alignPc();
    if (a == b) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIfIcmpne(_: *Vm, frame: *Frame, _: u8) Error!void {
    const b = try frame.pop();
    const a = try frame.pop();
    frame.alignPc();
    if (a != b) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIfIcmplt(_: *Vm, frame: *Frame, _: u8) Error!void {
    const b: i32 = @bitCast(try frame.pop());
    const a: i32 = @bitCast(try frame.pop());
    frame.alignPc();
    if (a < b) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIfIcmpge(_: *Vm, frame: *Frame, _: u8) Error!void {
    const b: i32 = @bitCast(try frame.pop());
    const a: i32 = @bitCast(try frame.pop());
    frame.alignPc();
    if (a >= b) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIfIcmpgt(_: *Vm, frame: *Frame, _: u8) Error!void {
    const b: i32 = @bitCast(try frame.pop());
    const a: i32 = @bitCast(try frame.pop());
    frame.alignPc();
    if (a > b) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIfIcmple(_: *Vm, frame: *Frame, _: u8) Error!void {
    const b: i32 = @bitCast(try frame.pop());
    const a: i32 = @bitCast(try frame.pop());
    frame.alignPc();
    if (a <= b) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIfeq(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v = try frame.pop();
    frame.alignPc();
    if (v == 0) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIfne(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v = try frame.pop();
    frame.alignPc();
    if (v != 0) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIflt(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v: i32 = @bitCast(try frame.pop());
    frame.alignPc();
    if (v < 0) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIfge(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v: i32 = @bitCast(try frame.pop());
    frame.alignPc();
    if (v >= 0) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIfgt(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v: i32 = @bitCast(try frame.pop());
    frame.alignPc();
    if (v > 0) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIfle(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v: i32 = @bitCast(try frame.pop());
    frame.alignPc();
    if (v <= 0) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIfnull(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v = try frame.pop();
    frame.alignPc();
    if (v == 0) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

pub fn opIfnonnull(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v = try frame.pop();
    frame.alignPc();
    if (v != 0) frame.pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little) else frame.pc += 2;
}

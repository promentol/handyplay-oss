//! Local-variable load/store opcodes (ALOAD/ASTORE/LOAD_n/STORE_n/LLOAD/LSTORE families)
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

pub fn opAload0(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 1) return Error.StackUnderflow;
    try frame.push(frame.slab[0]);
}

pub fn opAload1(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 2) return Error.StackUnderflow;
    try frame.push(frame.slab[1]);
}

pub fn opAload2(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 3) return Error.StackUnderflow;
    try frame.push(frame.slab[2]);
}

pub fn opAload3(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 4) return Error.StackUnderflow;
    try frame.push(frame.slab[3]);
}

pub fn opAstore0(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 1) return Error.StackUnderflow;
    frame.slab[0] = try frame.pop();
}

pub fn opAstore1(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 2) return Error.StackUnderflow;
    frame.slab[1] = try frame.pop();
}

pub fn opAstore2(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 3) return Error.StackUnderflow;
    frame.slab[2] = try frame.pop();
}

pub fn opAstore3(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 4) return Error.StackUnderflow;
    frame.slab[3] = try frame.pop();
}

pub fn opAload(_: *Vm, frame: *Frame, _: u8) Error!void {
    const idx = frame.bytecode[frame.pc];
    frame.pc += 1;
    if (idx >= frame.locals_count) return Error.StackUnderflow;
    try frame.push(frame.slab[idx]);
}

pub fn opAstore(_: *Vm, frame: *Frame, _: u8) Error!void {
    const idx = frame.bytecode[frame.pc];
    frame.pc += 1;
    if (idx >= frame.locals_count) return Error.StackUnderflow;
    frame.slab[idx] = try frame.pop();
}

pub fn opAload0Dup(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 1) return Error.StackUnderflow;
    try frame.push(frame.slab[0]);
}

pub fn opLoad1(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 2) return Error.StackUnderflow;
    try frame.push(frame.slab[1]);
}

pub fn opLoad2(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 3) return Error.StackUnderflow;
    try frame.push(frame.slab[2]);
}

pub fn opLoad3(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 4) return Error.StackUnderflow;
    try frame.push(frame.slab[3]);
}

pub fn opStore0(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v = try frame.pop();
    if (frame.locals_count < 1) return Error.StackUnderflow;
    frame.slab[0] = v;
}

pub fn opStore1(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v = try frame.pop();
    if (frame.locals_count < 2) return Error.StackUnderflow;
    frame.slab[1] = v;
}

pub fn opStore2(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v = try frame.pop();
    if (frame.locals_count < 3) return Error.StackUnderflow;
    frame.slab[2] = v;
}

pub fn opStore3(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v = try frame.pop();
    if (frame.locals_count < 4) return Error.StackUnderflow;
    frame.slab[3] = v;
}

pub fn opLload0(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 2) return Error.StackUnderflow;
    try frame.push(frame.slab[0]);
    try frame.push(frame.slab[1]);
}

pub fn opLload1(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 3) return Error.StackUnderflow;
    try frame.push(frame.slab[1]);
    try frame.push(frame.slab[2]);
}

pub fn opLload2(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 4) return Error.StackUnderflow;
    try frame.push(frame.slab[2]);
    try frame.push(frame.slab[3]);
}

pub fn opLload3(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.locals_count < 5) return Error.StackUnderflow;
    try frame.push(frame.slab[3]);
    try frame.push(frame.slab[4]);
}

pub fn opStoreOp(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.pc >= frame.bytecode.len) return Error.StackUnderflow;
    const slot = frame.bytecode[frame.pc];
    frame.pc += 1;
    const v = try frame.pop();
    if (slot >= frame.locals_count) return Error.StackUnderflow;
    frame.slab[slot] = v;
}

pub fn opLoadOp(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.pc >= frame.bytecode.len) return Error.StackUnderflow;
    const slot = frame.bytecode[frame.pc];
    frame.pc += 1;
    if (slot >= frame.locals_count) return Error.StackUnderflow;
    try frame.push(frame.slab[slot]);
}

pub fn opLstore0(_: *Vm, frame: *Frame, _: u8) Error!void {
    const hi = try frame.pop();
    const lo = try frame.pop();
    if (frame.locals_count < 2) return Error.StackUnderflow;
    frame.slab[0] = lo;
    frame.slab[1] = hi;
}

pub fn opLstore1(_: *Vm, frame: *Frame, _: u8) Error!void {
    const hi = try frame.pop();
    const lo = try frame.pop();
    if (frame.locals_count < 3) return Error.StackUnderflow;
    frame.slab[1] = lo;
    frame.slab[2] = hi;
}

pub fn opLstore2(_: *Vm, frame: *Frame, _: u8) Error!void {
    const hi = try frame.pop();
    const lo = try frame.pop();
    if (frame.locals_count < 4) return Error.StackUnderflow;
    frame.slab[2] = lo;
    frame.slab[3] = hi;
}

pub fn opLstore3(_: *Vm, frame: *Frame, _: u8) Error!void {
    const hi = try frame.pop();
    const lo = try frame.pop();
    if (frame.locals_count < 5) return Error.StackUnderflow;
    frame.slab[3] = lo;
    frame.slab[4] = hi;
}

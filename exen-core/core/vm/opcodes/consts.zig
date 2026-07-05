//! Constant push opcodes (NOP, ACONST_NULL, ICONST_*, BIPUSH, SIPUSH, LDC, LDC2_W, LDC_STRING)
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

pub fn opNop(_: *Vm, _: *Frame, _: u8) Error!void {}

pub fn opAconstNull(_: *Vm, frame: *Frame, _: u8) Error!void {
    try frame.push(0);
}

pub fn opIconst(_: *Vm, frame: *Frame, op: u8) Error!void {
    const value: i32 = switch (op) {
        0x02 => -1,
        0x03 => 0,
        0x04 => 1,
        0x05 => 2,
        0x06 => 3,
        0x07 => 4,
        0x08 => 5,
        else => unreachable,
    };
    try frame.push(@bitCast(value));
}

/// LCONST_0 / LCONST_1 (opcodes 0x09 / 0x0a, canonical sub_40CD4C /
/// sub_40CD7B). Push a 2-slot long constant — lo first, then hi, per
/// this VM's little-endian long layout (matches LDC2_W above and the
/// LLOAD/LSTORE family). Values 0L and 1L both have hi == 0.
pub fn opLconst(_: *Vm, frame: *Frame, op: u8) Error!void {
    const lo: u32 = if (op == 0x0a) 1 else 0;
    try frame.push(lo);
    try frame.push(0);
}

pub fn opBipush(_: *Vm, frame: *Frame, _: u8) Error!void {
    const imm: i8 = @bitCast(frame.bytecode[frame.pc]);
    frame.pc += 1;
    const v: i32 = imm;
    try frame.push(@bitCast(v));
}

pub fn opSipush(_: *Vm, frame: *Frame, _: u8) Error!void {
    const u = frame.readU16();
    const s: i32 = @as(i16, @bitCast(u));
    try frame.push(@bitCast(s));
}

pub fn opLdcString(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const off = frame.readU16();
    const handle = try vm.heap.alloc(0x7772dde3); // java.lang.String
    if (vm.heap.get(handle)) |inst| {
        inst.fields[0] = off;
        // Materialise the constant-pool string data into inst.bytes
        // so `String.getBytes()` (native 159) can copy from it. Keep
        // `fields[0]` set to the constant-pool offset — some code
        // paths use it for String equality / hashing. The bytes slice
        // is the "value" view; fields[0] is the "identity" view.
        if (off + 2 <= frame.bytecode.len) {
            const len: u32 = std.mem.readInt(u16, frame.bytecode[off..][0..2], .little);
            const end = off + 2 + len;
            if (end <= frame.bytecode.len) {
                if (len > 0) {
                    const buf = vm.heap.allocator.alloc(u8, len) catch null; // heap-owned (GC frees it)
                    if (buf) |b| {
                        @memcpy(b, frame.bytecode[off + 2 .. end]);
                        inst.bytes = b;
                    }
                }
            }
        }
    }
    try frame.push(handle);
}

pub fn opLdc(_: *Vm, frame: *Frame, _: u8) Error!void {
    const off = frame.readU16();
    if (off + 4 > frame.bytecode.len) return Error.StackOverflow;
    const v = std.mem.readInt(u32, frame.bytecode[off..][0..4], .little);
    try frame.push(v);
}

pub fn opLdc2W(_: *Vm, frame: *Frame, _: u8) Error!void {
    const off = frame.readU16();
    if (off + 8 > frame.bytecode.len) return Error.StackOverflow;
    const lo = std.mem.readInt(u32, frame.bytecode[off..][0..4], .little);
    const hi = std.mem.readInt(u32, frame.bytecode[off + 4 ..][0..4], .little);
    try frame.push(lo);
    try frame.push(hi);
}

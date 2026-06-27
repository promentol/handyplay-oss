//! Method return opcodes (RETURN, IRETURN/ARETURN, LRETURN)
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

pub fn opReturn(_: *Vm, frame: *Frame, _: u8) Error!void {
    frame.returning = true;
    frame.ret_slots = 0;
}

pub fn opIreturn(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v = try frame.pop();
    frame.ret_value[0] = v;
    frame.ret_slots = 1;
    frame.returning = true;
}

pub fn opLreturn(_: *Vm, frame: *Frame, _: u8) Error!void {
    const hi = try frame.pop();
    const lo = try frame.pop();
    frame.ret_value[0] = lo;
    frame.ret_value[1] = hi;
    frame.ret_slots = 2;
    frame.returning = true;
}

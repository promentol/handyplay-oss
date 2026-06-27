//! Catch-all for unbound opcode slots
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

pub fn unimpl(vm: *Vm, frame: *Frame, op: u8) Error!void {
    log.warn("UNIMPL OP 0x{x:0>2} at PC=0x{x:0>4} (method 0x{x:0>8})", .{
        op, frame.pc - 1, frame.method.hash,
    });
    vm.halted = true;
    vm.halt_reason = .{ .unknown_opcode = .{
        .op = op,
        .pc = @intCast(frame.pc - 1),
        .method_hash = frame.method.hash,
    } };
}

/// Canonical-no-op opcode (sub_4102CF — empty body `void sub_4102CF() { ; }`).
/// The canonical ISA reserves many opcode slots that map to this empty
/// function; the dispatcher reads the byte, calls it (no stack/PC effect),
/// and moves on. Bind each canonical no-op slot to this rather than to
/// `unimpl` so the tick doesn't halt on a benign byte.
pub fn opNoop(_: *Vm, _: *Frame, _: u8) Error!void {}

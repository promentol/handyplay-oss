//! Legacy catch-all native dispatcher. Used by per-class files in
//! `natives/` when an index inside their owned range isn't yet wired
//! through `bridge.dispatcher`. Returns 0 (one slot) so the caller's
//! operand-stack arithmetic stays consistent — the gamelet may
//! mis-execute, but it won't NPE the way an unhandled native does.
//!
//! The earlier "sentinel handle" arm for `java.lang.*` indices is
//! gone: every java.lang.{Object,Class,String,StringBuffer} native is
//! now a real per-class port (see natives/java/lang/), so nothing in
//! that index range falls through here anymore.

const std = @import("std");
const dbg = @import("../debug/names.zig");
const err_mod = @import("error.zig");
const log_fmt = @import("log_fmt.zig");
const frame_mod = @import("frame.zig");
const vm_mod = @import("vm.zig");

const Error = err_mod.Error;
const Frame = frame_mod.Frame;
const Vm = vm_mod.Vm;
const log = std.log.scoped(.interp);
const methodStr = log_fmt.methodStr;

pub fn defaultNativeStub(_: *Vm, idx: u32, frame: *Frame) Error!void {
    log.debug("    🎯 NATIVE [{d}] {s} called from {s}", .{
        idx, dbg.nativeName(idx), methodStr(frame.method.class.hash, frame.method.hash),
    });
    // Assume int-return (1 slot). 0 is the safest fallback — keeps
    // operand-stack arithmetic consistent and matches the canonical
    // "no-op returns 0" pattern of most unported natives.
    frame.ret_value[0] = 0;
    frame.ret_slots = 1;
}

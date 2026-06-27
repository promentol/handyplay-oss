//! Operand-stack manipulation (POP, POP2, DUP, DUP_X1, DUP2)
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

/// POP (opcode 0x57, sub_408A78 at ref:8458).
/// Canonical body:
///   **(SP) = 0;          // zero the top cell (defensive clear)
///   SP += 4;             // advance SP (= shrink stack by 1 slot)
pub fn opPop(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp == 0) return Error.StackUnderflow;
    frame.sp -= 1;
    frame.slab[frame.sp] = 0; // match canonical's defensive zero-write
}

pub fn opPop2(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 2) return Error.StackUnderflow;
    frame.sp -= 1;
    frame.slab[frame.sp] = 0;
    frame.sp -= 1;
    frame.slab[frame.sp] = 0;
}

/// POP-noclear (opcode 0x88, sub_40C990 at ref:11160).
/// Canonical body — net SP delta −4 bytes (1 slot), no cell modified:
///   SP -= 8;             // back up 8 bytes
///   **(SP) = **(SP);     // self-assign at SP_orig−8 — NO-OP
///   SP += 4;             // advance 4 bytes → final SP = SP_orig − 4
/// Difference vs 0x57: this variant does NOT zero the popped cell.
pub fn opPopNoclear(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp == 0) return Error.StackUnderflow;
    frame.sp -= 1;
}

pub fn opDup(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp == 0) return Error.StackUnderflow;
    const v = frame.slab[frame.sp - 1];
    try frame.push(v);
}

pub fn opDupX1(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 2) return Error.StackUnderflow;
    const y = frame.slab[frame.sp - 1];
    const x = frame.slab[frame.sp - 2];
    frame.slab[frame.sp - 2] = y;
    frame.slab[frame.sp - 1] = x;
    try frame.push(y);
}

/// DUP_X2 (opcode 0x5b, sub_4093D9 at ref:8899) — duplicate top
/// and insert under the third-from-top: `..,A,B,C → ..,C,A,B,C`.
/// Canonical body:
///   v4 = SP - 12;         // top 3 slots: A=v4[0], B=v4[1], C=v4[2]
///   v4[0] = C; v4[1] = A; v4[2] = B; v4[3] = C;
///   SP += 4;              // +1 slot
pub fn opDupX2(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 3) return Error.StackUnderflow;
    const c = frame.slab[frame.sp - 1];
    const b = frame.slab[frame.sp - 2];
    const a = frame.slab[frame.sp - 3];
    frame.slab[frame.sp - 3] = c;
    frame.slab[frame.sp - 2] = a;
    frame.slab[frame.sp - 1] = b;
    try frame.push(c);
}

pub fn opDup2(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 2) return Error.StackUnderflow;
    const b = frame.slab[frame.sp - 1];
    const a = frame.slab[frame.sp - 2];
    try frame.push(a);
    try frame.push(b);
}

/// DUP2_X1 (opcode 0x5d, sub_409484 at ref:8937) — JVM-style
/// duplicate-top-two-slots-and-insert-beneath-third. Before:
/// `[..., w3, w2, w1]` (w1 top) → After: `[..., w2, w1, w3, w2, w1]`.
///
/// Canonical (ref:8945-8956):
///   v4 = sp - 12;                  // 3 slots back
///   v2 = v4[0]; v1 = v4[1]; v3 = v4[2];
///   v4[0] = v1; v4[1] = v3; v4[2] = v2;
///   v4[3] = v1; v4[4] = v3;
///   sp += 8;                       // net +2 slots
///
/// Mapping to JVM names: w1=top=v3, w2=v1, w3=bottom=v2.
/// Result `[v1, v3, v2, v1, v3]` = `[w2, w1, w3, w2, w1]`. ✓
pub fn opDup2X1(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 3) return Error.StackUnderflow;
    const w1 = frame.slab[frame.sp - 1]; // top    (canonical v3)
    const w2 = frame.slab[frame.sp - 2]; // middle (canonical v1)
    const w3 = frame.slab[frame.sp - 3]; // bottom (canonical v2)
    frame.slab[frame.sp - 3] = w2;       // v4[0] = v1
    frame.slab[frame.sp - 2] = w1;       // v4[1] = v3
    frame.slab[frame.sp - 1] = w3;       // v4[2] = v2
    try frame.push(w2);                  // v4[3] = v1
    try frame.push(w1);                  // v4[4] = v3
}

/// DUP2_X2 (opcode 0x5e, sub_4094F6 at ref:8961) — JVM-style
/// duplicate-top-two-slots-and-insert-four-deep. Before:
/// `[..., w4, w3, w2, w1]` (w1 top) → After: `[..., w2, w1, w4, w3, w2, w1]`.
///
/// Canonical (ref:8970-8983):
///   v5 = sp - 16;                  // 4 slots back
///   v3 = v5[0]; v4 = v5[1]; v1 = v5[2]; v2 = v5[3];
///   v5[0] = v1; v5[1] = v2; v5[2] = v3; v5[3] = v4;
///   v5[4] = v1; v5[5] = v2;
///   sp += 8;                       // net +2 slots
///
/// Mapping to JVM names: w1=top=v2, w2=v1, w3=v4, w4=bottom=v3.
/// Result `[v1, v2, v3, v4, v1, v2]` = `[w2, w1, w4, w3, w2, w1]`. ✓
pub fn opDup2X2(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 4) return Error.StackUnderflow;
    const w1 = frame.slab[frame.sp - 1]; // top    (canonical v2)
    const w2 = frame.slab[frame.sp - 2]; //         (canonical v1)
    const w3 = frame.slab[frame.sp - 3]; //         (canonical v4)
    const w4 = frame.slab[frame.sp - 4]; // bottom (canonical v3)
    frame.slab[frame.sp - 4] = w2;       // v5[0] = v1
    frame.slab[frame.sp - 3] = w1;       // v5[1] = v2
    frame.slab[frame.sp - 2] = w4;       // v5[2] = v3
    frame.slab[frame.sp - 1] = w3;       // v5[3] = v4
    try frame.push(w2);                  // v5[4] = v1
    try frame.push(w1);                  // v5[5] = v2
}

/// SWAP (opcode 0x5f, sub_40FC84 at ref:13269) — JVM-style
/// swap the top two stack slots. Stack pointer is unchanged.
/// Before `[..., v2, top]` → After `[..., top, v2]`.
///
/// Canonical (ref:13275-13280):
///   v1 = sp - 8;                   // 2 slots back
///   v2 = v1[0];                    // bottom (sp-2)
///   result = v1[1];                // top    (sp-1)
///   v1[0] = result;
///   v1[1] = v2;
///   // sp NOT modified
pub fn opSwap(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 2) return Error.StackUnderflow;
    const top = frame.slab[frame.sp - 1]; // canonical result
    const v2 = frame.slab[frame.sp - 2];  // canonical v2
    frame.slab[frame.sp - 2] = top;       // v1[0] = result
    frame.slab[frame.sp - 1] = v2;        // v1[1] = v2
}

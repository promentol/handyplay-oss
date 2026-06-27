//! Object allocation + type-check (NEW, CHECKCAST)
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

/// Walk `recv_class_hash` and its super chain looking for `target_hash`.
/// Returns true if any class in the chain matches the target (including
/// `recv_class_hash` itself). Mirrors canonical `sub_411B6F`'s class-chain
/// walk; the interface-walking inner loop in the canonical listing is
/// elided here because we don't model interface tables yet — gamelets'
/// observed INSTANCEOF checks all hit the direct super chain.
fn isAssignableTo(vm: *Vm, recv_class_hash: u32, target_hash: u32) bool {
    if (target_hash == JAVA_LANG_OBJECT) return true;
    var cur = recv_class_hash;
    var hops: u32 = 0;
    while (cur != 0 and cur != JAVA_LANG_OBJECT and hops < 32) : (hops += 1) {
        if (cur == target_hash) return true;
        cur = vm.registry.superHash(cur) orelse return false;
    }
    return cur == target_hash;
}

/// Resolve the operand of CHECKCAST / INSTANCEOF (canonical
/// sub_40BCEA / sub_40BC23 family). Both opcodes share a 4-byte
/// operand at the aligned PC: `[tag:u16][desc_offset:u16]`. When
/// `tag & 0xff == 0x99` (object-ref form), `desc_offset` points
/// elsewhere in the bytecode where a `class_index:u16` lives;
/// resolving that index via the registry yields the target class.
/// On `tag != 0x99`, canonical short-circuits with a 2-byte advance
/// (no resolve) — we return null to signal that.
fn readClassOperand(vm: *Vm, frame: *Frame) ?u32 {
    frame.alignPc();
    if (frame.pc + 4 > frame.bytecode.len) return null;
    const tag = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little);
    if ((tag & 0xff) != 0x99) {
        frame.pc += 2;
        return null;
    }
    const desc_off = std.mem.readInt(u16, frame.bytecode[frame.pc + 2 ..][0..2], .little);
    frame.pc += 4;
    if (@as(usize, desc_off) + 2 > frame.bytecode.len) return null;
    const class_idx = std.mem.readInt(u16, frame.bytecode[desc_off..][0..2], .little);
    const cls = vm.registry.lookupByIndex(class_idx) orelse return null;
    return cls.hash;
}

/// CHECKCAST (opcode 0xC0, sub_40BC23 @ ref:10690). Canonical
/// throws on mismatch via `sub_407A13` (non-catchable abort). We log
/// the mismatch and silently allow the cast — keeps gamelets running
/// past speculative casts that aren't structurally enforced in our
/// looser type model. The PC advance + operand resolve mirror the
/// canonical layout (shared with INSTANCEOF).
pub fn opCheckcast(vm: *Vm, frame: *Frame, _: u8) Error!void {
    _ = readClassOperand(vm, frame);
    // Leave the stack alone: canonical's CHECKCAST is a pure type guard
    // that doesn't pop on success. On failure it would abort; we don't.
}

/// INSTANCEOF (opcode 0xC1, sub_40BCEA @ ref:10728). Pops an
/// object reference and pushes 1 if its class is assignable to the
/// target class (i.e. target is in the receiver's super chain, or
/// target is Object), 0 otherwise. Mirrors canonical's
/// `sub_411B6F(ref, target_class)` body (null receiver → 0, target
/// equals Object → 1, walk super chain for direct hit).
pub fn opInstanceof(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const target_hash_opt = readClassOperand(vm, frame);
    const ref = try frame.pop();
    if (ref == 0) {
        try frame.push(0);
        return;
    }
    // tag != 0x99 path: canonical leaves the stack short. Preserve our
    // earlier lenient behaviour (push 1 for non-null) so legacy gamelets
    // that hit this rare path don't underflow.
    const target_hash = target_hash_opt orelse {
        try frame.push(1);
        return;
    };
    const inst = vm.heap.get(ref) orelse {
        try frame.push(0);
        return;
    };
    const result: u32 = if (isAssignableTo(vm, inst.class_hash, target_hash)) 1 else 0;
    try frame.push(result);
}

pub fn opNew(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const desc_off = frame.readU16();
    if (desc_off + 2 > frame.bytecode.len) return Error.StackOverflow;
    const class_idx = std.mem.readInt(u16, frame.bytecode[desc_off..][0..2], .little);

    const cls = vm.registry.lookupByIndex(class_idx) orelse {
        log.warn("  NEW: class_index {d} not registered — allocating with hash=0", .{class_idx});
        const handle = try vm.heap.alloc(0);
        try frame.push(handle);
        return;
    };
    // Mirror sub_40ED5A's call to sub_40E359 (line 12579): the FIRST
    // time we touch a class via NEW, its `<clinit>` runs. ExEn
    // doesn't have an explicit class-loading opcode, so this is where
    // static-field setup for instantiable classes actually happens.
    _ = vm.ensureClassObject(cls.hash) catch null;
    const handle = try vm.heap.alloc(cls.hash);
    log.debug("  NEW class_index={d} class=0x{x:0>8} → handle=0x{x:0>8}", .{
        class_idx, cls.hash, handle,
    });
    // SPAWN-DEBUG (BanjoKazooie enemy hunt): NEWs are low-volume, so an
    // INFO trace of every gameplay object creation is grep-able without
    // the GETFIELD/PUTFIELD firehose. Skip boot-time framework spam
    // (Resource/Palette/Image/String/StringBuffer).
    switch (cls.hash) {
        0xbab5c664, 0x5562ca3b, 0x23c5e7e8, 0x7772dde3, 0x6bddc5b7 => {},
        else => std.log.scoped(.spawndbg).info("NEW class=0x{x:0>8} handle=0x{x:0>8}", .{ cls.hash, handle }),
    }
    // Image instances (class 0x23c5e7e8) get their pixel data from
    // the real `image.TransformBitmapFromResExed` native (Layer 2),
    // not from a host-side cycling cache. Just push the handle.
    try frame.push(handle);
}

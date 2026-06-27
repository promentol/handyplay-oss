//! Method invocation (INVOKEVIRTUAL, INVOKESTATIC, INVOKESPECIAL, INVOKE_OWN — plus desc variants)
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

pub fn opInvokevirtual(vm: *Vm, frame: *Frame, op: u8) Error!void {
    return doInvokevirtual(vm, frame, op, 4);
}

pub fn opInvokevirtualAlt(vm: *Vm, frame: *Frame, _: u8) Error!void {
    // Canonical sub_40C1FA dispatches to the *current frame's class*
    // (`*(u16*)(VmState+28)`), NOT virtually via the receiver's class.
    // It's effectively a non-virtual self-call: "call my own class's
    // version of this method, even if the receiver is a subclass that
    // overrides it." Previously we routed this through the same
    // virtual dispatch as 0xEE — subclass overrides would silently
    // hijack the call.
    const desc_off = frame.readU16();
    if (desc_off + 8 > frame.bytecode.len) return Error.StackUnderflow;
    const method_hash = std.mem.readInt(u32, frame.bytecode[desc_off..][0..4], .little);
    const arg_count = std.mem.readInt(u16, frame.bytecode[desc_off + 6 ..][0..2], .little);

    const total_pop = @as(u32, arg_count) + 1;
    if (frame.sp < frame.locals_count + total_pop) return Error.StackUnderflow;
    const this_ref = frame.slab[frame.sp - total_pop];
    frame.sp -= total_pop;

    log.debug("  INVOKEVIRTUAL_ALT desc@0x{x:0>4}: {s} args={d} this=0x{x:0>8}", .{
        desc_off, methodStr(0, method_hash), arg_count, this_ref,
    });

    if (this_ref == 0) {
        log.warn("  INVOKEVIRTUAL_ALT on NULL this — current frame returns", .{});
        frame.returning = true;
        frame.ret_slots = 0;
        return;
    }

    // Direct-class lookup: find method in the current frame's class
    // record. If absent, walk the super chain (matches canonical's
    // sub_40DF05 fallback when sub_40E02C's exact-class lookup misses).
    const mi = vm.registry.findMethod(frame.class_hash, method_hash) orelse
        vm.resolveVirtual(frame.class_hash, method_hash) orelse {
        log.warn("  INVOKEVIRTUAL_ALT method 0x{x:0>8} not found in class 0x{x:0>8}", .{
            method_hash, frame.class_hash,
        });
        vm.halted = true;
        vm.halt_reason = .{ .method_not_found = method_hash };
        return Error.MethodNotFound;
    };
    log.debug("  → resolved to class={s} (class-direct)", .{classStr(mi.class.hash)});

    var pop_buf: [32]u32 = undefined;
    if (total_pop > pop_buf.len) return Error.StackOverflow;
    for (0..total_pop) |i| pop_buf[i] = frame.slab[frame.sp + i];
    try vm.invokeMethodInfo(mi, frame, pop_buf[0..total_pop]);
}

pub fn doInvokevirtual(vm: *Vm, frame: *Frame, _: u8, arg_count_off: u32) Error!void {
    const desc_off = frame.readU16();
    if (desc_off + 8 > frame.bytecode.len) return Error.StackUnderflow;
    const method_hash = std.mem.readInt(u32, frame.bytecode[desc_off..][0..4], .little);
    const arg_count = std.mem.readInt(u16, frame.bytecode[desc_off + arg_count_off ..][0..2], .little);

    // Pop arg_count args + 1 `this` slot.
    const total_pop = @as(u32, arg_count) + 1;
    if (frame.sp < frame.locals_count + total_pop) return Error.StackUnderflow;
    const this_ref = frame.slab[frame.sp - total_pop];
    frame.sp -= total_pop;

    log.debug("  INVOKEVIRTUAL desc@0x{x:0>4}: {s} args={d} this=0x{x:0>8}", .{
        desc_off, methodStr(0, method_hash), arg_count, this_ref,
    });

    if (this_ref == 0) {
        log.warn("  INVOKEVIRTUAL on NULL this — current frame returns (canonical sub_41B6B2)", .{});
        // Canonical (`sub_41B6B2` at ref:19665): on internal
        // exception, set state=2 and **zero the current frame's PC**,
        // causing the interpreter loop `sub_40DC74` to exit THIS
        // frame only. Parent frames continue at the opcode after
        // this INVOKE — they see whatever (if anything) is on the
        // stack. We mirror that with `frame.returning = true` and
        // `ret_slots = 0` (no value pushed; matches the canonical
        // "frame just bails" semantics). Unlike `vm.halted = true`
        // which would abort the entire tick, this lets the gamelet's
        // event loop continue past the catastrophic call.
        frame.returning = true;
        frame.ret_slots = 0;
        return;
    }

    const inst = vm.heap.get(this_ref) orelse {
        log.warn("  INVOKEVIRTUAL on invalid handle 0x{x:0>8} — current frame returns", .{this_ref});
        frame.returning = true;
        frame.ret_slots = 0;
        return;
    };

    const mi = vm.resolveVirtual(inst.class_hash, method_hash) orelse {
        log.warn("  method 0x{x:0>8} not found in class chain starting at 0x{x:0>8}", .{
            method_hash, inst.class_hash,
        });
        vm.halted = true;
        vm.halt_reason = .{ .method_not_found = method_hash };
        return Error.MethodNotFound;
    };
    log.debug("  → resolved to class={s}", .{classStr(mi.class.hash)});
    // Re-fetch args from operand stack (pop_buf preserves the pre-pop
    // values so we can pass them as the new frame's locals).
    var pop_buf: [32]u32 = undefined;
    if (total_pop > pop_buf.len) return Error.StackOverflow;
    for (0..total_pop) |i| pop_buf[i] = frame.slab[frame.sp + i];
    try vm.invokeMethodInfo(mi, frame, pop_buf[0..total_pop]);
}

pub fn opInvokestaticAlt(vm: *Vm, frame: *Frame, op: u8) Error!void {
    return doInvokestatic(vm, frame, op, 6);
}

pub fn opInvokestatic(vm: *Vm, frame: *Frame, op: u8) Error!void {
    return doInvokestatic(vm, frame, op, 4);
}

pub fn doInvokestatic(vm: *Vm, frame: *Frame, _: u8, arg_count_off: u32) Error!void {
    const desc_off = frame.readU16();
    if (desc_off + 8 > frame.bytecode.len) return Error.StackUnderflow;
    const method_hash = std.mem.readInt(u32, frame.bytecode[desc_off..][0..4], .little);
    const arg_count = std.mem.readInt(u16, frame.bytecode[desc_off + arg_count_off ..][0..2], .little);

    log.debug("  INVOKESTATIC desc@0x{x:0>4} {s} args={d}", .{
        desc_off, methodStr(0, method_hash), arg_count,
    });

    // Build args slice from operand stack.
    var pop_buf: [32]u32 = undefined;
    if (arg_count > pop_buf.len) return Error.StackOverflow;
    for (0..arg_count) |i| pop_buf[i] = frame.slab[frame.sp - arg_count + i];
    frame.sp -= arg_count;

    // INVOKESTATIC's descriptor names the OWNING class explicitly — just
    // like INVOKESPECIAL and GETSTATIC_FULL. Layout:
    //   +0..4              u32 method_hash
    //   +arg_count_off..+2 u16 arg_count          (4 for 0xF2, 6 for 0xF1 Alt)
    //   +arg_count_off+2   u16 class_ref_offset   ← indirect into bytecode
    // and `bytecode[class_ref_offset]` is the u16 class INDEX. Static
    // calls target unrelated utility classes (exen.Math.random, etc.)
    // that are NOT on the caller's super-chain, so the class MUST come
    // from the descriptor — resolving by method hash alone would pick an
    // arbitrary class when the hash collides (the GETSTATIC_FULL bug).
    const STATIC_FLAG: u16 = 0x0008;
    var mi: ?cr.MethodInfo = null;
    if (desc_off + arg_count_off + 4 <= frame.bytecode.len) {
        const cref_off = std.mem.readInt(u16, frame.bytecode[desc_off + arg_count_off + 2 ..][0..2], .little);
        if (@as(usize, cref_off) + 2 <= frame.bytecode.len) {
            const class_id = std.mem.readInt(u16, frame.bytecode[cref_off..][0..2], .little);
            if (vm.registry.lookupByIndex(class_id)) |rec| {
                if (vm.registry.classes.getPtr(rec.hash)) |stable| {
                    if (stable.findMethod(method_hash)) |m| mi = m;
                }
            }
        }
    }
    // Fallback: walk the current class's super-chain, then the well-known
    // built-in static homes, then a global static-preferring scan. Only
    // reached when the descriptor class-ref is malformed or the named
    // class doesn't declare the method (rare). Prefer the STATIC-flagged
    // match so a colliding instance-method hash can't shadow the static.
    if (mi == null) {
        var ch: u32 = frame.class_hash;
        var hops: u32 = 0;
        chain: while (hops < 32) : (hops += 1) {
            if (vm.registry.findMethod(ch, method_hash)) |m| {
                if ((m.flags & STATIC_FLAG) != 0) {
                    mi = m;
                    break :chain;
                }
                if (mi == null) mi = m;
            }
            const next = vm.registry.superHash(ch) orelse break;
            if (next == 0 or next == ch) break;
            ch = next;
        }
        if (mi == null or (mi.?.flags & STATIC_FLAG) == 0) {
            for ([_]u32{ EXEN_GAMELET, JAVA_LANG_OBJECT }) |wk| {
                if (vm.registry.findMethod(wk, method_hash)) |m| {
                    if ((m.flags & STATIC_FLAG) != 0) {
                        mi = m;
                        break;
                    }
                    if (mi == null) mi = m;
                }
            }
        }
        if (mi == null or (mi.?.flags & STATIC_FLAG) == 0) {
            var it = vm.registry.classes.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.findMethod(method_hash)) |m| {
                    if ((m.flags & STATIC_FLAG) != 0) {
                        mi = m;
                        break;
                    }
                    if (mi == null) mi = m;
                }
            }
        }
    }
    const resolved = mi orelse {
        vm.halted = true;
        vm.halt_reason = .{ .method_not_found = method_hash };
        return Error.MethodNotFound;
    };
    log.debug("  → resolved to class={s} flags=0x{x:0>4}", .{ classStr(resolved.class.hash), resolved.flags });
    try vm.invokeMethodInfo(resolved, frame, pop_buf[0..arg_count]);
}

pub fn opInvokespecial(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const desc_off = frame.readU16();
    if (desc_off + 8 > frame.bytecode.len) return Error.StackUnderflow;
    const method_hash = std.mem.readInt(u32, frame.bytecode[desc_off..][0..4], .little);
    const arg_count = std.mem.readInt(u16, frame.bytecode[desc_off + 4 ..][0..2], .little);

    const total_pop = @as(u32, arg_count) + 1;
    if (frame.sp < frame.locals_count + total_pop) return Error.StackUnderflow;
    const this_ref = frame.slab[frame.sp - total_pop];

    log.debug("  INVOKESPECIAL desc@0x{x:0>4}: {s} args={d} this=0x{x:0>8}", .{
        desc_off, methodStr(0, method_hash), arg_count, this_ref,
    });

    if (this_ref == 0) {
        log.warn("  INVOKESPECIAL on NULL this — current frame returns (canonical sub_41B6B2)", .{});
        frame.returning = true;
        frame.ret_slots = 0;
        return;
    }

    const inst = vm.heap.get(this_ref) orelse {
        log.warn("  INVOKESPECIAL on invalid handle 0x{x:0>8} — current frame returns", .{this_ref});
        frame.returning = true;
        frame.ret_slots = 0;
        return;
    };

    // Resolution: INVOKESPECIAL's descriptor encodes the TARGET CLASS
    // explicitly — `sub_40E5A2:12301` matches the desc's class-id
    // against each class on the receiver's super chain before
    // searching the method table. The descriptor layout is:
    //   +0..4  u32 method_hash
    //   +4..6  u16 arg_count
    //   +6..8  u16 class_ref_offset    ← indirect into bytecode
    // and `bytecode[class_ref_offset]` is the u16 class INDEX. So
    // `new X; INVOKESPECIAL X.<init>` and `super.<init>()` differ
    // only by what's at class_ref_offset (the subclass vs the super
    // class), and the descriptor unambiguously tells us which.
    // Without this, every INVOKESPECIAL <init> resolved to the
    // caller's super — skipping `new X.<init>` entirely and leaving
    // statics that X.<init> would have set (e.g. screen-width slot
    // 12 on Crash's 0x555aa710) at 0.
    var target_class_hash: u32 = 0;
    if (desc_off + 8 <= frame.bytecode.len) {
        const cref_off = std.mem.readInt(u16, frame.bytecode[desc_off + 6 ..][0..2], .little);
        if (cref_off + 2 <= frame.bytecode.len) {
            const class_id = std.mem.readInt(u16, frame.bytecode[cref_off..][0..2], .little);
            if (vm.registry.by_index.get(class_id)) |h| target_class_hash = h;
        }
    }
    var resolved: ?cr.MethodInfo = null;
    if (target_class_hash != 0) {
        if (vm.registry.findMethod(target_class_hash, method_hash)) |mi_t| {
            resolved = mi_t;
        }
    }
    if (resolved == null) {
        // Fallback: walk the receiver's super chain starting from the
        // declared target (or the receiver itself if we couldn't
        // resolve the target class). Matches sub_40E5A2's behaviour
        // when the requested class isn't directly registered.
        const start = if (target_class_hash != 0) target_class_hash else inst.class_hash;
        var ch: u32 = start;
        var hops: u32 = 0;
        while (hops < 32) : (hops += 1) {
            if (vm.registry.findMethod(ch, method_hash)) |mi_c| {
                resolved = mi_c;
                break;
            }
            const next = vm.registry.superHash(ch) orelse 0;
            if (next == 0 or next == ch) break;
            ch = next;
        }
        if (resolved == null) {
            resolved = vm.registry.findMethodAnywhere(method_hash);
        }
    }
    const mi = resolved orelse {
        log.warn("  INVOKESPECIAL: method 0x{x:0>8} not found in super-chain of 0x{x:0>8}", .{
            method_hash, frame.class_hash,
        });
        vm.halted = true;
        vm.halt_reason = .{ .method_not_found = method_hash };
        return Error.MethodNotFound;
    };
    log.debug("  → resolved to class={s} (super of {s})", .{ classStr(mi.class.hash), classStr(frame.class_hash) });

    var pop_buf: [32]u32 = undefined;
    if (total_pop > pop_buf.len) return Error.StackOverflow;
    for (0..total_pop) |i| pop_buf[i] = frame.slab[frame.sp - total_pop + i];
    frame.sp -= total_pop;
    try vm.invokeMethodInfo(mi, frame, pop_buf[0..total_pop]);
}

pub fn opInvokeOwn(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const desc_off = frame.readU16();
    if (desc_off + 8 > frame.bytecode.len) return Error.StackOverflow;
    const method_hash = std.mem.readInt(u32, frame.bytecode[desc_off..][0..4], .little);
    // sub_40C013:10814 — `v2[3]` (WORD at byte offset 6) is arg count.
    // (Distinct from INVOKEVIRTUAL/SPECIAL which use offset 4.)
    const arg_count = std.mem.readInt(u16, frame.bytecode[desc_off + 6 ..][0..2], .little);
    const total_pop = @as(u32, arg_count) + 1;

    log.debug("  INVOKE-own desc@0x{x:0>4} {s} args={d} sp={d} locals={d}", .{
        desc_off, methodStr(0, method_hash), arg_count, frame.sp, frame.locals_count,
    });

    if (frame.sp < total_pop) return Error.StackUnderflow;
    const this_ref = frame.slab[frame.sp - total_pop];


    if (this_ref == 0) {
        log.warn("  INVOKE_OWN on NULL this — current frame returns (canonical sub_41B6B2)", .{});
        frame.returning = true;
        frame.ret_slots = 0;
        return;
    }

    // Resolve in the CURRENT frame's class first (this is what
    // sub_40E02C uses with class_hash=VC+28 = current class).
    const mi = vm.registry.findMethod(frame.class_hash, method_hash) orelse
        vm.resolveVirtual(frame.class_hash, method_hash) orelse
        vm.registry.findMethodAnywhere(method_hash) orelse
    {
        vm.halted = true;
        vm.halt_reason = .{ .method_not_found = method_hash };
        return Error.MethodNotFound;
    };
    log.debug("  → resolved to class={s}", .{classStr(mi.class.hash)});

    var pop_buf: [32]u32 = undefined;
    if (total_pop > pop_buf.len) return Error.StackOverflow;
    for (0..total_pop) |i| pop_buf[i] = frame.slab[frame.sp - total_pop + i];
    frame.sp -= total_pop;
    try vm.invokeMethodInfo(mi, frame, pop_buf[0..total_pop]);
}

//! Field access (GETSTATIC, PUTSTATIC, GETFIELD, PUTFIELD — incl. _own/_full variants)
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

pub fn opGetstatic(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const desc_off = frame.readU16();
    if (desc_off + 12 > frame.bytecode.len) return Error.StackUnderflow;
    const type_tag = std.mem.readInt(u16, frame.bytecode[desc_off + 6 ..][0..2], .little);
    const slot = std.mem.readInt(u16, frame.bytecode[desc_off + 8 ..][0..2], .little);

    const class_obj = try vm.ensureClassObject(frame.class_hash);

    log.debug("  GETSTATIC desc@0x{x:0>4}: tag=0x{x:0>4} slot={d}  → class_obj.statics[{d}]=0x{x:0>8}", .{
        desc_off, type_tag, slot, slot, class_obj.statics[slot],
    });

    if (slot >= class_obj.statics.len) return Error.StackOverflow;

    const tag_lo = type_tag & 0xFF;
    // Mirrors the type-tagged branches in sub_40A01A:
    if ((type_tag & 0xFF00) != 0 or tag_lo == 0x99) {
        try frame.push(class_obj.statics[slot]);
    } else if (tag_lo == 0x59) {
        try frame.push(class_obj.statics[slot]); // int
    } else if (tag_lo == 0x15) {
        // short — sign-extended 16-bit
        const v16: i16 = @bitCast(@as(u16, @truncate(class_obj.statics[slot])));
        const v: i32 = v16;
        try frame.push(@bitCast(v));
    } else if (tag_lo == 0x90 or tag_lo == 0xD5 or tag_lo == 0x50) {
        // byte/boolean/char — 8-bit unsigned
        try frame.push(class_obj.statics[slot] & 0xFF);
    } else if (tag_lo == 0x6E) {
        // long — 2 slots
        try frame.push(class_obj.statics[slot]);
        if (slot + 1 < class_obj.statics.len)
            try frame.push(class_obj.statics[slot + 1]);
    } else {
        // Unknown tag: per ref, do nothing (silent drop).
        log.warn("  GETSTATIC unknown type tag 0x{x:0>4} — pushing nothing", .{type_tag});
    }
}

pub fn opPutstatic(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const desc_off = frame.readU16();
    if (desc_off + 12 > frame.bytecode.len) return Error.StackUnderflow;
    const type_tag = std.mem.readInt(u16, frame.bytecode[desc_off + 6 ..][0..2], .little);
    const slot = std.mem.readInt(u16, frame.bytecode[desc_off + 8 ..][0..2], .little);

    const class_obj = try vm.ensureClassObject(frame.class_hash);
    if (slot >= class_obj.statics.len) return Error.StackOverflow;

    const tag_lo = type_tag & 0xFF;
    if ((type_tag & 0xFF00) != 0 or tag_lo == 0x99) {
        // Reference / object — pop u32 and store.
        const v = try frame.pop();
        class_obj.statics[slot] = v;
        log.debug("  PUTSTATIC desc@0x{x:0>4}: tag=0x{x:0>4} slot={d} ref ← 0x{x:0>8}", .{ desc_off, type_tag, slot, v });
    } else if (tag_lo == 0x59 or tag_lo == 0x15) {
        // int / short — store full u32.
        const v = try frame.pop();
        class_obj.statics[slot] = v;
        log.debug("  PUTSTATIC desc@0x{x:0>4}: tag=0x{x:0>4} slot={d} int ← 0x{x:0>8}", .{ desc_off, type_tag, slot, v });
    } else if (tag_lo == 0x90 or tag_lo == 0xD5 or tag_lo == 0x50) {
        // byte / boolean / char — store low byte only (per sub_40F4FB).
        const v = try frame.pop();
        class_obj.statics[slot] = v & 0xFF;
        log.debug("  PUTSTATIC desc@0x{x:0>4}: tag=0x{x:0>4} slot={d} byte ← 0x{x:0>2}", .{ desc_off, type_tag, slot, v & 0xFF });
    } else if (tag_lo == 0x6E) {
        // long — pop 2 slots (sp -= 8), store both.
        const hi = try frame.pop();
        const lo = try frame.pop();
        class_obj.statics[slot] = lo;
        if (slot + 1 < class_obj.statics.len) class_obj.statics[slot + 1] = hi;
        log.debug("  PUTSTATIC desc@0x{x:0>4}: tag=0x{x:0>4} slot={d} long ← 0x{x:0>8}{x:0>8}", .{ desc_off, type_tag, slot, hi, lo });
    } else {
        log.warn("  PUTSTATIC unknown type tag 0x{x:0>4} — popping nothing", .{type_tag});
    }
}

/// Resolve a FULL static descriptor (GETSTATIC_FULL / PUTSTATIC_FULL) to
/// its field-info. Mirrors canonical `sub_40DCF0`: the 8-byte descriptor
/// is `[field_hash:u32][type_tag:u16][class_desc_ptr:u16]`, where the
/// `@6` word points elsewhere in the bytecode at the owning class's
/// `class_index:u16`. That index is resolved via the registry
/// (`sub_40E359`) and the field's slot/tag are read from THAT class's
/// field table — NOT a global "first class with this hash" search.
///
/// The descriptor names the owning class precisely because a static
/// field hash (CRC of the field name) is NOT unique: an inheritance
/// chain (e.g. MIDlet `extends` base scene) can carry the same field
/// hash on multiple classes at different slots. Honouring the named
/// class is what disambiguates them.
///
/// Falls back to a global field-hash search only when the class pointer
/// is malformed or the field isn't declared on the named class — the
/// same belt-and-braces pattern `Registry.resolveVirtual` uses.
fn resolveFullStatic(vm: *Vm, frame: *Frame, desc_off: u16) ?cr.FieldInfo {
    const field_hash = std.mem.readInt(u32, frame.bytecode[desc_off..][0..4], .little);

    if (@as(usize, desc_off) + 8 <= frame.bytecode.len) {
        const class_ptr = std.mem.readInt(u16, frame.bytecode[desc_off + 6 ..][0..2], .little);
        if (@as(usize, class_ptr) + 2 <= frame.bytecode.len) {
            const class_idx = std.mem.readInt(u16, frame.bytecode[class_ptr..][0..2], .little);
            if (vm.registry.lookupByIndex(class_idx)) |rec| {
                // Re-fetch a stable pointer: FieldInfo.class is a borrowed
                // pointer, and lookupByIndex returns the record by value.
                if (vm.registry.classes.getPtr(rec.hash)) |stable| {
                    if (stable.findField(field_hash)) |fi| return fi;
                }
            }
        }
    }

    var it = vm.registry.classes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.findField(field_hash)) |fi| return fi;
    }
    return null;
}

pub fn opGetstaticFull(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const desc_off = frame.readU16();
    if (desc_off + 4 > frame.bytecode.len) return Error.StackOverflow;
    const field_hash = std.mem.readInt(u32, frame.bytecode[desc_off..][0..4], .little);

    const fi = resolveFullStatic(vm, frame, desc_off) orelse {
        log.warn("  GETSTATIC-full: field 0x{x:0>8} not found — pushing 0", .{field_hash});
        try frame.push(0);
        return;
    };
    const owner = try vm.ensureClassObject(fi.class.hash);
    if (fi.slot >= owner.statics.len) {
        try frame.push(0);
        return;
    }
    const v = owner.statics[fi.slot];
    const v_hi: u32 = if (fi.slot + 1 < owner.statics.len) owner.statics[fi.slot + 1] else 0;
    log.debug("  GETSTATIC-full field=0x{x:0>8} class=0x{x:0>8} slot={d} tag=0x{x:0>4} value=0x{x:0>8}", .{
        field_hash, fi.class.hash, fi.slot, fi.type_tag, v,
    });
    try pushTyped(frame, fi.type_tag, v, v_hi);
}

pub fn opPutstaticFull(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const desc_off = frame.readU16();
    if (desc_off + 8 > frame.bytecode.len) return Error.StackOverflow;
    const field_hash = std.mem.readInt(u32, frame.bytecode[desc_off..][0..4], .little);

    // Resolve the owning class from the descriptor (sub_40DCF0), not a
    // global hash search — see resolveFullStatic. A static field hash is
    // not unique across an inheritance chain.
    const fi = resolveFullStatic(vm, frame, desc_off) orelse {
        log.warn("  PUTSTATIC-full: field 0x{x:0>8} not found — popping 1 slot", .{field_hash});
        _ = try frame.pop();
        return;
    };

    const tag_lo = fi.type_tag & 0xFF;
    const owner = try vm.ensureClassObject(fi.class.hash);
    if (fi.slot >= owner.statics.len) {
        log.warn("  PUTSTATIC-full slot {d} out of range — dropped", .{fi.slot});
        _ = try frame.pop();
        return;
    }
    // Arrays carry their type in the HIGH byte (e.g. 0x0190 = array of
    // byte, 0x0199 = array of ref). For any array tag, the value on the
    // operand stack is a HEAP HANDLE (u32) — DO NOT mask to the
    // primitive width. Mirroring opGetstatic's `(type_tag & 0xFF00) != 0`
    // check. Without this guard, a byte[] field (tag 0x0190) was being
    // truncated from `handle & 0xFF`, turning handle 0x121 into 0x21
    // and routing later array-access opcodes to a stale (Palette)
    // instance whose `inst.bytes` was null — cascading into NPE.
    const is_array = (fi.type_tag & 0xFF00) != 0;
    if (tag_lo == 0x6E and !is_array) {
        const hi = try frame.pop();
        const lo = try frame.pop();
        owner.statics[fi.slot] = lo;
        if (fi.slot + 1 < owner.statics.len) owner.statics[fi.slot + 1] = hi;
        log.debug("  PUTSTATIC-full field=0x{x:0>8} class=0x{x:0>8} slot={d} long ← 0x{x:0>8}{x:0>8}", .{
            field_hash, fi.class.hash, fi.slot, hi, lo,
        });
    } else {
        const v = try frame.pop();
        const stored: u32 = if (!is_array and (tag_lo == 0x90 or tag_lo == 0xD5 or tag_lo == 0x50)) v & 0xFF else v;
        owner.statics[fi.slot] = stored;
        log.debug("  PUTSTATIC-full field=0x{x:0>8} class=0x{x:0>8} slot={d} tag=0x{x:0>4} ← 0x{x:0>8}", .{
            field_hash, fi.class.hash, fi.slot, fi.type_tag, stored,
        });
    }
}

pub fn opPutfieldOwn(vm: *Vm, frame: *Frame, op: u8) Error!void {
    return doPutfield(vm, frame, op);
}

pub fn doPutfield(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const desc_off = frame.readU16();
    if (desc_off + 12 > frame.bytecode.len) return Error.StackOverflow;
    // sub_40F0B2 reads type_tag AND slot from the DESCRIPTOR (not from
    // field-info chain walk), and uses the descriptor's pop formula
    // `4 * ((tag>>4)&3) + 4` bytes = value_slots+1 slots.
    const field_hash = std.mem.readInt(u32, frame.bytecode[desc_off..][0..4], .little);
    const type_tag = std.mem.readInt(u16, frame.bytecode[desc_off + 6 ..][0..2], .little);
    const slot = std.mem.readInt(u16, frame.bytecode[desc_off + 8 ..][0..2], .little);
    const value_slots: u32 = (@as(u32, type_tag) >> 4) & 3; // 0..3 — sub_40F0B2 pops value_slots+1 slots (= 1..4)

    // Total pop = value_slots + 1 (the +1 is the receiver `this`).
    // Allow dipping into locals (unified slab) — sp >= value_slots+1 is enough.
    const total_pop = value_slots + 1;
    if (frame.sp < total_pop) return Error.StackUnderflow;

    // Layout on stack: ..., this, val_lo (, val_hi, ...). Pop order:
    // value first then this. sp[-total_pop] = this; sp[-total_pop+1..sp] = value.
    const this_ref = frame.slab[frame.sp - total_pop];
    const v_lo: u32 = if (value_slots >= 1) frame.slab[frame.sp - total_pop + 1] else 0;
    const v_hi: u32 = if (value_slots >= 2) frame.slab[frame.sp - total_pop + 2] else 0;
    frame.sp -= total_pop;

    if (this_ref == 0) {
        log.warn("  PUTFIELD on NULL this — current frame returns (canonical sub_41B6B2)", .{});
        frame.returning = true;
        frame.ret_slots = 0;
        return;
    }
    const inst = vm.heap.get(this_ref) orelse {
        log.warn("  PUTFIELD on invalid handle — current frame returns", .{});
        frame.returning = true;
        frame.ret_slots = 0;
        return;
    };
    // Hash-keyed storage is functionally equivalent to canonical's
    // slot-based access for the gamelet corpus we have — verified
    // empirically (slot-mirror experiment showed no behavioral
    // difference for the JEU sub-menu bug). The slot field is read
    // from the descriptor for documentation but isn't used.
    // exen.Image.depth (hash 0xd042b3aa): the simulator treats
    // depth=0 as "device default" (8bpp on Manuf.003); a literal 0
    // here breaks the gamelet's `buf_size = w*h*depth/8` allocation.
    var v_lo_eff = v_lo;
    if (field_hash == 0xd042b3aa and v_lo == 0) v_lo_eff = 8;
    // Tactical trace for cursor field
    if (field_hash == 0xd042fb2d) {
        log.debug("CURSOR WRITE: value={d} this=0x{x} from {s} PC=0x{x:0>4}", .{
            v_lo_eff, this_ref, classStr(frame.method.class.hash), frame.pc -% 1,
        });
    }
    try inst.field_map.put(field_hash, v_lo_eff);
    if (value_slots >= 2) try inst.field_map.put(field_hash +% 1, v_hi);
    // Binding an Image as a Graphics draw target (FIELD_GFX_TARGET) makes
    // it a render target: its pixels come from compositing (drawImage),
    // not a palette-decoded resource. Mark it so doTransformToSystemPalette
    // never clobbers the composed pixels with a blank-indexed decode —
    // this is what made Pikubi2's menu-text strip render blank.
    if (field_hash == 0x3dd3bff1 and v_lo_eff != 0) {
        if (vm.heap.get(v_lo_eff)) |target_img| target_img.is_render_target = true;
    }
    log.debug("  PUTFIELD field=0x{x:0>8} tag=0x{x:0>4} this=0x{x:0>8} value=0x{x:0>8}", .{
        field_hash, type_tag, this_ref, v_lo_eff,
    });
    _ = slot;
}

pub fn opPutfieldFull(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const desc_off = frame.readU16();
    if (desc_off + 8 > frame.bytecode.len) return Error.StackOverflow;
    const field_hash = std.mem.readInt(u32, frame.bytecode[desc_off..][0..4], .little);
    const tag_word = std.mem.readInt(u16, frame.bytecode[desc_off + 4 ..][0..2], .little);
    const value_slots: u32 = (@as(u32, tag_word) >> 4) & 3;
    const total_pop = value_slots + 1;
    if (frame.sp < total_pop) return Error.StackUnderflow;

    const this_ref = frame.slab[frame.sp - total_pop];
    const v_lo: u32 = if (value_slots >= 1) frame.slab[frame.sp - total_pop + 1] else 0;
    const v_hi: u32 = if (value_slots >= 2) frame.slab[frame.sp - total_pop + 2] else 0;
    frame.sp -= total_pop;

    if (this_ref == 0) {
        log.warn("  PUTFIELD-full on NULL this — current frame returns (canonical sub_41B6B2)", .{});
        frame.returning = true;
        frame.ret_slots = 0;
        return;
    }
    const inst = vm.heap.get(this_ref) orelse {
        log.warn("  PUTFIELD-full on invalid handle — current frame returns", .{});
        frame.returning = true;
        frame.ret_slots = 0;
        return;
    };

    // Hash-keyed storage: the field's identity is its u32 hash, which
    // is unique across the class chain. No need to resolve a slot —
    // a future GETFIELD for the same hash will find the value back.
    try inst.field_map.put(field_hash, v_lo);
    if (value_slots >= 2) try inst.field_map.put(field_hash +% 1, v_hi);
    log.debug("  PUTFIELD-full field=0x{x:0>8} this=0x{x:0>8} value=0x{x:0>8}", .{
        field_hash, this_ref, v_lo,
    });
}

pub fn opGetfieldOwn(vm: *Vm, frame: *Frame, op: u8) Error!void {
    return doGetfield(vm, frame, op);
}

pub fn opGetfield(vm: *Vm, frame: *Frame, op: u8) Error!void {
    return doGetfield(vm, frame, op);
}

pub fn doGetfield(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const desc_off = frame.readU16();
    if (desc_off + 10 > frame.bytecode.len) return Error.StackOverflow;
    const field_hash = std.mem.readInt(u32, frame.bytecode[desc_off..][0..4], .little);
    const type_tag = std.mem.readInt(u16, frame.bytecode[desc_off + 6 ..][0..2], .little);
    const slot = std.mem.readInt(u16, frame.bytecode[desc_off + 8 ..][0..2], .little);

    const this_ref = try frame.pop();
    if (this_ref == 0) {
        log.warn("  GETFIELD on NULL this — current frame returns (canonical sub_41B6B2)", .{});
        frame.returning = true;
        frame.ret_slots = 0;
        return;
    }
    const inst = vm.heap.get(this_ref) orelse {
        log.warn("  GETFIELD on invalid handle — current frame returns", .{});
        frame.returning = true;
        frame.ret_slots = 0;
        return;
    };

    // Hash-keyed lookup (verified equivalent to canonical's slot-
    // based access for our gamelet corpus). Slot is read for
    // documentation only.
    _ = slot;
    const v = inst.field_map.get(field_hash) orelse 0;
    const v_hi = inst.field_map.get(field_hash +% 1) orelse 0;
    const fi_opt = vm.registry.findFieldInChain(inst.class_hash, field_hash);
    const tag: u16 = if (fi_opt) |fi| fi.type_tag else type_tag;
    log.debug("  GETFIELD field=0x{x:0>8} class=0x{x:0>8} tag=0x{x:0>4} value=0x{x:0>8}", .{
        field_hash, inst.class_hash, tag, v,
    });
    try pushTyped(frame, tag, v, v_hi);
}

/// Push a value onto the operand stack with type-aware packing. Used
/// by GETFIELD / GETSTATIC family to honour the descriptor's tag byte:
/// signed-extends 16-bit fields, masks byte fields, and pushes both
/// halves of a long.
fn pushTyped(frame: *Frame, type_tag: u16, v: u32, v_hi: u32) Error!void {
    const tag_lo = type_tag & 0xFF;
    if ((type_tag & 0xFF00) != 0 or tag_lo == 0x99 or tag_lo == 0x59) {
        try frame.push(v);
    } else if (tag_lo == 0x15) {
        const v16: i16 = @bitCast(@as(u16, @truncate(v)));
        const v_i: i32 = v16;
        try frame.push(@bitCast(v_i));
    } else if (tag_lo == 0x90 or tag_lo == 0xD5 or tag_lo == 0x50) {
        try frame.push(v & 0xFF);
    } else if (tag_lo == 0x6E) {
        try frame.push(v);
        try frame.push(v_hi);
    } else {
        try frame.push(v);
    }
}

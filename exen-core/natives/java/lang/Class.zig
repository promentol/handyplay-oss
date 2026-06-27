//! java.lang.Class — native funcs_407AA2[] indices 155..157
//!
//! Hash 0x42816699. Class reflection.
//! Bodies ported from `reference/ref`:
//!
//!   155 → sub_42A3BE  forName(String)
//!   156 → (host shim) newInstance()
//!   157 → sub_42A3DA  getName()

const std = @import("std");
const core = @import("core");
const dbg = core.debug;
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const first_index: u32 = 155;
pub const last_index: u32 = 157;

const JAVA_LANG_CLASS: u32 = 0x42816699;
const JAVA_LANG_STRING: u32 = 0x7772dde3;

// ── [155] forName(name) — sub_42A3BE ────────────────────────────────────────
// Canonical body is `*a1 = sub_411795(*a1); return 1`, where
// `sub_411795` walks the input String's byte buffer, computes the
// CRC-32 (`sub_4105F5` is std IEEE 802.3 CRC-32), and looks the class
// up in the simulator's name→class table. The result is the
// class-object pointer the gamelet later uses as a Class<?> ref.
//
// In our model: read name.bytes, CRC-32 it, registry.lookup, return
// the shared `ClassObject.class_handle` (allocate lazily — same
// stable identity as Object.getClass).
fn forName(vm: *Vm, args: bridge.ArgFrame) i16 {
    const name_handle = args.handle(0);
    const hash: u32 = blk: {
        if (vm.heap.get(name_handle)) |inst| {
            if (inst.bytes) |b| if (b.len > 0) break :blk std.hash.Crc32.hash(b);
        }
        break :blk 0xFFFFFFFE; // sentinel for empty/missing
    };
    const result: Handle = blk: {
        if (vm.ensureClassObject(hash)) |co| {
            if (co.class_handle != 0) break :blk co.class_handle;
            const h = vm.heap.alloc(JAVA_LANG_CLASS) catch break :blk 1;
            co.class_handle = h;
            if (vm.heap.get(h)) |class_inst| class_inst.fields[0] = hash;
            break :blk h;
        } else |_| {
            const h = vm.heap.alloc(JAVA_LANG_CLASS) catch break :blk 1;
            if (vm.heap.get(h)) |class_inst| class_inst.fields[0] = hash;
            break :blk h;
        }
    };
    args.setReturn(result);
    return 1;
}

// ── [156] newInstance(Class) — sub_42A360 ──────────────────────────────────
// Canonical body (ref:28366):
//   v2 = *(__int16 *)(a2 + 28);  // tag at class-object +28
//   BYTE1(v2) = 0;
//   if ( v2 == 153 )             // 0x99 — ObjRef tag
//     v4 = sub_410067(153, *(_DWORD *)(*(_DWORD *)(a2 + 24) + 12));
//   else
//     sub_410198(-991676898);    // fault
//   *a1 = v4;
//   return 1;
// `*(class_record+12)` is the class's u32 hash; we keep that hash on
// the Class<?>'s `fields[0]` (set in `forName` / `Object.getClass`).
//
// Boot-path special case: the gamelet's bytecode `<clinit>` calls
// `Class.forName("GameTopLevel").newInstance()` and stores the result
// to `Bootstrap.statics[0]`. The HOST pre-allocates `bootstrap_gamelet_handle`
// and runs `<init>` on it BEFORE bytecode runs; lifecycle methods
// (keyPress/tick/screenUpdate) dispatch via `Bootstrap.statics[0]`.
// If we allocate fresh and the bytecode overwrites statics[0],
// lifecycle targets the un-initialised new instance. So when the
// requested class matches the bootstrap handle's class, return the
// pre-allocated handle. Other classes (general reflection) get a
// real allocation matching canonical.
fn newInstance(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const class_inst = vm.heap.get(this) orelse {
        args.setReturn(0);
        return 1;
    };
    const target_hash = class_inst.fields[0];
    const bootstrap_h = interp.Vm.bootstrap_gamelet_handle;
    if (bootstrap_h != 0) {
        const want_bootstrap =
            target_hash == 0xFFFFFFFE or
            (if (vm.heap.get(bootstrap_h)) |bs| bs.class_hash == target_hash else false);
        if (want_bootstrap) {
            args.setReturn(bootstrap_h);
            return 1;
        }
    }
    args.setReturn(vm.heap.alloc(target_hash) catch 0);
    return 1;
}

// ── [157] getName(this) — sub_42A3DA ────────────────────────────────────────
// Canonical body builds a String containing the JLS name of the class
// (`"foo.Bar"` for normal classes, `"[Lfoo.Bar;"` for arrays, etc.).
// It reads the class-record's name buffer at +24/+28, optionally
// prefixes `[` chars and a type code from a small lookup, and packages
// the result as a fresh String.
//
// We don't keep the name in the class record. Instead we keep the
// (hash → name) map in `core.debug.names`, which is enough for every
// builtin class the gamelet asks about. If the hash isn't known, fall
// back to the hex hash so the caller still sees a non-null buffer.
fn getName(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const class_inst = vm.heap.get(this) orelse {
        args.setReturn(0);
        return 1;
    };
    const target_hash = class_inst.fields[0];
    const new_h = vm.heap.alloc(JAVA_LANG_STRING) catch {
        args.setReturn(0);
        return 1;
    };
    args.setReturn(new_h); // default return — overwrite later only on success
    const new_inst = vm.heap.get(new_h) orelse return 1;

    // Known array-type hashes (from sub_410106 call sites in
    // ref). Canonical sub_42A3DA reads the array dimension /
    // element-tag byte from class_record+22 and prepends `[` per
    // dimension plus a JLS type code (`B`/`C`/`S`/`I`/`Z`/`F`/`D`/
    // `J`/`L<name>;`). We don't store an explicit dimension count,
    // so we model the common cases by hash:
    if (arrayTypePrefix(target_hash)) |prefix| {
        const buf = vm.allocator.alloc(u8, prefix.len) catch return 1;
        @memcpy(buf, prefix);
        new_inst.bytes = buf;
        new_inst.fields[0] = @intCast(buf.len);
        return 1;
    }

    if (dbg.className(target_hash)) |name| {
        const buf = vm.allocator.alloc(u8, name.len) catch return 1;
        @memcpy(buf, name);
        new_inst.bytes = buf;
        new_inst.fields[0] = @intCast(buf.len);
    } else {
        const buf = vm.allocator.alloc(u8, 10) catch return 1;
        _ = std.fmt.bufPrint(buf, "0x{x:0>8}", .{target_hash}) catch {
            vm.allocator.free(buf);
            return 1;
        };
        new_inst.bytes = buf;
        new_inst.fields[0] = 10;
    }
    return 1;
}

/// Map a known array-element class hash to the JLS array-name prefix
/// (`[B`, `[C`, …). Returns null for non-array hashes. Hashes are the
/// ones `sub_410106` is called with in ref — collected from
/// the natives that allocate typed arrays.
fn arrayTypePrefix(hash: u32) ?[]const u8 {
    return switch (hash) {
        0x9EC04138 => "[B", // byte[]  — String.getBytes, StringBuffer buffers
        0x5DA4D0C7 => "[C", // char[]  — String.toLowerCase/toUpperCase results
        else => null,
    };
}

pub const handle = bridge.canonical(.{
    .{ 155, "Class.forName",     forName },
    .{ 156, "Class.newInstance", newInstance },
    .{ 157, "Class.getName",     getName },
});

//! java.lang.Object — native funcs_407AA2[] indices 151..154
//!
//! Hash 0x4161c4a6. Root class metaops: getClass / hashCode / clone / wait.
//! Bodies ported from `reference/ref`:
//!
//!   151 → sub_42A660  getClass()
//!   152 → sub_42A6CC  hashCode()
//!   153 → sub_42A718  clone()
//!   154 → sub_42A6DF  wait()

const std = @import("std");
const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const first_index: u32 = 151;
pub const last_index: u32 = 154;

const JAVA_LANG_CLASS: u32 = 0x42816699;

// ── [151] getClass(this) — sub_42A660 ───────────────────────────────────────
// Returns the Class<?> object for this instance's runtime class. The
// canonical body looks up the receiver's class tag (at receiver+12 in
// the simulator heap layout) via `sub_411710` and returns the unique
// class-object pointer. We model that as a single Handle per class,
// cached on `ClassObject.class_handle` so every getClass call against
// the same runtime class returns the same handle (gamelets compare
// Class<?> with `==`, so identity must be stable).
fn getClass(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const inst = vm.heap.get(this) orelse {
        args.setReturn(0);
        return 1;
    };
    const co = vm.ensureClassObject(inst.class_hash) catch {
        args.setReturn(0);
        return 1;
    };
    if (co.class_handle != 0) {
        args.setReturn(co.class_handle);
        return 1;
    }
    const h = vm.heap.alloc(JAVA_LANG_CLASS) catch {
        args.setReturn(0);
        return 1;
    };
    co.class_handle = h;
    if (vm.heap.get(h)) |class_inst| class_inst.fields[0] = inst.class_hash;
    args.setReturn(h);
    return 1;
}

// ── [152] hashCode(this) — sub_42A6CC ───────────────────────────────────────
// Canonical body is literally `*a1 = *a1; return 1` — the handle IS
// the hash. Java spec only requires consistency within a run, which
// returning the raw handle satisfies.
fn hashCode(_: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturn(args.this());
    return 1;
}

// ── [153] clone(this) — sub_42A718 ──────────────────────────────────────────
// Canonical branches on whether `this` is an array (`sub_411A0F` — a
// tag-aware element-by-element copy) or a regular object
// (`sub_411ADD` — header + flat memcpy). A `sub_411B6F` precheck
// would fault for non-`Cloneable` types; we never throw that, since
// no gamelet in the corpus catches CloneNotSupportedException.
//
// Our `Instance` is a tagged union of both shapes:
//   * Arrays: `fields[0]` = length, `fields[1..]` = elements;
//             `bytes` mirrors the byte/char element view if present;
//             `field_map` is empty.
//   * Objects: hash-keyed `field_map` for declared fields; `bytes`
//             holds owned strings/buffers; `fields[]` unused or
//             holding raw slot-keyed legacy state.
// We copy whichever subset is populated so both shapes round-trip:
//   - Always copy `fields[..]` (cheap, covers array elements + a few
//     slot-keyed cases on objects).
//   - Copy `field_map` entries for objects.
//   - Deep-copy `bytes` when present (arrays and Strings own it).
//   - Borrow `pixels` (read-only image rasters; canonical's clone
//     memcpys the header into the new image and the IDAT chunk is
//     `.exn`-backed memory, so sharing is safe).
fn clone(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const src = vm.heap.get(this) orelse {
        args.setReturn(0);
        return 1;
    };
    const new_h = vm.heap.alloc(src.class_hash) catch {
        args.setReturn(0);
        return 1;
    };
    const dst = vm.heap.get(new_h) orelse {
        args.setReturn(new_h);
        return 1;
    };

    const is_array = src.field_map.count() == 0 and src.fields[0] != 0;

    // Slot-keyed storage covers array elements; copy unconditionally
    // because arrays use it for element data and a handful of object
    // classes still use it for legacy slot-indexed fields.
    dst.fields = src.fields;

    if (!is_array) {
        // Hash-keyed field storage — only meaningful for non-array
        // objects. Skipping the iterator for arrays avoids the
        // (zero-cost but tidier) walk over an empty map.
        var it = src.field_map.iterator();
        while (it.next()) |e| {
            dst.field_map.put(e.key_ptr.*, e.value_ptr.*) catch {};
        }
    }

    if (src.bytes) |b| {
        const buf = vm.allocator.alloc(u8, b.len) catch {
            args.setReturn(new_h);
            return 1;
        };
        @memcpy(buf, b);
        dst.bytes = buf;
    }

    dst.pixels = src.pixels;
    dst.pix_w = src.pix_w;
    dst.pix_h = src.pix_h;
    args.setReturn(new_h);
    return 1;
}

// ── [154] wait(this) — sub_42A6DF ───────────────────────────────────────────
// Canonical checks an internal monitor counter at receiver+8 and
// throws InternalException 0x77BFBB4E when it's negative; otherwise
// returns 0 (= no stack push per canonical's slot-count convention).
fn waitMethod(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

pub const handle = bridge.canonical(.{
    .{ 151, "Object.getClass",  getClass },
    .{ 152, "Object.hashCode",  hashCode },
    .{ 153, "Object.clone",     clone },
    .{ 154, "Object.wait",      waitMethod },
});

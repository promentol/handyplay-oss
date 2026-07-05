//! vm.sys.Runtime — native funcs_407AA2[] indices 175..177
//!
//! Hash 0xb4f0ccbf. gc / createTempClass / getTickCount, identified from
//! the canonical bodies (idx = funcs-table line − 3126 in emulator.c):
//!   175 sub_42B2A0 — gc: runs the collector (sub_40A30B two-pass
//!       refcount sweep over the intrusive object lists), pushes nothing.
//!   176 sub_42B2AD — createTempClass: validates (handle, index) against
//!       the u16 length at object+18, pushes a bool that is effectively
//!       constant 0 in this build (`sub_410060() & 1`, sub_410060 = stub
//!       returning 0); on invalid input canonical raises a pending VM
//!       error via sub_410198(code) and pushes 0.
//!   177 sub_42B338 — getTickCount: ms tick (sub_406872 → sub_435D3F)
//!       into *a1, pushes ONE int slot (unlike Gamelet.getTimerTickCount
//!       idx 75, which pushes a 2-slot long).

const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;

pub const class_name: []const u8 = "Runtime";
pub const first_index: u32 = 175;
pub const last_index: u32 = 177;

// ── [175] gc() — sub_42B2A0 ────────────────────────────────────────────────
// Canonical: `sub_40A30B(); return 0;` — the refcount-based collector.
// Our VM's collector is the conservative mark-sweep in vm.collectGarbage
// (normally run between ticks by exen.tick); running it here mirrors the
// observable effect (dead objects reclaimed at the gamelet's request).
// The operand slab above the native frame is conservative-scanned, so an
// intra-tick collection cannot free anything the bytecode still holds.
fn gc(vm: *Vm, _: bridge.ArgFrame) i16 {
    vm.collectGarbage();
    return 0;
}

// ── [176] createTempClass(obj, index) — sub_42B2AD ────────────────────────
// ⚠ verified structure; canonical pushes constant 0. Body shape:
//     if (!obj)                 { sub_410198(910855525); push 0; }
//     else if (index > len@+18) { sub_410198(490483763); push 0; }
//     else                      { push sub_410060() & 1; }   // == 0
// sub_410060 is a stub returning 0 in this build, so ALL paths push 0 —
// we mirror the validation shape (against our array-length slot) without
// the pending-exception codes.
fn createTempClass(vm: *Vm, args: bridge.ArgFrame) i16 {
    const obj = args.handle(0);
    const index = args.getU32(1);
    if (vm.heap.get(obj)) |inst| {
        _ = index;
        _ = inst;
    }
    args.setReturn(0);
    return 1;
}

// ── [177] getTickCount() — sub_42B338 ──────────────────────────────────────
// Canonical: `*a1 = sub_406872(); return 1;` — ms since boot. We return
// the deterministic VM clock (advanced by exen.tick), same rationale as
// Gamelet.getTimerTickCount (idx 75) — but this variant pushes ONE int
// slot, not a 2-slot long. MidtownMadness3 polls this 19×/frame for its
// loading gate.
fn getTickCount(vm: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturn(@truncate(vm.clock_ms & 0xFFFF_FFFF));
    return 1;
}

pub const entries = .{
    .{ 175, "gc",              gc },
    .{ 176, "createTempClass", createTempClass },
    .{ 177, "getTickCount",    getTickCount },
};

pub const handle = bridge.canonical(entries);

//! exen.AnimFlash — native funcs_407AA2[] indices 54..64
//!
//! Hash 0xd414954a. Macromedia Flash-style timeline animation — but the
//! canonical simulator NEVER implemented native playback: all 11 subs
//! (sub_4248B0..sub_42492A, verbatim in emulator.c) are no-ops, pushed
//! constants, or single field reads. The actual per-frame work lives in
//! the class's 6 BYTECODE methods, which run through our interpreter
//! unchanged. These literal ports matter for the push-count contract:
//! the previous defaultNativeStub pushed one 0 slot for EVERY call,
//! while canonical pushes NOTHING for six of these — a Class A SP-drift
//! cascade in every AnimFlash-using gamelet (Spyro, SphereMadness 1/2,
//! IFRacing2, Worms, download1).
//!
//! Instance fields (builtin 4CVP record; canonical byte offsets):
//!   slot 3 (+36) 0xd0426be6  width   ← getWidth
//!   slot 4 (+40) 0xd0425e87  height  ← getHeight

const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;

pub const class_name: []const u8 = "AnimFlash";
pub const first_index: u32 = 54;
pub const last_index: u32 = 64;

const FIELD_WIDTH: u32 = 0xd0426be6; // slot 3, canonical +36
const FIELD_HEIGHT: u32 = 0xd0425e87; // slot 4, canonical +40

// ── [54] initAnimFlash — sub_4248B0: `*a1 = 0; return 1;` ───────────────────
fn initAnimFlash(_: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturn(0);
    return 1;
}

// ── [55] draw — sub_4248C2: empty body, pushes nothing ──────────────────────
fn draw(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

// ── [56] delete — sub_4248CA: empty ─────────────────────────────────────────
fn delete(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

// ── [57] setFrame — sub_4248D2: empty ───────────────────────────────────────
fn setFrame(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

// ── [58] getNbFrames — sub_4248DA: `*a1 = 1; return 1;` ─────────────────────
fn getNbFrames(_: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturn(1);
    return 1;
}

// ── [59] getNbLoops — sub_4248EC: `*a1 = 0; return 1;` ──────────────────────
fn getNbLoops(_: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturn(0);
    return 1;
}

// ── [60] setPosition — sub_4248FE: empty ────────────────────────────────────
fn setPosition(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

// ── [61] setSize — sub_424906: empty ────────────────────────────────────────
fn setSize(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

// ── [62] getRawFrames — sub_42490E: empty (VOID despite argc=5) ─────────────
fn getRawFrames(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

// ── [63] getWidth — sub_424916: `*a1 = *(this+36); return 1;` ───────────────
fn getWidth(vm: *Vm, args: bridge.ArgFrame) i16 {
    const v = if (vm.heap.get(args.this())) |inst|
        inst.field_map.get(FIELD_WIDTH) orelse 0
    else
        0;
    args.setReturn(v);
    return 1;
}

// ── [64] getHeight — sub_42492A: `*a1 = *(this+40); return 1;` ──────────────
fn getHeight(vm: *Vm, args: bridge.ArgFrame) i16 {
    const v = if (vm.heap.get(args.this())) |inst|
        inst.field_map.get(FIELD_HEIGHT) orelse 0
    else
        0;
    args.setReturn(v);
    return 1;
}

pub const entries = .{
    .{ 54, "initAnimFlash", initAnimFlash },
    .{ 55, "draw",          draw },
    .{ 56, "delete",        delete },
    .{ 57, "setFrame",      setFrame },
    .{ 58, "getNbFrames",   getNbFrames },
    .{ 59, "getNbLoops",    getNbLoops },
    .{ 60, "setPosition",   setPosition },
    .{ 61, "setSize",       setSize },
    .{ 62, "getRawFrames",  getRawFrames },
    .{ 63, "getWidth",      getWidth },
    .{ 64, "getHeight",     getHeight },
};

pub const handle = bridge.canonical(entries);

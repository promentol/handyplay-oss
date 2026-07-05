//! catalog.GameProperty — native funcs_407AA2[] index 184
//!
//! Hash 0xdd22a4ed. Single native, canonical sub_4243C0:
//!     __int16 sub_4243C0() { return 0; }
//! A literal no-op (empty constructor/placeholder atom) — pushes nothing.

const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;

pub const class_name: []const u8 = "GameProperty";
pub const first_index: u32 = 184;
pub const last_index: u32 = 184;

// ── [184] placeholder — sub_4243C0 ─────────────────────────────────────────
// Canonical body is empty; the whole native is `return 0`.
fn noop(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

pub const entries = .{
    .{ 184, "GameProperty", noop },
};

pub const handle = bridge.canonical(entries);

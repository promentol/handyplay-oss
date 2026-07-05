//! exen.util.Debug — native funcs_407AA2[] indices 147..150
//!
//! Hash 0x11749d8a. Host-side debug print sinks.
//! Per-class method table (extracted from unk_4494F0.bin):
//!   idx 147  sub_429E68  hash=?            unported
//!   idx 148  sub_429EFA  hash=?            unported
//!   idx 149  sub_429F50  hash=?            unported
//!   idx 150  sub_429FC2  hash=0x305aa2f2   printInt(int)  ✓ ported
//!
//! Canonical sub_429FC2 body (ref:28070):
//!   v3 = sub_422D10(*a1, 16, v2);   // format int → buffer (max 16 chars)
//!   if (v3 == -2) { sub_434771("non-catcheable I"); sub_407A13(); return v3; }
//!   sub_434760(v2);                  // host debug-string sink
//!   return 0;
//!
//! sub_422D10 is the sprintf-like int-to-decimal formatter. sub_434760 is
//! the host's debug-print sink (in the reference simulator it routes to OutputDebugString
//! / console). We mirror by routing through std.log.

const std = @import("std");
const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;

pub const class_name: []const u8 = "Debug";
pub const first_index: u32 = 147;
pub const last_index: u32 = 150;

const gamelet_log = std.log.scoped(.gamelet);

// ── [150] sub_429FC2 — Debug.printInt(int) ─────────────────────────────────
fn printInt(_: *Vm, args: bridge.ArgFrame) i16 {
    gamelet_log.info("{d}", .{args.getI32(0)});
    return 0;
}

/// Known names for idxs in this class's range that have NO Zig handler
/// yet (they hit `defaultNativeStub` at runtime). Consumed by
/// `natives/mod.zig::native_names` for logs/tools; idxs in range but
/// absent here AND in `entries` render as "Class.?N". When porting one
/// of these, move the row into `entries` with its handler.
pub const stub_names = .{
    .{ 147, "DisplayText" },           // sub_429F40
    .{ 148, "WaitForKey" },            // sub_429FB2
    .{ 149, "DisplayMemoryBlocks" },   // sub_429FBA
};

pub const entries = .{
    .{ 150, "printInt", printInt },
};

pub const handle = bridge.canonical(entries);

//! exen.List — native funcs_407AA2[] indices 109..109
//!
//! Hash 0xdf774e57. Scrollable text-list widget.
//! Spec: docs/native_index_map.md. Each handler ports the corresponding
//! `sub_*` body from `reference/ref`.
//!
//! Currently delegates to the legacy monolithic dispatcher in
//! `core/vm/interp.zig` so behaviour is byte-identical to pre-split.
//! Per-index migration into this file is incremental: replace the
//! delegate with a per-idx switch as each native gets a faithful
//! port + tests.

const core = @import("core");
const interp = core.interp;

pub const class_name: []const u8 = "List";
pub const first_index: u32 = 109;
pub const last_index: u32 = 109;

/// Known names for idxs in this class's range that have NO Zig handler
/// yet (they hit `defaultNativeStub` at runtime). Consumed by
/// `natives/mod.zig::native_names` for logs/tools; idxs in range but
/// absent here AND in `entries` render as "Class.?N". When porting one
/// of these, move the row into `entries` with its handler.
pub const stub_names = .{
    .{ 109, "drawList" },   // sub_426870
};


pub fn handle(vm: *interp.Vm, idx: u32, frame: *interp.Frame) interp.Error!void {
    return interp.defaultNativeStub(vm, idx, frame);
}

//! exen.AnimFlash — native funcs_407AA2[] indices 54..64
//!
//! Hash 0xd414954a. Macromedia Flash-style timeline animation.
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

pub const first_index: u32 = 54;
pub const last_index: u32 = 64;

pub fn handle(vm: *interp.Vm, idx: u32, frame: *interp.Frame) interp.Error!void {
    return interp.defaultNativeStub(vm, idx, frame);
}

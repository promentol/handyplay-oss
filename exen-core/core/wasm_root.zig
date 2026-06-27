//! WASM-only module root. Re-exports just the freestanding-safe
//! pieces of `core` (no VM, no filesystem, no SDL/audio dependencies).
//!
//! Used by the `wasm` frontend so the build doesn't drag in the
//! interpreter / dispatch tables / audio backend that don't compile
//! on wasm32-freestanding.

pub const exn_metadata = @import("exn/metadata.zig");
pub const exn_loader = @import("exn/loader.zig");
pub const png = @import("codecs/png.zig");

//! WASM frontend — read-only catalog/launcher API.
//!
//! Exposes a small set of `export fn` symbols that a JS host can call
//! to validate a .exn buffer, read its gamelet name, and locate its
//! icon PNG. Designed so the JS side controls memory: JS allocates a
//! buffer via `wasm_alloc`, writes the .exn bytes into the wasm
//! memory at that pointer, then passes (ptr, len) to the query
//! functions.
//!
//! ABI summary (all functions are C-callconv, freestanding wasm32):
//!
//!   void* wasm_alloc(usize size)
//!     Allocate `size` bytes of wasm memory. Returns a pointer (offset
//!     into `memory`) the JS host can write into. NULL on OOM.
//!
//!   void wasm_free(void* ptr, usize size)
//!     Free a buffer obtained from `wasm_alloc`. `size` MUST match.
//!
//!   i32 exn_validate(const u8* ptr, usize len)
//!     Returns 0 if the buffer is a valid NEXE-magic .exn with a
//!     well-formed name region. Negative = error code (see below).
//!
//!   i32 exn_name_into(const u8* ptr, usize len, u8* out, usize cap)
//!     Copies the gamelet name (e.g. "TheTerminator") into `out` and
//!     returns the byte length written. Negative on error.
//!
//!   i32 exn_icon_info(const u8* ptr, usize len, u32* out)
//!     `out` MUST point at a 16-byte buffer (4 × u32 LE). On success
//!     writes [width, height, png_offset, png_length] and returns 0.
//!     Returns -ENO_ICON when the gamelet has no image section.
//!
//! Error codes (all negative; positive returns are payload lengths):
//!   -1  invalid magic                (E_BAD_MAGIC)
//!   -2  name region not terminated   (E_BAD_NAME)
//!   -3  output buffer too small      (E_BUF_TOO_SMALL)
//!   -4  no icon section in this .exn (E_NO_ICON)
//!   -5  unexpected allocator failure (E_OOM)

const std = @import("std");
// We import a narrow wasm-only root (`core/wasm_root.zig`) so the
// build doesn't drag in vm_state / dispatch tables / audio backend —
// those don't compile on wasm32-freestanding.
const wasm_core = @import("metadata");
const meta = wasm_core.exn_metadata;
const png = wasm_core.png;

// ── Error codes ─────────────────────────────────────────────────────────────
const E_BAD_MAGIC: i32 = -1;
const E_BAD_NAME: i32 = -2;
const E_BUF_TOO_SMALL: i32 = -3;
const E_NO_ICON: i32 = -4;
const E_OOM: i32 = -5;

// ── Allocator ──────────────────────────────────────────────────────────────
// `std.heap.wasm_allocator` grows the wasm linear memory via the
// `memory.grow` instruction; freed regions go back to a freelist. It
// has no threading / posix dependencies, making it ideal for
// freestanding wasm builds. The caller (JS) is responsible for
// remembering each allocation's size so it can pass it back to free.
const alloc: std.mem.Allocator = std.heap.wasm_allocator;

export fn wasm_alloc(size: usize) ?[*]u8 {
    const buf = alloc.alloc(u8, size) catch return null;
    return buf.ptr;
}

export fn wasm_free(ptr: [*]u8, size: usize) void {
    alloc.free(ptr[0..size]);
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn errToCode(err: anyerror) i32 {
    return switch (err) {
        error.NotAnExnFile => E_BAD_MAGIC,
        error.NameNotTerminated => E_BAD_NAME,
        error.OutOfMemory => E_OOM,
        else => E_OOM,
    };
}

// ── Exports ────────────────────────────────────────────────────────────────

export fn exn_validate(ptr: [*]const u8, len: usize) i32 {
    meta.validate(ptr[0..len]) catch |err| return errToCode(err);
    return 0;
}

export fn exn_name_into(ptr: [*]const u8, len: usize, out: [*]u8, cap: usize) i32 {
    const name = meta.getName(ptr[0..len]) catch |err| return errToCode(err);
    if (name.len > cap) return E_BUF_TOO_SMALL;
    @memcpy(out[0..name.len], name);
    return @intCast(name.len);
}

/// Returns the byte length of the gamelet name without copying. Useful
/// for sizing a buffer before calling `exn_name_into`. Negative on
/// validation failure.
export fn exn_name_len(ptr: [*]const u8, len: usize) i32 {
    const name = meta.getName(ptr[0..len]) catch |err| return errToCode(err);
    return @intCast(name.len);
}

export fn exn_icon_info(ptr: [*]const u8, len: usize, out: [*]u32) i32 {
    meta.validate(ptr[0..len]) catch |err| return errToCode(err);
    const icon = meta.getIcon(alloc, ptr[0..len]) catch |err| return errToCode(err);
    const i = icon orelse return E_NO_ICON;
    out[0] = i.width;
    out[1] = i.height;
    out[2] = i.png_offset;
    out[3] = i.png_length;
    return 0;
}

/// Returns the number of sections in the layout table (excluding the
/// sentinel). 0 when the layout table can't be parsed (malformed or
/// truncated). Useful as a sanity probe alongside `exn_validate`.
export fn exn_section_count(ptr: [*]const u8, len: usize) i32 {
    const m = meta.readMetadataBytes(alloc, ptr[0..len]) catch |err| return errToCode(err);
    return @intCast(m.section_count);
}

/// Decode the gamelet icon into a raw RGBA8888 pixel buffer.
///
/// ExEn's embedded PNGs declare IHDR `compression=1` (codec-1..5
/// dispatch) — that's invalid per the PNG spec, so browsers refuse to
/// render the raw bytes. This export runs our internal codec
/// (`core/codecs/png.zig`), which handles the ExEn variant, and
/// returns a heap-allocated RGBA buffer the JS host can wrap in an
/// `ImageData` and paint onto a `<canvas>`.
///
/// On success: writes `[width, height, pixels_ptr]` into `out_info[0..3]`
/// (three u32 slots), and returns 0. The caller MUST free
/// `pixels_ptr` later with `wasm_free(pixels_ptr, width * height * 4)`.
///
/// On error: returns a negative code; `out_info` is untouched.
export fn exn_icon_decode_rgba(ptr: [*]const u8, len: usize, out_info: [*]u32) i32 {
    meta.validate(ptr[0..len]) catch |err| return errToCode(err);
    const icon = meta.getIcon(alloc, ptr[0..len]) catch |err| return errToCode(err);
    const i = icon orelse return E_NO_ICON;

    const decoded = png.decodePngToAbgr(alloc, ptr[0..len], i.png_offset) catch return E_OOM;
    // `decoded.pixels` is a [*]u32 of ABGR8888 values (R lo, A hi).
    // Canvas `ImageData` wants RGBA8888 (R lo, A hi) — same byte order
    // when viewed as little-endian u32, so no swizzle needed.
    out_info[0] = decoded.width;
    out_info[1] = decoded.height;
    out_info[2] = @intFromPtr(decoded.pixels.ptr);
    return 0;
}

// ── wasm entry point ────────────────────────────────────────────────────────
// Freestanding wasm32 needs a `_start` so the linker accepts the module.
// We don't run any startup logic; JS drives the lifecycle entirely.

pub export fn _start() void {}

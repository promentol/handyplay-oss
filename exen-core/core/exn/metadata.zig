//! Lightweight, read-only metadata extraction from a .exn gamelet file.
//!
//! Pure bytes-in API — no filesystem, no allocator-heavy state. Safe
//! to compile on wasm32-freestanding. Filesystem-taking conveniences
//! (`readName`, `readMetadata`, `readIconPng`) live in
//! `metadata_fs.zig` so they don't get pulled into the wasm build.
//!
//! Designed for launchers, catalog UIs, and tooling that needs to
//! display a gamelet's name and icon WITHOUT booting the VM.
//!
//! Icon convention: the gamelet's first image section under the
//! top-level layout table. Most the platform gamelets follow the pattern
//! "section 1 = splash/title image" (verified across TheTerminator,
//! Crash, Spyro, BombSquad, EagleSquadron, Pikubi).

const std = @import("std");
const loader = @import("loader.zig");
const classfile = @import("../classfile/methods.zig");

pub const Error = loader.Error || std.mem.Allocator.Error || error{ ReadFailed, BufferTooSmall };

/// Icon (PNG) location inside the .exn buffer. `png_offset` /
/// `png_length` reference the original `[]const u8` you passed in, so
/// the bytes are `bytes[png_offset .. png_offset + png_length]`.
pub const Icon = struct {
    width: u16,
    height: u16,
    png_offset: u32,
    png_length: u32,
};

/// In-memory snapshot. Slices view into the input buffer — caller must
/// keep the buffer alive while using these fields.
pub const Metadata = struct {
    name: []const u8,
    file_size: usize,
    section_count: u32,
    icon: ?Icon = null,
};

/// Validate the .exn header. Returns `Error.NotAnExnFile` if the magic
/// is wrong, `Error.NameNotTerminated` if the name region is malformed.
/// Doesn't allocate.
pub fn validate(bytes: []const u8) Error!void {
    if (bytes.len < 24) return loader.Error.NotAnExnFile;
    if (!(bytes[0] == 'N' and bytes[1] == 'E' and bytes[2] == 'X' and bytes[3] == 'E')) {
        return loader.Error.NotAnExnFile;
    }
    var i: usize = 20;
    while (i < bytes.len and bytes[i] != '.' and bytes[i] != 0) : (i += 1) {}
    if (i >= bytes.len or i == 20) return loader.Error.NameNotTerminated;
}

/// Return a slice into `bytes` containing the gamelet name. Cheap: no
/// allocation, no section walk.
pub fn getName(bytes: []const u8) Error![]const u8 {
    try validate(bytes);
    var i: usize = 20;
    while (i < bytes.len and bytes[i] != '.' and bytes[i] != 0) : (i += 1) {}
    return bytes[20..i];
}

/// Locate the gamelet's launcher icon in the .exn buffer. Returns null
/// when no PNG signature is found.
///
/// Selection strategy (in order):
///   1. **flag=0xff convention.** Parse the class-file's method/resource
///      table; the per-resource flag byte at `0xff` is the canonical
///      "launcher icon" marker (used by ~17 of 50 sampled gamelets, e.g.
///      SphereMadness res[3] 64×64, GhostHunter res[0] 100×120,
///      MotoGp res[0] 88×36). When a 0xff-flagged resource contains a
///      PNG signature, return that one.
///   2. **First PNG signature.** Fallback for gamelets that don't tag
///      their icon explicitly — scan the whole file linearly. Picks up
///      the splash/title strip on TheTerminator, Crash, Spyro, etc.
///
/// In both cases the 6 bytes preceding the signature in canonical ExEn
/// image sections encode (width:u16le, height:u16le, idat_len:u16le);
/// we read width/height from there when those bytes look sane,
/// otherwise pull them from the PNG IHDR (which is big-endian u32).
pub fn getIcon(allocator: std.mem.Allocator, bytes: []const u8) Error!?Icon {
    try validate(bytes);

    const png_sig = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

    // 1) Honour the canonical 0xff icon marker.
    if (classfile.parse(allocator, bytes)) |cf_const| {
        var cf = cf_const;
        defer cf.deinit();
        for (cf.methods) |m| {
            if (m.flag != 0xff) continue;
            if (m.offset >= bytes.len) continue;
            const end = @min(@as(usize, m.offset) + @as(usize, m.length), bytes.len);
            const body = bytes[m.offset..end];
            // Search inside this resource's slice — the PNG may sit
            // 0..32 bytes into the resource body (ExEn prepends a
            // small width/height header in some gamelets).
            var k: usize = 0;
            while (k + 8 <= body.len) : (k += 1) {
                if (!std.mem.eql(u8, body[k .. k + 8], &png_sig)) continue;
                const abs_off: usize = @as(usize, m.offset) + k;
                return iconFromSignature(bytes, abs_off);
            }
        }
    } else |_| {}

    // 2) Fallback: first PNG signature anywhere in the file.
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 1) {
        if (std.mem.eql(u8, bytes[i .. i + 8], &png_sig)) {
            return iconFromSignature(bytes, i);
        }
    }
    return null;
}

/// Build an `Icon` descriptor from a PNG signature at `bytes[sig_off]`.
fn iconFromSignature(bytes: []const u8, sig_off: usize) Icon {
    const png_len = pngStreamLength(bytes, sig_off);
    var w: u16 = 0;
    var h: u16 = 0;
    if (sig_off >= 6) {
        const prefix_w = std.mem.readInt(u16, bytes[sig_off - 6 ..][0..2], .little);
        const prefix_h = std.mem.readInt(u16, bytes[sig_off - 4 ..][0..2], .little);
        if (prefix_w > 0 and prefix_w <= 1024 and prefix_h > 0 and prefix_h <= 1024) {
            w = prefix_w;
            h = prefix_h;
        }
    }
    if (w == 0 or h == 0) {
        if (sig_off + 24 <= bytes.len and std.mem.eql(u8, bytes[sig_off + 12 .. sig_off + 16], "IHDR")) {
            const iw = std.mem.readInt(u32, bytes[sig_off + 16 ..][0..4], .big);
            const ih = std.mem.readInt(u32, bytes[sig_off + 20 ..][0..4], .big);
            w = @intCast(@min(iw, 65535));
            h = @intCast(@min(ih, 65535));
        }
    }
    return Icon{
        .width = w,
        .height = h,
        .png_offset = @intCast(sig_off),
        .png_length = @intCast(png_len),
    };
}

/// Compute the length of a PNG stream starting at `bytes[start]`. Walks
/// chunks until IEND. Falls back to "until EOF" on malformed chunk
/// lengths so we never return a 0-length stream for a valid signature.
fn pngStreamLength(bytes: []const u8, start: usize) usize {
    if (start + 8 > bytes.len) return bytes.len - start;
    var p: usize = start + 8; // skip 8-byte signature
    while (p + 12 <= bytes.len) {
        const chunk_len = std.mem.readInt(u32, bytes[p..][0..4], .big);
        const type_off = p + 4;
        // chunk body + 4-byte CRC follow the type tag
        const next = type_off + 4 + @as(usize, chunk_len) + 4;
        if (next > bytes.len) return bytes.len - start;
        if (std.mem.eql(u8, bytes[type_off..][0..4], "IEND")) return next - start;
        p = next;
    }
    return bytes.len - start;
}

/// One-call snapshot: name + size + section count + optional icon.
/// All slices view into `bytes`; no heap allocation survives past return.
pub fn readMetadataBytes(allocator: std.mem.Allocator, bytes: []const u8) Error!Metadata {
    try validate(bytes);
    const name = try getName(bytes);

    var meta: Metadata = .{
        .name = name,
        .file_size = bytes.len,
        .section_count = 0,
        .icon = null,
    };

    // Section count is informational only — older gamelets like MotoGp
    // have a non-4-aligned offset table that fails parseLayout's
    // strictness, so we skip it on error and just leave section_count=0.
    if (loader.parseLayout(allocator, bytes)) |layout_const| {
        var layout = layout_const;
        meta.section_count = layout.section_count;
        layout.deinit();
    } else |_| {}

    meta.icon = try getIcon(allocator, bytes);
    return meta;
}

// ── tests ──────────────────────────────────────────────────────────────────

test "validate accepts a NEXE header" {
    var buf: [40]u8 = undefined;
    @memset(&buf, 0);
    @memcpy(buf[0..4], "NEXE");
    @memcpy(buf[20..31], "Hello.world");
    try validate(&buf);
}

test "validate rejects bad magic" {
    var buf: [40]u8 = undefined;
    @memset(&buf, 0);
    @memcpy(buf[0..4], "XXXX");
    @memcpy(buf[20..31], "Hello.world");
    try std.testing.expectError(loader.Error.NotAnExnFile, validate(&buf));
}

test "getName slices the gamelet stem" {
    var buf: [40]u8 = undefined;
    @memset(&buf, 0);
    @memcpy(buf[0..4], "NEXE");
    @memcpy(buf[20..31], "Hello.world");
    const n = try getName(&buf);
    try std.testing.expectEqualStrings("Hello", n);
}

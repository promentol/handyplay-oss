//! exen.Gamelet — native funcs_407AA2[] indices 67..88
//!
//! Hash 0xe127b0e1. Lifecycle, screen info, timer, audio, SMS.
//! Spec: docs/native_index_map.md. Each handler ports the corresponding
//! `sub_*` body from `reference/ref`.
//!
//! First class fully migrated to the comptime `bridge` API — every
//! handler below is a plain Zig function with typed args. The
//! frame-marshalling shim is generated at comptime by `bridge.wrap`,
//! so there's no runtime cost vs the manual `nativeArg`/`ret_value`
//! pattern.

const std = @import("std");
const core = @import("core");
const _h = @import("../_helpers.zig");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const first_index: u32 = 67;
pub const last_index: u32 = 88;

// ── Display-capability quintet (idx 67..71) ─────────────────────────────────
// Canonical layering: a single device-bitmap-depth value (`sub_4022BA`)
// is the source of truth; the other natives derive from it via
// `sub_4022CB` (1 << depth) and `sub_4022DE` ((depth != 1)). Width and
// height come from a separate device-descriptor block initialized
// from the simulator's per-device config (Manuf.003 = 132×176).
//
// Modeling all five faithfully against canonical, with a single
// `device_bitmap_depth` constant standing in for the device-config
// `dword_45C7C4`-style field. Bumping it to e.g. 16 auto-updates the
// derived natives.
const device_bitmap_depth: u32 = 8;

// ── [67] isColor() — sub_424F70 → sub_4022DE: (depth != 1) ─────────────────
fn isColor(_: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturnI32(if (device_bitmap_depth != 1) 1 else 0);
    return 1;
}

// ── [68] numColors() — sub_424F86 → sub_4022CB: 1 << depth ─────────────────
fn numColors(_: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturnI32(@as(i32, 1) << @intCast(device_bitmap_depth));
    return 1;
}

// ── [69] getBitmapDepth() — sub_424FAC → sub_4022BA: depth ─────────────────
fn getBitmapDepth(_: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturnI32(@intCast(device_bitmap_depth));
    return 1;
}

// ── [70] getScreenWidth() — sub_424F99 → sub_40222C ────────────────────────
fn getScreenWidth(vm: *Vm, args: bridge.ArgFrame) i16 {
    const w: i32 = if (vm.framebuffer) |fb| @intCast(fb.width) else 101;
    args.setReturnI32(w);
    return 1;
}

// ── [71] getScreenHeight() — sub_424FBF → sub_40223B ───────────────────────
fn getScreenHeight(vm: *Vm, args: bridge.ArgFrame) i16 {
    const h: i32 = if (vm.framebuffer) |fb| @intCast(fb.height) else 80;
    args.setReturnI32(h);
    return 1;
}

// ── [72] screenUpdate(this) ─────────────────────────────────────────────────
// Flush the gamelet's offscreen Image (handle at this.field 0x3dd39153)
// to the LCD framebuffer. Sub_424FF2 in ref.
fn screenUpdate(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const img_handle = _h.instField(vm, this, 0x3dd39153);
    if (img_handle == 0) return 0;
    const fb = vm.framebuffer orelse return 0;
    const img = vm.heap.get(img_handle) orelse return 0;
    const src = img.pixels orelse return 0;
    const w = @min(img.pix_w, fb.width);
    const h = @min(img.pix_h, fb.height);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const src_off = y * img.pix_w;
        const dst_off = y * fb.width;
        std.mem.copyForwards(u32, fb.pixels[dst_off .. dst_off + w], src[src_off .. src_off + w]);
    }
    return 0;
}

// ── [75] getTimerTickCount() — canonical sub_425090 ────────────────────────
// Canonical body: `*a1 = sub_406872(); return 1;`
// sub_406872 → sub_435D3F → `GetTickCount() - dword_50498C` where
// dword_50498C is captured by sub_43F5AA at simulator boot. Result is
// a monotonic ms count since **process start** — a small, positive value
// (high 32 bits zero for ~24 days).
//
// Two bugs fixed here, both observed in BanjoKazooie (whose gamelet stores
// this result into a 64-bit `long` static and does 64-bit delta arithmetic
// to pace enemy spawning):
//   1. We returned `milliTimestamp()` (ms since the Unix epoch, ~1.7e12) —
//      a huge value whose low word has the sign bit set. Canonical returns
//      ms since *boot* (starts at 0). Subtract a boot origin to match.
//   2. We wrote only the low word (`setReturn`), so when the gamelet read
//      the value as a `long` the high word was stale stack garbage
//      (e.g. 0x7ffc2045) — corrupting every elapsed-time computation.
//      Write both words via `setReturnLong`; the high word is 0 for a
//      boot-relative count, matching a clean positive long.
fn getTimerTickCount(vm: *Vm, args: bridge.ArgFrame) i16 {
    // Deterministic ms-since-boot from the VM clock (advanced by exen.tick(delta_ms)),
    // not wall-clock — so replay / rewind / save-states are reproducible. Low word
    // only, both words written (the gamelet reads it as a 64-bit long).
    args.setReturnLong(vm.clock_ms & 0xFFFF_FFFF);
    return 1;
}

// ── [76] startTimer(this, period_ms) — sub_4250A3 ───────────────────────────
fn startTimer(_: *Vm, args: bridge.ArgFrame) i16 {
    core.g_timer_period_ms = args.getU32(1);
    return 0;
}

// ── [73] Gamelet.exitVm() — sub_424FD2 ──────────────────────────────────────
// Canonical body (reference/ref near 24990):
//     sub_424FD2():
//       sub_406628();                          // stop active sound  (same as stopMelody)
//       sub_40777B();                          // reset audio device state
//       **(_DWORD **)(dword_45FF3C + 36) = 1;  // set device "exiting" flag
//       return 0;
//
// argc=0. Strings region row 41 `exitVm: () → void` matches by arg-type
// (argc=0) and return type (void). The only argc=0 → void candidate near
// the exit/throwInternalException cluster in the strings region.
//
// Note despite the name, Terminator calls this ONCE during boot as part
// of its bytecode init sequence (a GameletBase.<init> housekeeping
// routine resets the audio device + state flags). It's NOT a process-
// terminate — calling it during boot is intentional. Our impl mirrors
// canonical's observable behavior: stop audio + leave VM alive.
fn exitVm(vm: *Vm, _: bridge.ArgFrame) i16 {
    core.audio.stop();
    vm.exit_requested = true;
    return 0;
}

// ── [74] throwInternalException(code) — sub_42506C ──────────────────────────
// Canonical (ref:25037-25043):
//     sub_434771("Internal Exception");   // log trace
//     sub_406628();                       // stop audio melody
//     sub_407A13();                       // **set state=2 → tick aborts**
//     return 0;
//
// Critically `sub_407A13` is the canonical-NPE handler that halts the
// CURRENT tick (mirrors what an INVOKEVIRTUAL-on-null does). MutantAlert
// proactively calls this native when it detects bad gamelet state — if
// we just log and continue, the bytecode keeps running with the
// already-broken state, cascading into 1000+ subsequent NPE warnings
// and never re-entering a recoverable tick boundary.
//
// We mirror that here: set `internal_exception` halt reason (same code
// as null-receiver path), which `runFrame` propagates up to tick() →
// "Internal Exception (code=...) — resuming next tick" log → fresh
// next tick. Audio stop is deferred (no current audio pipeline).
fn throwInternalException(vm: *Vm, args: bridge.ArgFrame) i16 {
    const code = args.getI32(0);
    std.log.scoped(.interp).warn("Gamelet.throwInternalException code={d} — aborting tick (canonical sub_407A13)", .{code});
    vm.halted = true;
    vm.halt_reason = .{ .internal_exception = Vm.EX_NULL_POINTER };
    return 0;
}

// ── [77] stopTimer() — sub_4250BA ───────────────────────────────────────────
fn stopTimer(_: *Vm, _: bridge.ArgFrame) i16 {
    core.g_timer_period_ms = 0;
    return 0;
}

// ── [79] saveCtx(this, buf) — sub_425156 → sub_4153F8 ───────────────────────
// Writes the gamelet's save buffer (byte[] handle, length at fields[0])
// to the persisted EEPROM file. Up to 300 bytes (canonical cap).
// `this` is the gamelet instance (the call is virtual on the
// gamelet); the actual buffer is the explicit first arg.
//
// Canonical sub_425156 ALWAYS returns 0 (ref:25095) — not the
// bytes written. The byte count was previously returned, which caused
// Worms's state machine to take the wrong post-save path (interpreting
// the truthy return as an error-or-state-code that triggered a
// destroy-and-transition cascade mid-gameplay, nulling sprite statics).
fn saveCtx(vm: *Vm, args: bridge.ArgFrame) i16 {
    const buf_handle = args.handle(1);
    if (vm.heap.get(buf_handle)) |inst| {
        if (inst.bytes) |bytes| {
            const n = core.eepromSave(bytes);
            std.log.scoped(.interp).info("Gamelet.saveCtx wrote {d}/{d} bytes", .{ n, bytes.len });
        }
    }
    return 0; // canonical sub_425156 returns 0 unconditionally
}

// ── [80] loadCtx(this, buf) — sub_4251D4 → sub_41547B ───────────────────────
// Reads up to `buf.length` bytes (max 300) from the EEPROM file into
// the gamelet's buffer. If the EEPROM is empty / missing, the buffer
// is left as-is and the gamelet sees its default (typically zeros).
//
// Canonical sub_4251D4 also ALWAYS returns 0 (same shape as saveCtx).
fn loadCtx(vm: *Vm, args: bridge.ArgFrame) i16 {
    const buf_handle = args.handle(1);
    if (vm.heap.get(buf_handle)) |inst| {
        if (inst.bytes) |bytes| {
            const n = core.eepromLoad(bytes);
            // Mirror loaded bytes into the field-backed view so reads via
            // BALOAD/IALOAD see the same data.
            for (0..@min(n, inst.fields.len - 1)) |i| {
                inst.fields[1 + i] = bytes[i];
            }
            std.log.scoped(.interp).info("Gamelet.loadCtx read {d}/{d} bytes", .{ n, bytes.len });
        }
    }
    return 0; // canonical sub_4251D4 returns 0 unconditionally
}

// ── [81] playVibrator() — sub_4253BC ────────────────────────────────────────
// Canonical body (ref:25202):
//     if (*((BYTE*)dword_45FE8C + 350)) sub_4065E0(10); return 0;
// sub_4065E0(10) → sub_434189(1000) → records "vibrate 1000ms" in
// dword_4A20BC + emits the "ExManufVibrati..." debug string.
// argc=0; canonical hard-codes 1000ms. We forward to the registered
// haptic backend; the SDL frontend can hook it up to a controller
// rumble or platform haptic API. No-op when no backend is installed.
fn playVibrator(_: *Vm, _: bridge.ArgFrame) i16 {
    core.haptic.vibrate(1000);
    return 0;
}

// ── [82] playMelody(buf) — sub_425252 ───────────────────────────────────────
// Canonical body (ref:25141):
//   v2 = *(buf + 4);                              // byte[] handle
//   if (!v2) throw;
//   if (!*((BYTE*)dword_45FE8C + 348)) return 0;  // audio-enabled flag
//   if (sub_406601(v2 + 20, *(WORD*)(v2 + 18))    // MelodyPlay(bytes, len)
//         != 1) throw;
//   return 0;
//
// The byte[] is a flat the platform MIDI-ish event stream — pairs of
// `(opcode, param)` per docs/audio.md, fed to `midiOutShortMsg` via
// `sub_43B192`'s timer-driven scheduler. We delegate to whatever
// audio backend the frontend registered (SDL3 currently); no-op if
// none, so headless / test builds still pass through.
var g_active_melody: Handle = 0;

fn playMelody(vm: *Vm, args: bridge.ArgFrame) i16 {
    const buf = args.handle(1);
    if (buf == 0) return 0;
    const inst = vm.heap.get(buf) orelse return 0;
    const bytes = inst.bytes orelse return 0;
    g_active_melody = buf;
    core.audio.play(bytes);
    return 0;
}

// ── [83] stopMelody() — sub_4252DF ──────────────────────────────────────────
fn stopMelody(_: *Vm, _: bridge.ArgFrame) i16 {
    if (g_active_melody != 0) {
        g_active_melody = 0;
        core.audio.stop();
    }
    return 0;
}

// ── [84] Gamelet.getNickName() → char[] — sub_4252EC ────────────────────────
// Canonical body (reference/ref:25169):
//
//   char Src[20];
//   sub_423B63(Src);                            // memcpy 16B from dword_45FE8C+102
//                                                // (the simulator's user-nickname slot)
//   v5 = sub_422F34(Src);                        // strlen-like length
//   v3 = sub_40FEF8("exen.Gamelet", 12);         // class-name hash (unused here)
//   v4 = sub_410106(v5, 0x150, v3);              // allocate char[] of length v5,
//                                                //   type tag 0x0150 = char[]
//   memcpy(v4 + 20, Src, v5);                    // copy bytes into payload
//   *a1 = v4;                                    // return new char[] handle
//   return 1;
//
// Returns a freshly-allocated char[] containing the current user nickname.
// The simulator stores it at `dword_45FE8C+102` (16-byte fixed slot),
// initialised by `sub_402A20` (profile-init, called during boot) to the
// hardcoded default `"Xcell"` (5 chars + null terminator at +107).
// See reference/ref:5350-5351 for the canonical write.
//
// We mirror that exact canonical default. A future host-side
// "configurable nickname" feature can swap the const out for a value
// from `simulator.ini` or a CLI flag.
const CHAR_ARRAY_CLASS_HASH: u32 = 0x5DA4D0C7; // canonical char[] runtime class
const NICKNAME_DEFAULT: []const u8 = "Xcell"; // matches reference/ref:5350

fn getNickName(vm: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturn(0);
    const h = vm.heap.alloc(CHAR_ARRAY_CLASS_HASH) catch return 1;
    args.setReturn(h);
    const inst = vm.heap.get(h) orelse return 1;
    const buf = vm.allocator.alloc(u8, NICKNAME_DEFAULT.len) catch return 1;
    @memcpy(buf, NICKNAME_DEFAULT);
    inst.bytes = buf;
    inst.fields[0] = @intCast(buf.len);
    return 1;
}

// ── [87] Gamelet.getVersionInfo(String name) → String — sub_425427 ──────────
// Canonical body (reference/ref:25232):
//   if (arg[0] == 0) abort/halt; *a1 = 0; return null
//   v2 = arg.char[];   // length-prefixed char buffer
//   for (i = 0; i < 2; i += 2) {                   // scan ["FrameWork", "V2.00"]
//     if (strlen(off_4492CC[i]) == v2.length AND chars match) break;
//   }
//   if (no match) { *a1 = 0; return null; }
//   Srca = (&off_4492D0)[i];                       // parallel-array lookup
//   allocate new String + char[]; copy Srca into it; return.
//
// Property lookup. The canonical literal `off_4492CC[2] = { "FrameWork",
// "V2.00" }` (ref:1508). Calling getVersionInfo("FrameWork") returns
// a new String containing the version literal (off_4492D0 = "V2.00").
// Calling with any other key returns null.
//
// Strings region row for `getVersionInfo` is present in our positional
// native_names; matching arg/return shape (1 String → String) + canonical
// behavior (key-based lookup against a 2-entry table returning a value
// String) confirms this is `getVersionInfo`.
const FRAMEWORK_KEY: []const u8 = "FrameWork";
const FRAMEWORK_VERSION: []const u8 = "V2.00";
const STRING_CLASS_HASH: u32 = 0x7772dde3;

fn getVersionInfo(vm: *Vm, args: bridge.ArgFrame) i16 {
    const key = args.handle(1);
    args.setReturn(0);
    if (key == 0) return 1;
    const key_inst = vm.heap.get(key) orelse return 1;
    const key_bytes = key_inst.bytes orelse return 1;
    if (!std.mem.eql(u8, key_bytes, FRAMEWORK_KEY)) return 1;
    const h = vm.heap.alloc(STRING_CLASS_HASH) catch return 1;
    args.setReturn(h);
    const inst = vm.heap.get(h) orelse return 1;
    const buf = vm.allocator.alloc(u8, FRAMEWORK_VERSION.len) catch return 1;
    @memcpy(buf, FRAMEWORK_VERSION);
    inst.bytes = buf;
    inst.fields[0] = @intCast(buf.len);
    return 1;
}

pub const handle = bridge.canonical(.{
    .{ 67, "isColor",                 isColor },
    .{ 68, "numColors",               numColors },
    .{ 69, "getBitmapDepth",          getBitmapDepth },
    .{ 70, "getScreenWidth",          getScreenWidth },
    .{ 71, "getScreenHeight",         getScreenHeight },
    .{ 72, "screenUpdate",            screenUpdate },
    .{ 73, "exitVm",                  exitVm },
    .{ 74, "throwInternalException",  throwInternalException },
    .{ 75, "getTimerTickCount",       getTimerTickCount },
    .{ 76, "startTimer",              startTimer },
    .{ 77, "stopTimer",               stopTimer },
    .{ 79, "saveCtx",                 saveCtx },
    .{ 80, "loadCtx",                 loadCtx },
    .{ 81, "playVibrator",            playVibrator },
    .{ 82, "playMelody",              playMelody },
    .{ 83, "stopMelody",              stopMelody },
    .{ 84, "Gamelet.getNickName",     getNickName },
    .{ 87, "Gamelet.getVersionInfo",  getVersionInfo },
});

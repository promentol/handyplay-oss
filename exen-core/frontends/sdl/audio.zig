//! SDL3 audio backend for `core.audio`. Registers C-callable
//! `play(data,len)` / `stop()` callbacks during frontend boot.
//!
//! Generates audio with a single-voice square-wave tone generator
//! fed into an `SDL_AudioStream`. This is "option 1" from
//! `docs/audio.md` — passable chiptune for gameplay, no MIDI synth
//! dependency, no SoundFont required.
//!
//! Stream format & event mapping
//! -----------------------------
//! The gamelet hands us a `byte[]` of `(opcode, param)` pairs (see
//! `docs/audio.md` and the canonical `sub_43B192` scheduler). We
//! interpret the high bit of the opcode as `note_on` / silence and
//! treat `param` as a per-event tick count (1 tick = TICK_MS ms).
//! Opcode bits 0..6 select the MIDI note number; we map that to a
//! frequency with the standard `440 * 2^((n-69)/12)` formula.
//!
//! This isn't byte-faithful to the platform's exact mapping (we haven't
//! traced sub_43B192's event decode in detail) but it produces audible,
//! pitch-correct output for the simple melodies gamelets emit (menu
//! beeps, jingles). When we trace the exact decode, only the
//! `pushEvent` parsing below needs to change.

const std = @import("std");

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "");
    @cInclude("SDL3/SDL.h");
});

const SAMPLE_RATE: u32 = 22050;
const VOLUME: f32 = 0.20;

// Duration table from `TimerFunc` (`ref:35849`, the local `v9[16]`).
// `param % 14` indexes this; values are tempo-units, multiplied by
// `1875 / tempo` ms per unit. With the default tempo (~120 BPM region
// in the canonical `dword_45CAAC`), 1 unit ≈ 15 ms — so the table
// covers durations from 30 ms up to ~2880 ms (a long whole note).
const DURATION_TABLE = [_]u8{ 192, 128, 96, 64, 48, 32, 24, 16, 12, 8, 6, 4, 3, 2 };

// Tempo unit in ms. Canonical computes `1875 / dword_45CAAC` from
// device profile; with typical values it lands around 15 ms. We use
// a fixed 15 ms — close enough for chiptune fidelity.
const TEMPO_UNIT_MS: u32 = 15;

// Active SDL audio device + stream. Created lazily on the first
// `play()` call so headless test runs don't open an audio device.
var g_device: c.SDL_AudioDeviceID = 0;
var g_stream: ?*c.SDL_AudioStream = null;

// Square-wave generator state.
var g_phase: f32 = 0;

fn ensureStream() bool {
    if (g_stream != null) return true;
    if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
        std.debug.print("[audio] SDL_InitSubSystem(AUDIO) failed: {s}\n", .{c.SDL_GetError()});
        return false;
    }
    const spec: c.SDL_AudioSpec = .{
        .format = c.SDL_AUDIO_F32,
        .channels = 1,
        .freq = @intCast(SAMPLE_RATE),
    };
    g_stream = c.SDL_OpenAudioDeviceStream(
        c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
        &spec,
        null,
        null,
    );
    if (g_stream == null) {
        std.debug.print("[audio] SDL_OpenAudioDeviceStream failed: {s}\n", .{c.SDL_GetError()});
        return false;
    }
    g_device = c.SDL_GetAudioStreamDevice(g_stream);
    _ = c.SDL_ResumeAudioStreamDevice(g_stream);
    return true;
}

/// Render `duration_ms` of square wave at `freq_hz` (or silence if
/// `freq_hz == 0`) into the active stream.
fn queueTone(freq_hz: f32, duration_ms: u32) void {
    const stream = g_stream orelse return;
    const total_samples: u32 = (SAMPLE_RATE * duration_ms) / 1000;
    if (total_samples == 0) return;

    // 4096-sample chunk buffer — keeps SDL_PutAudioStreamData calls
    // bounded so we don't allocate huge stack frames per event.
    var chunk: [4096]f32 = undefined;
    var remaining = total_samples;
    const phase_step: f32 = if (freq_hz > 0)
        freq_hz / @as(f32, @floatFromInt(SAMPLE_RATE))
    else
        0;

    while (remaining > 0) {
        const n: u32 = @min(remaining, chunk.len);
        if (freq_hz <= 0) {
            // Silence
            for (chunk[0..n]) |*s| s.* = 0;
        } else {
            for (chunk[0..n]) |*s| {
                g_phase += phase_step;
                if (g_phase >= 1.0) g_phase -= 1.0;
                // Square wave: +V for first half-cycle, -V for the rest.
                s.* = if (g_phase < 0.5) VOLUME else -VOLUME;
            }
        }
        const bytes_n: c_int = @intCast(n * @sizeOf(f32));
        _ = c.SDL_PutAudioStreamData(stream, &chunk, bytes_n);
        remaining -= n;
    }
}

/// MIDI note number → Hz. 440 Hz at note 69 (A4); octave per 12 notes.
fn noteFreq(note: u8) f32 {
    const semitones: f32 = @as(f32, @floatFromInt(note)) - 69.0;
    return 440.0 * std.math.pow(f32, 2.0, semitones / 12.0);
}

/// `play(data, len)` callback — called by Gamelet.playMelody via
/// `core.audio.backend.play_fn`. Parses the `(opcode, param)` stream
/// per the canonical `TimerFunc` decode (`ref:35849`) and
/// queues tones into the SDL audio stream.
///
/// Per-pair semantics:
///   opcode ∈ [0..127]   → MIDI note number; play for
///                          `DURATION_TABLE[param % 14] * TEMPO_UNIT_MS`.
///                          opcode == 0 ends the melody (rest of
///                          the stream is ignored — matches
///                          canonical's `if (length > 2) stop()`).
///   opcode == 128       → set channel (param & 0xF). We're mono, ignored.
///   opcode == 129       → patch change (drum kit if param==0). Ignored
///                          for square-wave; would matter with a real synth.
///   opcode == 130       → duration override for next note. Stored as
///                          a "carry" applied to the next note event.
///   opcode == 131       → tempo change. param sets `1875 / tempo`.
///                          Recompute TEMPO_UNIT_MS for subsequent notes.
///   opcode == 132       → set volume (canonical sub_43AC4E). Ignored —
///                          we run at fixed VOLUME.
///   opcode == 133       → master volume adjust. Ignored.
fn playCallback(data_ptr: [*]const u8, len: usize) callconv(.c) void {
    if (!ensureStream()) return;
    if (g_stream) |s| _ = c.SDL_ClearAudioStream(s);
    g_phase = 0;

    const data = data_ptr[0..len];
    var i: usize = 0;
    // Scale the canonical tempo unit by the same factor the host
    // loop uses to speed up visual ticks. Both sites read
    // `exen.TICK_PERIOD_CEIL_MS`, so audio and visuals stay locked
    // to the same game-clock speedup. For Crash/Terminator (typical
    // 150 ms tick request) and the current 75 ms ceiling, that's a
    // 2× speedup — audio plays at twice canonical tempo to match
    // the 2×-faster visuals.
    const core = @import("core");
    const requested = core.g_timer_period_ms;
    const ceil = core.TICK_PERIOD_CEIL_MS;
    const actual: u32 = if (requested == 0) ceil else @min(requested, ceil);
    const speedup: u32 = if (actual > 0) @max(requested / actual, 1) else 1;
    var tempo_unit_ms: u32 = @max(TEMPO_UNIT_MS / speedup, 1);
    var pending_duration_override: u32 = 0;

    while (i + 1 < data.len) : (i += 2) {
        const opcode = data[i];
        const param = data[i + 1];

        if (opcode <= 0x7F) {
            // 0 = end-of-melody when the stream is non-trivial.
            if (opcode == 0 and data.len > 2) break;
            if (opcode == 0) continue;

            const ticks: u32 = if (pending_duration_override != 0) blk: {
                const t = pending_duration_override;
                pending_duration_override = 0;
                break :blk t;
            } else DURATION_TABLE[param % DURATION_TABLE.len];
            const duration_ms: u32 = ticks * tempo_unit_ms;
            queueTone(noteFreq(opcode), duration_ms);
            continue;
        }

        // Special opcodes (>= 128). Most are state changes that don't
        // produce audio directly.
        switch (opcode) {
            128, 129 => {}, // channel / patch change — no-op for square wave
            130 => pending_duration_override = DURATION_TABLE[param % DURATION_TABLE.len],
            131 => {
                if (param != 0) tempo_unit_ms = 1875 / @as(u32, param);
            },
            132, 133 => {}, // volume change — fixed in our synth
            else => {}, // unknown opcode, skip
        }
    }
}

/// `stop()` callback — drops everything pending.
fn stopCallback() callconv(.c) void {
    if (g_stream) |s| _ = c.SDL_ClearAudioStream(s);
    g_phase = 0;
}

/// Install the callbacks on `core.audio.backend`. Frontend calls this
/// after `exen.boot()` returns.
pub fn register() void {
    const audio = @import("core").audio;
    audio.backend.play_fn = playCallback;
    audio.backend.stop_fn = stopCallback;
}

/// Tear down. Frontend calls on shutdown.
pub fn deinit() void {
    if (g_stream) |s| {
        c.SDL_DestroyAudioStream(s);
        g_stream = null;
    }
    g_device = 0;
    c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
}

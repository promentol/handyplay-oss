//! Core-owned audio engine: MIDI (TinySoundFont + gm.sf2), WAV/PCM clips,
//! duration-only fake voices (AMR/MP3), and the vm_bitstream_audio_* PCM ring.
//!
//! The core renders/mixes everything to interleaved s16 stereo @ 44100 Hz; the
//! frontends are pure PCM sinks that call `render()` (SDL pushes into an
//! SDL_AudioStream, libretro feeds its audio batch callback). Headless runs
//! keep time moving via `tickFallback`. Guest completion callbacks
//! `void (*)(handle, event)` are queued here and drained by `Vm.tick` through
//! `runCpu` — never fired from inside a native call or the mixer.
//!
//! Single-threaded by design: natives, render and drain all run on the emu
//! thread. Semantics follow the reference emulator (MREmu/MREngine/Audio.cpp,
//! AudioBitstream.cpp); the synth differs (SoundFont wavetable vs OPL3 FM).
//! Handles are 1-based — games test `handle > 0` (e.g. Doodle Jump).
//!
//! On wasm32-emscripten the synth C code isn't compiled/linked, so MIDI voices
//! degrade to silent clock-based fakes (valid handles, timed completion);
//! everything else (WAV mixer, bitstream, events) is pure Zig and works.
const std = @import("std");
const builtin = @import("builtin");
const tsf = @import("tsf.zig");
const wav_codec = @import("codecs/wav.zig");
const vm_mod = @import("vm.zig");

pub const SAMPLE_RATE: u32 = 44100;
/// Completion callback event value; verified from decompiled games (Doodle
/// Jump's MIDI and SFX callbacks both test `event == 5`).
pub const EVENT_END_OF_PLAY: u32 = 5;
/// The SF2 synth is only compiled/linked for native targets (see build.zig);
/// the wasm player build (zig build-obj + emcc) never sees tsf_*/tml_* symbols.
pub const synth_enabled = builtin.target.os.tag != .emscripten;

const gpa = std.heap.c_allocator;

pub var volume: u8 = 4; // global 0..6, MRE convention (vm_set_volume)
/// A frontend sink sets this; otherwise Vm.tick renders-to-discard so voice
/// time and completion events still advance (headless tools, tests).
pub var rendered_by_frontend: bool = false;

fn logEnabled() bool {
    return std.posix.getenv("AUDIO_LOG") != null;
}

// --- completion-callback queue ----------------------------------------------

const Event = struct { cb: u32, handle: i32 };
var event_q: [32]Event = undefined;
var event_n: usize = 0;

fn queueEvent(cb: u32, handle: i32) void {
    if (cb == 0 or event_n >= event_q.len) return;
    event_q[event_n] = .{ .cb = cb, .handle = handle };
    event_n += 1;
}

/// Fire queued completion callbacks into the guest. Called from Vm.tick.
/// Only events queued before this call are fired (callbacks may play new
/// clips and queue more — those wait for the next tick).
pub fn drainEvents(vm: *vm_mod.Vm) void {
    const n = event_n;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = event_q[i];
        if (logEnabled())
            std.debug.print("[audio] cb 0x{x:0>8}(handle={d}, event={d})\n", .{ e.cb, e.handle, EVENT_END_OF_PLAY });
        _ = vm.runCpu(e.cb, &.{ @bitCast(e.handle), EVENT_END_OF_PLAY });
    }
    // compact anything queued during the callbacks
    std.mem.copyForwards(Event, event_q[0 .. event_n - n], event_q[n..event_n]);
    event_n -= n;
}

// --- MIDI sequencing (shared by vm_midi_* voices and MThd clips) -------------

var master_synth: ?*tsf.Tsf = null; // lazy-loaded gm.sf2; voices get tsf_copy clones

fn masterSynth() ?*tsf.Tsf {
    if (comptime !synth_enabled) return null;
    if (master_synth == null) {
        const sf2 = @embedFile("assets/gm.sf2");
        master_synth = tsf.tsf_load_memory(sf2.ptr, @intCast(sf2.len));
        if (master_synth == null) std.debug.print("[audio] gm.sf2 load FAILED\n", .{});
    }
    return master_synth;
}

const RELEASE_TAIL_MS: u32 = 250; // let the last notes ring before completing

const MidiState = struct {
    synth: ?*tsf.Tsf = null, // per-voice tsf_copy (shares master samples)
    messages: ?*tsf.TmlMessage = null, // owned tml list (null on wasm: fake mode)
    cursor: ?*tsf.TmlMessage = null,
    playhead_ms: f64 = 0,
    duration_ms: u32 = 0,
    loops_left: i32 = 1,
    done: bool = false,

    /// Parse + prime. Returns false if the data is not a playable SMF.
    fn load(self: *MidiState, data: []const u8, start_ms: u32, repeat: i32) bool {
        // MREmu: repeat==0 means "forever" (999)
        self.loops_left = if (repeat == 0) 999 else repeat;
        self.playhead_ms = 0;
        self.done = false;
        if (comptime synth_enabled) {
            const master = masterSynth() orelse return false;
            self.messages = tsf.tml_load_memory(data.ptr, @intCast(data.len)) orelse return false;
            var length_ms: c_uint = 0;
            _ = tsf.tml_get_info(self.messages.?, null, null, null, null, &length_ms);
            self.duration_ms = length_ms;
            self.synth = tsf.tsf_copy(master) orelse {
                tsf.tml_free(self.messages);
                self.messages = null;
                return false;
            };
            tsf.tsf_set_output(self.synth.?, tsf.STEREO_INTERLEAVED, @intCast(SAMPLE_RATE), 0);
            self.cursor = self.messages;
            if (start_ms > 0) self.seek(start_ms);
        } else {
            // wasm fake voice: no synth; keep handles/completion timing sane.
            self.duration_ms = 60_000;
        }
        return true;
    }

    /// Fast-forward: apply program/control/pitch state, skip note-ons.
    fn seek(self: *MidiState, target_ms: u32) void {
        self.playhead_ms = @floatFromInt(target_ms);
        if (comptime synth_enabled) {
            while (self.cursor) |m| {
                if (m.time >= target_ms) break;
                switch (m.type) {
                    tsf.TML_PROGRAM_CHANGE, tsf.TML_CONTROL_CHANGE, tsf.TML_PITCH_BEND => self.dispatch(m),
                    else => {},
                }
                self.cursor = m.next;
            }
        }
    }

    fn dispatch(self: *MidiState, m: *tsf.TmlMessage) void {
        const f = self.synth orelse return;
        const ch: c_int = m.channel;
        switch (m.type) {
            tsf.TML_PROGRAM_CHANGE => _ = tsf.tsf_channel_set_presetnumber(f, ch, m.param.kv.a, @intFromBool(m.channel == 9)),
            tsf.TML_NOTE_ON => {
                if (m.param.kv.b == 0)
                    tsf.tsf_channel_note_off(f, ch, m.param.kv.a)
                else
                    _ = tsf.tsf_channel_note_on(f, ch, m.param.kv.a, @as(f32, @floatFromInt(m.param.kv.b)) / 127.0);
            },
            tsf.TML_NOTE_OFF => tsf.tsf_channel_note_off(f, ch, m.param.kv.a),
            tsf.TML_CONTROL_CHANGE => _ = tsf.tsf_channel_midi_control(f, ch, m.param.kv.a, m.param.kv.b),
            tsf.TML_PITCH_BEND => _ = tsf.tsf_channel_set_pitchwheel(f, ch, m.param.pitch_bend),
            else => {},
        }
    }

    /// Advance `frames` and mix into `acc` (interleaved stereo i32).
    /// Sets `done` when the last loop (incl. release tail) has played out.
    fn mix(self: *MidiState, acc: []i32, frames: usize) void {
        const ms_per_frame = 1000.0 / @as(f64, @floatFromInt(SAMPLE_RATE));
        if (comptime synth_enabled) {
            var scratch: [MIX_BLOCK * 2]i16 = undefined;
            var pos: usize = 0;
            while (pos < frames) {
                const n: usize = @min(frames - pos, MIX_BLOCK);
                self.playhead_ms += ms_per_frame * @as(f64, @floatFromInt(n));
                while (self.cursor) |m| {
                    if (@as(f64, @floatFromInt(m.time)) > self.playhead_ms) break;
                    self.dispatch(m);
                    self.cursor = m.next;
                }
                tsf.tsf_render_short(self.synth.?, &scratch, @intCast(n), 0);
                for (0..n * 2) |i| acc[(pos * 2) + i] += scratch[i];
                pos += n;
                self.checkEnd();
                if (self.done) break;
            }
        } else {
            self.playhead_ms += ms_per_frame * @as(f64, @floatFromInt(frames));
            self.checkEnd();
        }
    }

    fn checkEnd(self: *MidiState) void {
        if (self.cursor != null) return;
        if (self.playhead_ms < @as(f64, @floatFromInt(self.duration_ms + RELEASE_TAIL_MS))) return;
        self.loops_left -= 1;
        if (self.loops_left > 0) {
            if (comptime synth_enabled) {
                if (self.synth) |f| tsf.tsf_note_off_all(f);
                self.cursor = self.messages;
            }
            self.playhead_ms = 0;
        } else {
            self.done = true;
        }
    }

    fn deinit(self: *MidiState) void {
        if (comptime synth_enabled) {
            if (self.synth) |f| tsf.tsf_close(f);
            if (self.messages != null) tsf.tml_free(self.messages);
        }
        self.* = .{};
    }
};

// --- voice tables -------------------------------------------------------------

const MIX_BLOCK = 64; // frames per inner mixing block (tsf example uses 64)

const MidiVoice = struct {
    active: bool = false,
    playing: bool = false, // false = paused
    bg_suspended: bool = false,
    src_ptr: u32 = 0, // guest data pointer, for MREmu's same-source-reuse rule
    cb: u32 = 0,
    state: MidiState = .{},
};

const ClipKind = enum { midi, wav, fake };

const WavState = struct {
    pcm: []u8 = &.{}, // owned copy of the 'data' chunk
    bits: u8 = 16,
    channels: u8 = 1,
    rate: u32 = 8000,
    pos_fp: u64 = 0, // 16.16 frame position
    step_fp: u64 = 0,
    frames: usize = 0,

    fn sampleAt(self: *const WavState, frame: usize, ch: usize) i32 {
        const c = @min(ch, self.channels - 1);
        if (self.bits == 16) {
            const idx = (frame * self.channels + c) * 2;
            return std.mem.readInt(i16, self.pcm[idx..][0..2], .little);
        }
        const v: i32 = self.pcm[frame * self.channels + c];
        return (v - 128) << 8;
    }
};

const ClipVoice = struct {
    active: bool = false,
    playing: bool = false,
    bg_suspended: bool = false,
    cb: u32 = 0,
    repeat_left: i32 = 1,
    kind: ClipKind = .fake,
    midi: MidiState = .{},
    wav: WavState = .{},
    // fake (AMR/MP3/unknown): silent, duration-faithful
    fake_playhead_ms: f64 = 0,
    fake_duration_ms: u32 = 0,
};

const BitstreamVoice = struct {
    active: bool = false,
    started: bool = false,
    bg_suspended: bool = false,
    data_finished: bool = false, // guest said "no more put_data"
    end_reported: bool = false,
    stereo: bool = false,
    rate: u32 = 8000,
    gain_num: u8 = 4, // volume 0..6 (per-voice, from _start)
    cb: u32 = 0,
    ring: [RING_BYTES]u8 = undefined,
    head: usize = 0, // read index (bytes)
    len: usize = 0, // filled bytes
    frac_fp: u64 = 0, // 16.16 fractional source-frame accumulator
    played_frames: u64 = 0, // source frames consumed (for get_play_time)
};

/// MREmu: bitstream_buf_size = 10*1024 (we account in bytes; only Gold Miner
/// consumes the reported units — AUDIO_LOG instrumentation will confirm).
const RING_BYTES = 10 * 1024;
pub const BITSTREAM_RATES = [8]u32{ 8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000 };

var midi_voices: [8]MidiVoice = @splat(.{});
var clip_voices: [8]ClipVoice = @splat(.{});
var bs_voices: [4]BitstreamVoice = @splat(.{});

fn midiAt(h: i32) ?*MidiVoice {
    if (h < 1 or h > @as(i32, midi_voices.len)) return null;
    const v = &midi_voices[@intCast(h - 1)];
    return if (v.active) v else null;
}
fn clipAt(h: i32) ?*ClipVoice {
    if (h < 1 or h > @as(i32, clip_voices.len)) return null;
    const v = &clip_voices[@intCast(h - 1)];
    return if (v.active) v else null;
}
fn bsAt(h: i32) ?*BitstreamVoice {
    if (h < 1 or h > @as(i32, bs_voices.len)) return null;
    const v = &bs_voices[@intCast(h - 1)];
    return if (v.active) v else null;
}

// --- MIDI API (vm_midi_*) ------------------------------------------------------

/// MREmu vm_midi_play_by_bytes_ex semantics: same guest source -> stop the old
/// voice and reuse its slot; playing a new MIDI pauses all other MIDI voices.
pub fn midiPlay(data: []const u8, src_ptr: u32, start_ms: u32, repeat: i32, cb: u32) i32 {
    var slot: ?usize = null;
    for (&midi_voices, 0..) |*v, i| {
        if (v.active and v.src_ptr == src_ptr) {
            v.state.deinit();
            v.* = .{};
            slot = i;
            break;
        }
    }
    if (slot == null) for (&midi_voices, 0..) |*v, i| {
        if (!v.active) {
            slot = i;
            break;
        }
    };
    const i = slot orelse return -1;
    const v = &midi_voices[i];
    if (!v.state.load(data, start_ms, repeat)) {
        if (logEnabled()) std.debug.print("[audio] midiPlay: not a playable SMF (len={d})\n", .{data.len});
        return -1;
    }
    // pause every other midi voice (MREmu behavior)
    for (&midi_voices, 0..) |*o, j| {
        if (j != i and o.active) o.playing = false;
    }
    v.active = true;
    v.playing = true;
    v.bg_suspended = false;
    v.src_ptr = src_ptr;
    v.cb = cb;
    return @intCast(i + 1);
}

pub fn midiPause(h: i32) i32 {
    const v = midiAt(h) orelse return -1;
    v.playing = false;
    return 0;
}
pub fn midiResume(h: i32) i32 {
    const v = midiAt(h) orelse return -1;
    v.playing = true;
    v.bg_suspended = false;
    return 0;
}
pub fn midiGetTimeMs(h: i32) ?u32 {
    const v = midiAt(h) orelse return null;
    return @intFromFloat(@max(0, v.state.playhead_ms));
}
pub fn midiStop(h: i32) void {
    const v = midiAt(h) orelse return;
    v.state.deinit();
    v.* = .{};
}
pub fn midiStopAll() void {
    for (&midi_voices) |*v| if (v.active) {
        v.state.deinit();
        v.* = .{};
    };
}

// --- clip API (vm_audio_*) -----------------------------------------------------

const AMR_HEADER = "#!AMR\n";
// AMR-NB frame payload sizes by frame type (bits 3..6 of the header byte).
const AMR_FRAME_SIZES = [16]u8{ 12, 13, 15, 17, 19, 20, 26, 31, 5, 0, 0, 0, 0, 0, 0, 0 };

fn amrDurationMs(data: []const u8) u32 {
    if (data.len < AMR_HEADER.len) return 0;
    var pos: usize = AMR_HEADER.len;
    var frames: u32 = 0;
    while (pos < data.len) {
        const ft: usize = (data[pos] >> 3) & 0xF;
        pos += 1 + AMR_FRAME_SIZES[ft];
        frames += 1;
        if (AMR_FRAME_SIZES[ft] == 0 and ft >= 9) break; // corrupt/end
    }
    return frames * 20; // 20 ms per AMR frame
}

/// minimp3 shim (core/mp3_impl.c); native targets only, like the tsf synth.
extern fn mre_mp3_decode(
    buf: [*]const u8,
    len: usize,
    out_pcm: *?[*]i16,
    out_samples: *usize,
    out_channels: *c_int,
    out_hz: *c_int,
) c_int;

fn looksLikeMp3(data: []const u8) bool {
    if (data.len < 3) return false;
    return std.mem.eql(u8, data[0..3], "ID3") or
        (data[0] == 0xFF and (data[1] & 0xE0) == 0xE0);
}

const MP3_BITRATES = [16]u32{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 }; // MPEG1 L3, kbps

fn mp3DurationMs(data: []const u8) u32 {
    var pos: usize = 0;
    if (data.len > 10 and std.mem.eql(u8, data[0..3], "ID3")) {
        const sz: usize = (@as(usize, data[6]) << 21) | (@as(usize, data[7]) << 14) |
            (@as(usize, data[8]) << 7) | data[9];
        pos = 10 + sz;
    }
    if (pos + 4 > data.len) return 5000;
    if (data[pos] != 0xFF or (data[pos + 1] & 0xE0) != 0xE0) return 5000;
    const kbps = MP3_BITRATES[(data[pos + 2] >> 4) & 0xF];
    if (kbps == 0) return 5000;
    return @intCast((data.len - pos) * 8 / kbps); // bytes*8 / (kbit/s) = ms
}

pub fn clipDurationMs(data: []const u8, format: u8) i32 {
    _ = format; // the format byte is unreliable across titles; sniff magic instead
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "MThd")) {
        if (comptime synth_enabled) {
            const msgs = tsf.tml_load_memory(data.ptr, @intCast(data.len)) orelse return -1;
            defer tsf.tml_free(msgs);
            var length_ms: c_uint = 0;
            _ = tsf.tml_get_info(msgs, null, null, null, null, &length_ms);
            return @intCast(length_ms);
        }
        return 60_000;
    }
    if (wav_codec.parse(data)) |w| return @intCast(w.durationMs());
    if (data.len >= AMR_HEADER.len and std.mem.eql(u8, data[0..AMR_HEADER.len], AMR_HEADER))
        return @intCast(amrDurationMs(data));
    if (data.len >= 3 and (std.mem.eql(u8, data[0..3], "ID3") or (data[0] == 0xFF and (data[1] & 0xE0) == 0xE0)))
        return @intCast(mp3DurationMs(data));
    return -1;
}

pub fn clipPlay(data: []const u8, format: u8, repeat: i32, cb: u32) i32 {
    var slot: ?usize = null;
    for (&clip_voices, 0..) |*v, i| {
        if (!v.active) {
            slot = i;
            break;
        }
    }
    const i = slot orelse return -1;
    const v = &clip_voices[i];
    v.* = .{};
    v.repeat_left = if (repeat == 0) 999 else repeat;
    v.cb = cb;

    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "MThd")) {
        if (!v.midi.load(data, 0, v.repeat_left)) return -1;
        v.kind = .midi;
    } else if (wav_codec.parse(data)) |w| {
        const copy = gpa.dupe(u8, w.data) catch return -1;
        v.kind = .wav;
        v.wav = .{
            .pcm = copy,
            .bits = w.bits,
            .channels = w.channels,
            .rate = w.sample_rate,
            .step_fp = (@as(u64, w.sample_rate) << 16) / SAMPLE_RATE,
            .frames = w.frameCount(),
        };
    } else if (comptime synth_enabled) blk: {
        // MP3 (e.g. AC Unity music, format 5): decode whole clip via minimp3
        // into a PCM voice; anything else (AMR, unknown) falls to a fake voice.
        if (looksLikeMp3(data)) {
            var pcm: ?[*]i16 = null;
            var samples: usize = 0;
            var channels: c_int = 0;
            var hz: c_int = 0;
            if (mre_mp3_decode(data.ptr, data.len, &pcm, &samples, &channels, &hz) == 0) {
                const ch: u8 = if (channels >= 2) 2 else 1;
                const rate: u32 = @intCast(hz);
                v.kind = .wav;
                v.wav = .{
                    .pcm = @as([*]u8, @ptrCast(pcm.?))[0 .. samples * 2],
                    .bits = 16,
                    .channels = ch,
                    .rate = rate,
                    .step_fp = (@as(u64, rate) << 16) / SAMPLE_RATE,
                    .frames = samples / ch,
                };
                if (logEnabled())
                    std.debug.print("[audio] mp3 decoded: {d} samples {d}ch {d}Hz\n", .{ samples, ch, rate });
                break :blk;
            }
        }
        makeFakeVoice(v, data, format);
    } else {
        makeFakeVoice(v, data, format);
    }
    v.active = true;
    v.playing = true;
    return @intCast(i + 1);
}

/// AMR / undecodable clip: silent voice with a faithful duration so handle +
/// completion-event logic behaves (real AMR decode = future work).
fn makeFakeVoice(v: *ClipVoice, data: []const u8, format: u8) void {
    v.kind = .fake;
    const d = clipDurationMs(data, format);
    v.fake_duration_ms = if (d > 0) @intCast(d) else 1000;
    if (logEnabled())
        std.debug.print("[audio] clipPlay fake voice fmt={d} dur={d}ms magic={x:0>2} {x:0>2} {x:0>2} {x:0>2}\n", .{ format, v.fake_duration_ms, data[0], if (data.len > 1) data[1] else 0, if (data.len > 2) data[2] else 0, if (data.len > 3) data[3] else 0 });
}

pub fn clipGetTimeMs(h: i32) ?u32 {
    const v = clipAt(h) orelse return null;
    return switch (v.kind) {
        .midi => @intFromFloat(@max(0, v.midi.playhead_ms)),
        .wav => if (v.wav.rate == 0) 0 else @intCast(((v.wav.pos_fp >> 16) * 1000) / v.wav.rate),
        .fake => @intFromFloat(@max(0, v.fake_playhead_ms)),
    };
}
pub fn clipStop(h: i32) i32 {
    const v = clipAt(h) orelse return -1;
    freeClip(v);
    return 0;
}
pub fn clipPause(h: i32) i32 {
    const v = clipAt(h) orelse return -1;
    v.playing = false;
    return 0;
}
pub fn clipResume(h: i32) i32 {
    const v = clipAt(h) orelse return -1;
    v.playing = true;
    v.bg_suspended = false;
    return 0;
}
pub fn clipClose(h: i32) void {
    const v = clipAt(h) orelse return;
    freeClip(v);
}
pub fn clipStopAll() void {
    for (&clip_voices) |*v| if (v.active) freeClip(v);
}
pub fn clipCloseAll() void {
    clipStopAll();
}

fn freeClip(v: *ClipVoice) void {
    if (v.kind == .midi) v.midi.deinit();
    if (v.kind == .wav and v.wav.pcm.len > 0) gpa.free(v.wav.pcm);
    v.* = .{};
}

// --- background suspend/resume (vm_audio_suspend_bg_play) ----------------------

pub fn suspendBg() void {
    for (&midi_voices) |*v| if (v.active and v.playing) {
        v.playing = false;
        v.bg_suspended = true;
    };
    for (&clip_voices) |*v| if (v.active and v.playing) {
        v.playing = false;
        v.bg_suspended = true;
    };
    for (&bs_voices) |*v| if (v.active and v.started) {
        v.started = false;
        v.bg_suspended = true;
    };
}
pub fn resumeBg() void {
    for (&midi_voices) |*v| if (v.active and v.bg_suspended) {
        v.playing = true;
        v.bg_suspended = false;
    };
    for (&clip_voices) |*v| if (v.active and v.bg_suspended) {
        v.playing = true;
        v.bg_suspended = false;
    };
    for (&bs_voices) |*v| if (v.active and v.bg_suspended) {
        v.started = true;
        v.bg_suspended = false;
    };
}

// --- bitstream API (vm_bitstream_audio_*) --------------------------------------

pub fn bitstreamOpenPcm(stereo: bool, rate_hz: u32, cb: u32) i32 {
    for (&bs_voices, 0..) |*v, i| {
        if (!v.active) {
            v.* = .{};
            v.active = true;
            v.stereo = stereo;
            v.rate = rate_hz;
            v.cb = cb;
            return @intCast(i + 1);
        }
    }
    return -1;
}
pub fn bitstreamClose(h: i32) i32 {
    const v = bsAt(h) orelse return -1;
    v.* = .{};
    return 0;
}
pub fn bitstreamPutData(h: i32, bytes: []const u8) ?u32 {
    const v = bsAt(h) orelse return null;
    const free_bytes = RING_BYTES - v.len;
    const n = @min(bytes.len & ~@as(usize, 1), free_bytes); // whole s16 samples
    var i: usize = 0;
    while (i < n) : (i += 1) {
        v.ring[(v.head + v.len + i) % RING_BYTES] = bytes[i];
    }
    v.len += n;
    return @intCast(n);
}
pub fn bitstreamStatus(h: i32) ?struct { total: u32, free: u32 } {
    const v = bsAt(h) orelse return null;
    return .{ .total = RING_BYTES, .free = @intCast(RING_BYTES - v.len) };
}
pub fn bitstreamStart(h: i32, vol: u8, start_ms: u32) i32 {
    _ = start_ms; // MREmu ignores it for the pure ring case
    const v = bsAt(h) orelse return -1;
    v.gain_num = @min(vol, 6);
    v.started = true;
    v.end_reported = false;
    return 0;
}
pub fn bitstreamStop(h: i32) i32 {
    const v = bsAt(h) orelse return -1;
    v.started = false;
    v.head = 0;
    v.len = 0;
    v.frac_fp = 0;
    return 0;
}
pub fn bitstreamFinished(h: i32) i32 {
    const v = bsAt(h) orelse return -1;
    v.data_finished = true;
    return 0;
}
pub fn bitstreamPlayTimeMs(h: i32) ?u32 {
    const v = bsAt(h) orelse return null;
    if (v.rate == 0) return 0;
    return @intCast(v.played_frames * 1000 / v.rate);
}

fn bsReadSample(v: *BitstreamVoice, frame_offset_bytes: usize) i16 {
    const i = (v.head + frame_offset_bytes) % RING_BYTES;
    const lo: u16 = v.ring[i];
    const hi: u16 = v.ring[(i + 1) % RING_BYTES];
    return @bitCast(lo | (hi << 8));
}

// --- mixer ----------------------------------------------------------------------

/// Mix everything into interleaved s16 stereo. Advances all voice clocks;
/// queues completion events for naturally-finished voices.
pub fn render(out: []i16, frames: usize) void {
    std.debug.assert(out.len >= frames * 2);
    var acc_buf: [MIX_BLOCK * 2]i32 = undefined;

    var done_frames: usize = 0;
    while (done_frames < frames) {
        // NOTE: explicit usize — @min with a comptime bound refines the result
        // type (u7 here), which would overflow on `n * 2`.
        const n: usize = @min(frames - done_frames, MIX_BLOCK);
        const acc = acc_buf[0 .. n * 2];
        @memset(acc, 0);

        for (&midi_voices, 0..) |*v, i| {
            if (!v.active or !v.playing) continue;
            v.state.mix(acc, n);
            if (v.state.done) {
                queueEvent(v.cb, @intCast(i + 1));
                v.state.deinit();
                v.* = .{};
            }
        }

        for (&clip_voices, 0..) |*v, i| {
            if (!v.active or !v.playing) continue;
            switch (v.kind) {
                .midi => {
                    v.midi.mix(acc, n);
                    if (v.midi.done) {
                        queueEvent(v.cb, @intCast(i + 1));
                        // keep the handle alive but silent: games close it via
                        // vm_audio_mixed_close from the completion callback.
                        v.playing = false;
                    }
                },
                .wav => mixWav(v, acc, n, @intCast(i + 1)),
                .fake => {
                    v.fake_playhead_ms += @as(f64, @floatFromInt(n)) * 1000.0 / SAMPLE_RATE;
                    if (v.fake_playhead_ms >= @as(f64, @floatFromInt(v.fake_duration_ms))) {
                        v.repeat_left -= 1;
                        if (v.repeat_left > 0) {
                            v.fake_playhead_ms = 0;
                        } else {
                            queueEvent(v.cb, @intCast(i + 1));
                            v.playing = false;
                        }
                    }
                },
            }
        }

        for (&bs_voices, 0..) |*v, i| {
            if (!v.active or !v.started) continue;
            mixBitstream(v, acc, n, @intCast(i + 1));
        }

        // global volume + clamp
        const vol: i32 = volume;
        for (0..n * 2) |k| {
            const s = @divTrunc(acc[k] * vol, 6);
            out[done_frames * 2 + k] = @intCast(std.math.clamp(s, std.math.minInt(i16), std.math.maxInt(i16)));
        }
        done_frames += n;
    }
}

fn mixWav(v: *ClipVoice, acc: []i32, frames: usize, handle: i32) void {
    const w = &v.wav;
    for (0..frames) |f| {
        const src_frame: usize = @intCast(w.pos_fp >> 16);
        if (src_frame >= w.frames) {
            v.repeat_left -= 1;
            if (v.repeat_left > 0) {
                w.pos_fp = 0;
                continue;
            }
            queueEvent(v.cb, handle);
            v.playing = false;
            return;
        }
        acc[f * 2] += w.sampleAt(src_frame, 0);
        acc[f * 2 + 1] += w.sampleAt(src_frame, 1);
        w.pos_fp += w.step_fp;
    }
}

fn mixBitstream(v: *BitstreamVoice, acc: []i32, frames: usize, handle: i32) void {
    const bytes_per_frame: usize = if (v.stereo) 4 else 2;
    const step_fp: u64 = (@as(u64, v.rate) << 16) / SAMPLE_RATE;
    const gain: i32 = v.gain_num;
    for (0..frames) |f| {
        if (v.len < bytes_per_frame) {
            // ring underrun; if the guest declared the stream finished, complete
            if (v.data_finished and !v.end_reported) {
                v.end_reported = true;
                v.started = false;
                queueEvent(v.cb, handle);
            }
            return;
        }
        const l = bsReadSample(v, 0);
        const r = if (v.stereo) bsReadSample(v, 2) else l;
        acc[f * 2] += @divTrunc(@as(i32, l) * gain, 6);
        acc[f * 2 + 1] += @divTrunc(@as(i32, r) * gain, 6);

        v.frac_fp += step_fp;
        const adv_frames = v.frac_fp >> 16;
        if (adv_frames > 0) {
            v.frac_fp &= 0xFFFF;
            const adv_bytes = @min(@as(usize, @intCast(adv_frames)) * bytes_per_frame, v.len);
            v.head = (v.head + adv_bytes) % RING_BYTES;
            v.len -= adv_bytes;
            v.played_frames += adv_frames;
        }
    }
}

// --- lifecycle -------------------------------------------------------------------

/// Headless/no-sink time keeping: render-to-discard so completion events and
/// playheads advance at wall-tick rate.
var fallback_rem_ms: u32 = 0;
var discard: [MIX_BLOCK * 2]i16 = undefined;

pub fn tickFallback(delta_ms: u32) void {
    var total_ms = delta_ms + fallback_rem_ms;
    const max_ms = 200; // don't spiral on huge deltas
    if (total_ms > max_ms) total_ms = max_ms;
    var frames = @as(usize, total_ms) * SAMPLE_RATE / 1000;
    fallback_rem_ms = 0;
    while (frames > 0) {
        const n: usize = @min(frames, MIX_BLOCK);
        render(&discard, n);
        frames -= n;
    }
}

/// Stop and free every voice and clear pending events. Called on Vm.destroy,
/// savestate load, and libretro reset/teardown.
pub fn reset() void {
    midiStopAll();
    clipStopAll();
    for (&bs_voices) |*v| v.* = .{};
    event_n = 0;
}

test "amr duration walks frames" {
    // header + two type-0 frames (12 payload bytes each) = 40 ms
    var buf: [6 + 13 * 2]u8 = undefined;
    @memcpy(buf[0..6], AMR_HEADER);
    buf[6] = 0 << 3;
    @memset(buf[7..19], 0xAA);
    buf[19] = 0 << 3;
    @memset(buf[20..32], 0xBB);
    try std.testing.expectEqual(@as(u32, 40), amrDurationMs(&buf));
}

test "render with zero voices" {
    reset();
    var buf: [256]i16 = undefined;
    render(&buf, 128);
    tickFallback(33);
    reset();
}

test "midi voice renders audible samples end-to-end" {
    if (comptime !synth_enabled) return;
    reset();
    // Minimal format-0 SMF: program 0, note-on C4, note-off after 2 beats.
    const smf = [_]u8{
        'M', 'T', 'h', 'd', 0, 0, 0, 6, 0, 0, 0, 1, 0, 0x60,
        'M', 'T', 'r', 'k', 0, 0, 0, 16,
        0x00, 0xC0, 0x00, // program change
        0x00, 0x90, 0x3C, 0x64, // note on C4 vel 100
        0x81, 0x40, 0x80, 0x3C, 0x00, // delta 192 ticks, note off
        0x00, 0xFF, 0x2F, 0x00, // end of track
    };
    const h = midiPlay(&smf, 0x1000, 0, 1, 0);
    try std.testing.expect(h == 1);

    var buf: [MIX_BLOCK * 2]i16 = undefined;
    var nonzero: usize = 0;
    var rendered: usize = 0;
    while (rendered < SAMPLE_RATE / 4) : (rendered += MIX_BLOCK) { // 250 ms
        render(&buf, MIX_BLOCK);
        for (buf) |s| {
            if (s != 0) nonzero += 1;
        }
    }
    try std.testing.expect(nonzero > 1000); // the note is audible
    try std.testing.expect(midiGetTimeMs(h).? >= 240);
    // play out the rest (1s note + release tail), voice must self-free
    var guard: usize = 0;
    while (midiAt(h) != null and guard < 10 * SAMPLE_RATE) : (guard += MIX_BLOCK)
        render(&buf, MIX_BLOCK);
    try std.testing.expect(midiAt(h) == null);
    reset();
}

test "handles are 1-based and invalid handles rejected" {
    reset();
    try std.testing.expectEqual(@as(i32, -1), midiPause(0));
    try std.testing.expectEqual(@as(i32, -1), midiPause(1));
    const h = bitstreamOpenPcm(false, 8000, 0);
    try std.testing.expectEqual(@as(i32, 1), h);
    try std.testing.expectEqual(@as(i32, 0), bitstreamClose(h));
    reset();
}

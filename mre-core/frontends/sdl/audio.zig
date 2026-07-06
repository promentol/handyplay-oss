//! SDL3 audio sink for the core audio engine (pattern from exen-core's
//! frontends/sdl/audio.zig): a push-model SDL_AudioStream fed from the main
//! loop — no callback thread touches engine state.
//!
//! `pump()` keeps ~100 ms of s16-stereo-44100 queued; the 16 ms main loop
//! refills ~706 frames per iteration so the cushion never underruns.
const std = @import("std");
const core = @import("core");

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "");
    @cInclude("SDL3/SDL.h");
});

var stream: ?*c.SDL_AudioStream = null;

const BYTES_PER_FRAME = 2 * @sizeOf(i16); // stereo s16
const TARGET_QUEUED_BYTES: c_int = 4410 * BYTES_PER_FRAME; // ~100 ms
const CHUNK_FRAMES = 1024;

/// Open the default playback device. Failure is non-fatal: the core's
/// tick-fallback keeps audio time (and completion callbacks) advancing.
pub fn init() void {
    // Debug bisect switch: MRE_NO_SDL_AUDIO=1 skips the audio device entirely
    // (engine falls back to tick-driven silent rendering).
    if (std.posix.getenv("MRE_NO_SDL_AUDIO") != null) return;
    if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
        std.debug.print("[audio] SDL audio init failed: {s}\n", .{c.SDL_GetError()});
        return;
    }
    const spec = c.SDL_AudioSpec{
        .format = c.SDL_AUDIO_S16,
        .channels = 2,
        .freq = core.audio.SAMPLE_RATE,
    };
    stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null);
    if (stream == null) {
        std.debug.print("[audio] SDL_OpenAudioDeviceStream failed: {s}\n", .{c.SDL_GetError()});
        return;
    }
    _ = c.SDL_ResumeAudioStreamDevice(stream);
    core.audio.rendered_by_frontend = true;
}

/// Render however much is needed to restore the latency cushion. Call once per
/// main-loop iteration (after vm.tick so this frame's natives are audible).
pub fn pump() void {
    const s = stream orelse return;
    var deficit_bytes = TARGET_QUEUED_BYTES - c.SDL_GetAudioStreamQueued(s);
    var buf: [CHUNK_FRAMES * 2]i16 = undefined;
    while (deficit_bytes > 0) {
        const frames: usize = @min(CHUNK_FRAMES, @as(usize, @intCast(deficit_bytes)) / BYTES_PER_FRAME + 1);
        core.audio.render(&buf, frames);
        if (!c.SDL_PutAudioStreamData(s, &buf, @intCast(frames * BYTES_PER_FRAME))) return;
        deficit_bytes -= @intCast(frames * BYTES_PER_FRAME);
    }
}

pub fn deinit() void {
    if (stream) |s| c.SDL_DestroyAudioStream(s);
    stream = null;
    core.audio.rendered_by_frontend = false;
}

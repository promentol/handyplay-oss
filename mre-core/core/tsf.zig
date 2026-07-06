//! Hand-written bindings for the vendored TinySoundFont (tsf.h + tml.h).
//! Only the subset the audio engine uses. No @cImport so targets that don't
//! compile the C implementation (wasm build-obj) never need include paths;
//! everything referencing these symbols sits behind `audio.synth_enabled`.
//! Struct layout must match tml.h at the vendored pin (see COMMIT_PIN).

pub const Tsf = opaque {};

pub const STEREO_INTERLEAVED: c_int = 0; // enum TSFOutputMode

// tml.h `struct tml_message`: u32 time(ms) | u8 type | u8 channel |
// 2-byte param union | next pointer.
pub const TmlMessage = extern struct {
    time: c_uint,
    type: u8,
    channel: u8,
    param: extern union {
        kv: extern struct {
            a: u8, // key / control / program / channel_pressure
            b: u8, // velocity / key_pressure / control_value
        },
        pitch_bend: c_ushort,
    },
    next: ?*TmlMessage,
};

// enum TMLMessageType
pub const TML_NOTE_OFF: u8 = 0x80;
pub const TML_NOTE_ON: u8 = 0x90;
pub const TML_KEY_PRESSURE: u8 = 0xA0;
pub const TML_CONTROL_CHANGE: u8 = 0xB0;
pub const TML_PROGRAM_CHANGE: u8 = 0xC0;
pub const TML_CHANNEL_PRESSURE: u8 = 0xD0;
pub const TML_PITCH_BEND: u8 = 0xE0;
pub const TML_SET_TEMPO: u8 = 0x51;

pub extern fn tsf_load_memory(buffer: ?*const anyopaque, size: c_int) ?*Tsf;
pub extern fn tsf_copy(f: *Tsf) ?*Tsf;
pub extern fn tsf_close(f: *Tsf) void;
pub extern fn tsf_reset(f: *Tsf) void;
pub extern fn tsf_set_output(f: *Tsf, outputmode: c_int, samplerate: c_int, global_gain_db: f32) void;
pub extern fn tsf_render_short(f: *Tsf, buffer: [*]i16, samples: c_int, flag_mixing: c_int) void;
pub extern fn tsf_note_off_all(f: *Tsf) void;
pub extern fn tsf_channel_set_presetnumber(f: *Tsf, channel: c_int, preset_number: c_int, flag_mididrums: c_int) c_int;
pub extern fn tsf_channel_note_on(f: *Tsf, channel: c_int, key: c_int, vel: f32) c_int;
pub extern fn tsf_channel_note_off(f: *Tsf, channel: c_int, key: c_int) void;
pub extern fn tsf_channel_midi_control(f: *Tsf, channel: c_int, controller: c_int, control_value: c_int) c_int;
pub extern fn tsf_channel_set_pitchwheel(f: *Tsf, channel: c_int, pitch_wheel: c_int) c_int;

pub extern fn tml_load_memory(buffer: ?*const anyopaque, size: c_int) ?*TmlMessage;
pub extern fn tml_free(f: ?*TmlMessage) void;
pub extern fn tml_get_info(
    first_message: *TmlMessage,
    used_channels: ?*c_int,
    used_programs: ?*c_int,
    total_notes: ?*c_int,
    time_first_note: ?*c_uint,
    time_length: ?*c_uint,
) c_int;

//! Minimal libretro API surface, hand-declared in Zig (no libretro.h needed).
//! Only the structs/enums/callbacks our cores use. C ABI throughout, linked into a
//! native `.so`/`.dylib` for RetroArch and any other libretro host.
const std = @import("std");

pub const API_VERSION: c_uint = 1;

// retro_environment commands we handle.
pub const ENVIRONMENT_SET_PIXEL_FORMAT: c_uint = 10;
pub const ENVIRONMENT_GET_SYSTEM_DIRECTORY: c_uint = 9;
pub const ENVIRONMENT_GET_SAVE_DIRECTORY: c_uint = 31;
pub const ENVIRONMENT_GET_VFS_INTERFACE: c_uint = 45 | 0x10000;

pub const PIXEL_FORMAT_0RGB1555: c_uint = 0;
pub const PIXEL_FORMAT_XRGB8888: c_uint = 1;
pub const PIXEL_FORMAT_RGB565: c_uint = 2;

pub const REGION_NTSC: c_uint = 0;

pub const DEVICE_JOYPAD: c_uint = 1;
pub const DEVICE_ID_JOYPAD_B: c_uint = 0;
pub const DEVICE_ID_JOYPAD_Y: c_uint = 1;
pub const DEVICE_ID_JOYPAD_SELECT: c_uint = 2;
pub const DEVICE_ID_JOYPAD_START: c_uint = 3;
pub const DEVICE_ID_JOYPAD_UP: c_uint = 4;
pub const DEVICE_ID_JOYPAD_DOWN: c_uint = 5;
pub const DEVICE_ID_JOYPAD_LEFT: c_uint = 6;
pub const DEVICE_ID_JOYPAD_RIGHT: c_uint = 7;
pub const DEVICE_ID_JOYPAD_A: c_uint = 8;
pub const DEVICE_ID_JOYPAD_X: c_uint = 9;
pub const DEVICE_ID_JOYPAD_L: c_uint = 10;
pub const DEVICE_ID_JOYPAD_R: c_uint = 11;

pub const MEMORY_SAVE_RAM: c_uint = 0;
pub const MEMORY_SYSTEM_RAM: c_uint = 2;

pub const SystemInfo = extern struct {
    library_name: [*:0]const u8,
    library_version: [*:0]const u8,
    valid_extensions: [*:0]const u8,
    need_fullpath: bool,
    block_extract: bool,
};

pub const GameGeometry = extern struct {
    base_width: c_uint,
    base_height: c_uint,
    max_width: c_uint,
    max_height: c_uint,
    aspect_ratio: f32,
};

pub const SystemTiming = extern struct {
    fps: f64,
    sample_rate: f64,
};

pub const SystemAvInfo = extern struct {
    geometry: GameGeometry,
    timing: SystemTiming,
};

pub const GameInfo = extern struct {
    path: ?[*:0]const u8,
    data: ?*const anyopaque,
    size: usize,
    meta: ?[*:0]const u8,
};

pub const EnvironmentFn = ?*const fn (c_uint, ?*anyopaque) callconv(.c) bool;
pub const VideoRefreshFn = ?*const fn (?*const anyopaque, c_uint, c_uint, usize) callconv(.c) void;
pub const AudioSampleFn = ?*const fn (i16, i16) callconv(.c) void;
pub const AudioSampleBatchFn = ?*const fn (?[*]const i16, usize) callconv(.c) usize;
pub const InputPollFn = ?*const fn () callconv(.c) void;
pub const InputStateFn = ?*const fn (c_uint, c_uint, c_uint, c_uint) callconv(.c) i16;

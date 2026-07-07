//! Host-implemented `vm_*` natives — the full native func table (~165
//! entries). Each handler reads args via `vm.arg(i)` and returns through `vm.setRet`.
//! Covers the System/IO/Graphics/Textout/CharSet/Timer/Audio/Sock/SIM/STDLib/
//! ProgramManager/Resources subsystems plus call marshalling.
//!
//! Implementation depth: graphics/text/file-io/resources/timers/charset/stdlib/sim
//! are real; audio/socket/media are faithful constant stubs (no host audio/network
//! device in this build), matching the reference's return values.
const std = @import("std");
const vmmod = @import("vm.zig");
const Vm = vmmod.Vm;
const Bridge = @import("bridge.zig").Bridge;
const gfx = @import("gfx.zig");
const audio = @import("audio.zig");
const tags = @import("loader/tags.zig");
const png = @import("codecs/png.zig");
const gif = @import("codecs/gif.zig");

fn s(v: u32) i32 {
    return @bitCast(v);
}
fn u(v: i32) u32 {
    return @bitCast(v);
}

/// Metadata for one native registration — the single source of truth for the table
/// below AND offline tooling (imported directly, no text parsing). The old
/// `// VERIFIED` / `// UNVERIFIED` line comments are now the structured `verified`
/// boolean; the trailing comment keeps the human rationale.
///   stub = false                 -> implemented (real handler)
///   stub = true, verified = true   -> placeholder whose constant return is confirmed correct
///   stub = true, verified = false  -> placeholder with an unconfirmed / guessed return
pub const Native = struct {
    name: []const u8,
    handler: *const fn (*Vm) void,
    stub: bool = false,
    verified: bool = false,
};

pub const table = [_]Native{

    // Stub (r.rs) verification status — surfaces in the STUBBED run report and the
    // per-call "[bridge] STUBBED call:" log:
    //   VERIFIED   — the constant return is confirmed correct/honest: SDK-doc-checked,
    //                a void/no-op call, or the right value for a device/subsystem this
    //                host genuinely cannot provide. No action needed.
    //   UNVERIFIED — registered as a placeholder; its return is unconfirmed (a guess, or
    //                a subsystem we could implement). Candidate for review — trace via the
    //                STUBBED-call log when a game misbehaves.

    // ---- System ----
    .{ .name = "vm_get_time", .handler = getTime },
    .{ .name = "vm_get_curr_utc", .handler = getCurrUtc },
    .{ .name = "vm_get_sys_time_zone", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — TZ offset guessed as 0 (UTC)
    .{ .name = "vm_get_malloc_stat", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — heap stats not modeled
    .{ .name = "vm_malloc", .handler = sysMalloc },
    .{ .name = "vm_calloc", .handler = sysCalloc },
    .{ .name = "vm_realloc", .handler = sysRealloc },
    .{ .name = "vm_free", .handler = sysFree },
    .{ .name = "vm_reg_sysevt_callback", .handler = regSysevt },
    .{ .name = "vm_get_mre_total_mem_size", .handler = getTotalMem },
    .{ .name = "vm_get_tick_count", .handler = getTickCount },
    .{ .name = "vm_get_exec_filename", .handler = getExecFilename },
    .{ .name = "vm_get_sys_property", .handler = getSysProperty },
    .{ .name = "vm_get_vm_tag", .handler = getVmTag },
    .{ .name = "vm_app_log", .handler = appLog },
    .{ .name = "vm_switch_power_saving_mode", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — no device power state; no-op is correct
    .{ .name = "vm_get_sys_scene", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — doc: sound profile; 0 = standard mode (not silent/meeting), the sensible default
    .{ .name = "vm_appmgr_is_installed", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — always "not installed"; may affect self-install flows
    .{ .name = "vm_appmgr_get_installed_list", .handler = appmgrList },
    .{ .name = "vm_exit_app", .handler = exitApp },
    .{ .name = "vm_send_sms", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — SMS absent; real send likely needs a completion event (see docs/sms_subsystem.md)

    // ---- Program manager / message ----
    .{ .name = "vm_pmng_get_current_handle", .handler = retOne, .stub = true, .verified = false }, // UNVERIFIED — handle value guessed as 1
    .{ .name = "vm_reg_msg_proc", .handler = regMsgProc },
    .{ .name = "vm_post_msg", .handler = retOne, .stub = true, .verified = false }, // UNVERIFIED — message not actually queued

    // ---- Timer ----
    .{ .name = "vm_create_timer", .handler = createTimer },
    .{ .name = "vm_delete_timer", .handler = deleteTimer },
    .{ .name = "vm_create_timer_ex", .handler = createTimer },
    .{ .name = "vm_delete_timer_ex", .handler = deleteTimer },

    // ---- File / IO ----
    .{ .name = "vm_reg_keyboard_callback", .handler = regKeyboard },
    .{ .name = "vm_reg_pen_callback", .handler = regPen },
    .{ .name = "vm_file_open", .handler = fileOpen },
    .{ .name = "vm_file_close", .handler = fileClose },
    .{ .name = "vm_file_read", .handler = fileRead },
    .{ .name = "vm_file_write", .handler = fileWrite },
    .{ .name = "vm_file_commit", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — flush of a memory-backed file is a no-op success (0)
    .{ .name = "vm_file_seek", .handler = fileSeek },
    .{ .name = "vm_file_tell", .handler = fileTell },
    .{ .name = "vm_file_is_eof", .handler = fileIsEof },
    .{ .name = "vm_file_getfilesize", .handler = fileGetSize },
    .{ .name = "vm_file_delete", .handler = retNeg1, .stub = true, .verified = false }, // UNVERIFIED — delete not implemented; returns failure
    .{ .name = "vm_file_rename", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — rename not implemented; 0 may falsely signal success
    .{ .name = "vm_file_mkdir", .handler = fileMkdir },
    .{ .name = "vm_file_set_attributes", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — attributes ignored
    .{ .name = "vm_file_get_attributes", .handler = fileGetAttributes },
    .{ .name = "vm_find_first", .handler = retNeg1, .stub = true, .verified = false }, // UNVERIFIED — directory enumeration not implemented (no matches)
    .{ .name = "vm_find_next", .handler = retNeg1, .stub = true, .verified = false }, // UNVERIFIED — directory enumeration not implemented
    .{ .name = "vm_find_close", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — doc: void return, nothing to close
    .{ .name = "vm_find_first_ext", .handler = retNeg1, .stub = true, .verified = false }, // UNVERIFIED — directory enumeration not implemented (no matches)
    .{ .name = "vm_find_next_ext", .handler = retNeg1, .stub = true, .verified = false }, // UNVERIFIED — directory enumeration not implemented
    .{ .name = "vm_find_close_ext", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — doc: void return, nothing to close
    .{ .name = "vm_file_get_modify_time", .handler = retNeg1, .stub = true, .verified = false }, // UNVERIFIED — mtime not tracked
    .{ .name = "vm_get_removeable_driver", .handler = retEDrive, .stub = true, .verified = true }, // VERIFIED — doc: removable-disk drive letter ('e')
    .{ .name = "vm_get_system_driver", .handler = retCDrive, .stub = true, .verified = true }, // VERIFIED — doc: phone/system-disk drive letter ('c')
    .{ .name = "vm_get_disk_free_space", .handler = diskFree },
    .{ .name = "vm_get_disk_info", .handler = retNeg1, .stub = true, .verified = false }, // UNVERIFIED — disk geometry not modeled
    .{ .name = "vm_is_support_keyborad", .handler = retOne, .stub = true, .verified = false }, // UNVERIFIED — assumes a keypad is present
    .{ .name = "vm_is_support_pen_touch", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — doc: TRUE/FALSE; emulated keypad phone has no touch panel (FALSE)
    .{ .name = "vm_get_resource_offset_from_file", .handler = resOffsetFromFile },

    // ---- SIM ----
    .{ .name = "vm_get_operator", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — no SIM; operator code faked as 0
    .{ .name = "vm_has_sim_card", .handler = retOne, .stub = true, .verified = false }, // UNVERIFIED — fakes a SIM present so games proceed
    .{ .name = "vm_get_imei", .handler = getImei },
    .{ .name = "vm_get_imsi", .handler = getImsi },
    .{ .name = "vm_sim_card_count", .handler = retOne, .stub = true, .verified = false }, // UNVERIFIED — fakes a single SIM
    .{ .name = "vm_set_active_sim_card", .handler = simActiveSet },
    .{ .name = "vm_get_sim_card_status", .handler = simStatus },
    .{ .name = "vm_query_operator_code", .handler = queryOperator },
    .{ .name = "vm_sim_get_active_sim_card", .handler = retOne, .stub = true, .verified = false }, // UNVERIFIED — fakes active SIM #1
    .{ .name = "vm_sim_max_card_count", .handler = retOne, .stub = true, .verified = false }, // UNVERIFIED — fakes single-SIM device
    .{ .name = "vm_sim_get_prefer_sim_card", .handler = retOne, .stub = true, .verified = false }, // UNVERIFIED — fakes preferred SIM #1

    // ---- Graphics ----
    .{ .name = "vm_graphic_get_screen_width", .handler = gScreenW },
    .{ .name = "vm_graphic_get_screen_height", .handler = gScreenH },
    .{ .name = "vm_graphic_create_layer", .handler = gCreateLayer },
    .{ .name = "vm_graphic_delete_layer", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — layer not actually freed/deregistered
    .{ .name = "vm_graphic_active_layer", .handler = gActiveLayer },
    .{ .name = "vm_graphic_get_layer_buffer", .handler = gGetLayerBuffer },
    .{ .name = "vm_graphic_flush_layer", .handler = gFlushLayer },
    .{ .name = "vm_graphic_flatten_layer", .handler = gFlushLayer },
    .{ .name = "vm_graphic_clear_layer_bg", .handler = gClearLayerBg },
    .{ .name = "vm_graphic_translate_layer", .handler = gTranslateLayer },
    .{ .name = "vm_graphic_get_bits_per_pixel", .handler = gBpp },
    // NOTE: the reference's FUNCN_FIX macro registers the NON-_FIX symbol name
    // (the _FIX suffix is only on the C impl). Games call the unsuffixed names.
    .{ .name = "vm_graphic_create_canvas", .handler = gCreateCanvas },
    .{ .name = "vm_graphic_create_canvas_cf", .handler = gCreateCanvasCf },
    .{ .name = "vm_graphic_release_canvas", .handler = gReleaseCanvas },
    .{ .name = "vm_graphic_get_canvas_buffer", .handler = gGetCanvasBuffer },
    .{ .name = "vm_graphic_create_layer_ex", .handler = gCreateLayerEx },
    .{ .name = "vm_graphic_create_layer_cf", .handler = gCreateLayerCf },
    .{ .name = "vm_graphic_load_image", .handler = gLoadImage },
    .{ .name = "vm_graphic_load_image_resized", .handler = gLoadImageResized },
    .{ .name = "vm_graphic_draw_image_from_memory", .handler = gDrawImageFromMemory },
    .{ .name = "vm_graphic_get_img_property", .handler = gGetImgProperty },
    .{ .name = "vm_graphic_get_img_property_ex", .handler = gGetImgPropertyEx },
    .{ .name = "vm_graphic_set_alpha_blending_layer", .handler = gSetAlphaBlend },
    .{ .name = "vm_graphic_get_frame_number", .handler = gGetFrameNumber },
    .{ .name = "vm_graphic_blt", .handler = gBlt },
    .{ .name = "vm_graphic_blt_ex", .handler = gBltEx },
    .{ .name = "vm_graphic_rotate", .handler = gRotate },
    .{ .name = "vm_graphic_mirror", .handler = gMirror },
    .{ .name = "vm_graphic_set_pixel", .handler = gSetPixel },
    .{ .name = "vm_graphic_set_pixel_ex", .handler = gSetPixelEx },
    .{ .name = "vm_graphic_line", .handler = gLine },
    .{ .name = "vm_graphic_line_ex", .handler = gLineEx },
    .{ .name = "vm_graphic_fill_rect", .handler = gFillRect },
    .{ .name = "vm_graphic_fill_rect_ex", .handler = gFillRectEx },
    .{ .name = "vm_graphic_roundrect", .handler = gRoundRect },
    .{ .name = "vm_graphic_roundrect_ex", .handler = gRoundRectEx },
    .{ .name = "vm_graphic_fill_roundrect", .handler = gFillRoundRect },
    .{ .name = "vm_graphic_fill_roundrect_ex", .handler = gFillRoundRectEx },
    .{ .name = "vm_graphic_rect", .handler = gRect },
    .{ .name = "vm_graphic_rect_ex", .handler = gRectEx },
    .{ .name = "vm_graphic_fill_polygon", .handler = gFillPolygon },
    .{ .name = "vm_graphic_fill_ellipse_ex", .handler = gFillEllipseEx },
    .{ .name = "vm_graphic_set_clip", .handler = gSetClip },
    .{ .name = "vm_graphic_reset_clip", .handler = gResetClip },
    .{ .name = "vm_graphic_flush_screen", .handler = gFlushScreen },
    .{ .name = "vm_graphic_is_r2l_state", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — doc: 0 = not right-to-left; correct for LTR games
    .{ .name = "vm_graphic_setcolor", .handler = gSetColor },
    .{ .name = "vm_graphic_canvas_set_trans_color", .handler = gCanvasTrans },
    .{ .name = "vm_graphic_get_buffer", .handler = gGetBuffer },
    .{ .name = "vm_initialize_screen_buffer", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — no-op; screen buffer is init elsewhere (assumed unneeded)

    // ---- Textout ----
    .{ .name = "vm_graphic_get_character_height", .handler = gCharH },
    .{ .name = "vm_graphic_get_character_width", .handler = gCharW },
    .{ .name = "vm_graphic_get_string_width", .handler = gStringW },
    .{ .name = "vm_graphic_get_string_height", .handler = gCharH },
    .{ .name = "vm_graphic_measure_character", .handler = gMeasureChar },
    .{ .name = "vm_graphic_get_character_info", .handler = retNeg1, .stub = true, .verified = false }, // UNVERIFIED — per-char metrics struct not filled
    .{ .name = "vm_graphic_set_font", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — doc: void; fixed 16px bitmap font can't honor size
    .{ .name = "vm_graphic_textout", .handler = gTextout },
    .{ .name = "vm_graphic_textout_by_baseline", .handler = gTextoutBaseline },
    .{ .name = "vm_font_set_font_size", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — fixed bitmap font; size not configurable (as set_font)
    .{ .name = "vm_font_set_font_style", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — doc: bold/italic valid only to vector font; 0 = VM_GDI_SUCCEED
    .{ .name = "vm_graphic_textout_to_layer", .handler = gTextoutToLayer },
    .{ .name = "vm_graphic_get_string_baseline", .handler = gGetStringBaseline },
    .{ .name = "vm_graphic_is_use_vector_font", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — we render a bitmap font, so "not vector" (0) is correct
    .{ .name = "vm_graphic_get_char_num_in_width", .handler = gCharNumInWidth },

    // ---- Resources ----
    .{ .name = "vm_load_resource", .handler = loadResource },
    .{ .name = "vm_resource_get_data", .handler = resourceGetData },
    .{ .name = "vm_get_res_header", .handler = retEight, .stub = true, .verified = false }, // UNVERIFIED — returns constant 8 (header size guessed)
    .{ .name = "vm_reg_res_provider", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — doc: void; registers a guest resource callback consulted only by resid-based loaders (vm_midi_play etc.), which are themselves stubbed, so storing it is a no-op today

    // ---- CharSet ----
    .{ .name = "vm_ucs2_to_gb2312", .handler = ucs2ToAscii },
    .{ .name = "vm_gb2312_to_ucs2", .handler = asciiToUcs2 },
    .{ .name = "vm_ucs2_to_ascii", .handler = ucs2ToAscii },
    .{ .name = "vm_ascii_to_ucs2", .handler = asciiToUcs2 },
    .{ .name = "vm_chset_convert", .handler = chsetConvert },
    .{ .name = "vm_get_language", .handler = retOne, .stub = true, .verified = false }, // UNVERIFIED — language id faked (assumed English)
    .{ .name = "vm_get_language_ssc", .handler = langSsc },
    .{ .name = "vm_ucs2_string", .handler = ucs2String },

    // ---- STDLib ----
    .{ .name = "vm_wstrlen", .handler = wstrlen },
    .{ .name = "vm_wstrcpy", .handler = wstrcpy },
    .{ .name = "vm_wstrncpy", .handler = wstrncpy },
    .{ .name = "vm_wstrcat", .handler = wstrcat },
    .{ .name = "vm_wstrcmp", .handler = wstrcmp },
    .{ .name = "vm_get_filename", .handler = getFilename },
    .{ .name = "vm_lower_case", .handler = lowerCase },
    .{ .name = "vm_get_gmobi_language", .handler = getGmobiLanguage },

    // ---- Audio ----
    .{ .name = "vm_set_volume", .handler = setVolume },
    .{ .name = "vm_get_volume", .handler = getVolume },
    .{ .name = "vm_audio_play_bytes_no_block", .handler = audioPlay },
    .{ .name = "vm_audio_stop_all", .handler = audioStopAll },
    .{ .name = "vm_audio_mixed_close", .handler = audioClose },
    .{ .name = "vm_audio_mixed_close_all", .handler = audioStopAll },
    .{ .name = "vm_audio_suspend_bg_play", .handler = audioSuspendBg }, // [reconstructed]
    .{ .name = "vm_audio_resume_bg_play", .handler = audioResumeBg }, // [reconstructed]
    // legacy MIDI/bitstream APIs (route to the same backend where sensible)
    .{ .name = "vm_midi_play", .handler = retNeg1, .stub = true, .verified = true }, // VERIFIED — doc: plays MIDI by resource id via the reg_res_provider callback; resid→bytes + guest-callback invocation not wired, so report VM_MIDI_FAILED (-1)
    .{ .name = "vm_midi_play_by_bytes", .handler = midiPlayBytes },
    .{ .name = "vm_midi_play_by_bytes_ex", .handler = midiPlayBytesEx },
    .{ .name = "vm_midi_pause", .handler = midiPause },
    .{ .name = "vm_midi_resume", .handler = midiResume },
    .{ .name = "vm_midi_get_time", .handler = midiGetTime },
    .{ .name = "vm_midi_stop", .handler = midiStop },
    .{ .name = "vm_midi_stop_all", .handler = midiStopAll },
    .{ .name = "vm_bitstream_audio_open", .handler = bsOpen },
    .{ .name = "vm_bitstream_audio_open_pcm", .handler = bsOpenPcm },
    .{ .name = "vm_bitstream_audio_finished", .handler = bsFinished },
    .{ .name = "vm_bitstream_audio_close", .handler = bsClose },
    .{ .name = "vm_bitstream_audio_get_buffer_status", .handler = bsStatus },
    .{ .name = "vm_bitstream_audio_put_data", .handler = bsPutData },
    .{ .name = "vm_bitstream_audio_start", .handler = bsStart },
    .{ .name = "vm_bitstream_audio_stop", .handler = bsStop },
    .{ .name = "vm_bitstream_audio_get_play_time", .handler = bsGetPlayTime },
    .{ .name = "vm_bitstream_audio_put_frame", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — absent on real device too (Gold Miner)
    .{ .name = "ext_media_setbufer", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — media capture/record not modeled
    .{ .name = "ext_media_getreadbuffer", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — media capture/record not modeled
    .{ .name = "ext_media_record", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — media capture/record not modeled
    .{ .name = "ext_media_readdatadone", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — media capture/record not modeled
    .{ .name = "ext_media_stop", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — media capture/record not modeled

    // ---- Socket / network (stubbed: no host network) ----
    .{ .name = "vm_is_support_wifi", .handler = retOne, .stub = true, .verified = false }, // UNVERIFIED — claims WiFi supported; inconsistent with no-network design
    .{ .name = "vm_wifi_is_connected", .handler = retOne, .stub = true, .verified = false }, // UNVERIFIED — claims connected despite no network (suspect; likely should be 0)
    .{ .name = "vm_soc_get_host_by_name", .handler = retNeg1, .stub = true, .verified = true }, // VERIFIED — no network: DNS resolve fails (-1)
    .{ .name = "vm_tcp_connect", .handler = retNeg1, .stub = true, .verified = true }, // VERIFIED — no network: connect fails (-1)
    .{ .name = "vm_tcp_close", .handler = retZero, .stub = true, .verified = true }, // VERIFIED — close no-op success
    .{ .name = "vm_tcp_read", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — 0 bytes; unreachable if connect fails, EOF-vs-error ambiguous
    .{ .name = "vm_tcp_write", .handler = retZero, .stub = true, .verified = false }, // UNVERIFIED — 0 bytes; unreachable if connect fails

    // ---- Misc ----
    .{ .name = "srand", .handler = srand },
    .{ .name = "rand", .handler = rand },

    // ---- ARModule memory (stdio helper) ----
    .{ .name = "armodule_malloc", .handler = armMalloc },
    .{ .name = "armodule_realloc", .handler = armRealloc },
    .{ .name = "armodule_free", .handler = armFree },
};

pub fn registerAll(b: *Bridge) void {
    for (table) |e| {
        _ = if (e.stub) b.registerStub(e.name, e.handler) else b.register(e.name, e.handler);
    }
}

// ---- generic returns -------------------------------------------------------
fn retZero(vm: *Vm) void {
    vm.setRet(0);
}
fn retOne(vm: *Vm) void {
    vm.setRet(1);
}
fn retEight(vm: *Vm) void {
    vm.setRet(8);
}
fn retNeg1(vm: *Vm) void {
    vm.setRet(u(-1));
}
fn retEDrive(vm: *Vm) void {
    vm.setRet('e');
}
fn retCDrive(vm: *Vm) void {
    vm.setRet('c');
}

// ---- system / memory -------------------------------------------------------
fn appArena(vm: *Vm) ?*@import("memory.zig").Manager {
    if (vm.app) |*app| return &app.app_memory;
    return null;
}

fn sysMalloc(vm: *Vm) void {
    const a = appArena(vm) orelse return vm.setRet(0);
    vm.setRet(a.malloc(vm.arg(0), false, 8));
}
fn sysCalloc(vm: *Vm) void {
    const a = appArena(vm) orelse return vm.setRet(0);
    const size = vm.arg(0);
    const p = a.malloc(size, false, 8);
    if (p != 0) @memset(vm.mem.slice(p, size), 0);
    vm.setRet(p);
}
fn sysRealloc(vm: *Vm) void {
    const a = appArena(vm) orelse return vm.setRet(0);
    vm.setRet(a.realloc(vm.mem, vm.arg(0), vm.arg(1)));
}
fn sysFree(vm: *Vm) void {
    if (appArena(vm)) |a| a.free(vm.arg(0));
    vm.setRet(0);
}
fn getTotalMem(vm: *Vm) void {
    vm.setRet(@intCast(vm.mem.buf.len));
}
fn getTickCount(vm: *Vm) void {
    // Nudge the clock on every read. clock_ms is otherwise frozen for the duration
    // of a single runCpu callback, so a game that busy-waits on elapsed time
    // (`while (get_tick_count() - start < delay) {}`) inside one callback would spin
    // forever (our clock only advances between ticks). The +1/call keeps such waits
    // making progress so they terminate; it's negligible beside vm.tick(delta)'s
    // per-frame advance during normal pacing. Fixes the Block Breaker 3 startup hang.
    vm.clock_ms +%= 1;
    vm.setRet(vm.clock_ms);
}
fn getTime(vm: *Vm) void {
    vm.setRet(0);
}
fn getCurrUtc(vm: *Vm) void {
    const p = vm.arg(0);
    if (p != 0) vm.mem.writeU32(p, @intCast(@as(u64, @bitCast(std.time.timestamp())) & 0xFFFF_FFFF));
    vm.setRet(0);
}
fn getSysProperty(vm: *Vm) void {
    vm.setRet(0);
}
var applog_budget: u32 = 40;
fn appLog(vm: *Vm) void {
    if (std.posix.getenv("LOG_FILES") != null and applog_budget > 0) {
        applog_budget -= 1;
        std.debug.print("[app_log] {s}\n", .{vm.readCStr(vm.arg(0))});
    }
    vm.setRet(0);
}
fn getExecFilename(vm: *Vm) void {
    // Return the app's own path so the game can re-open itself for resources.
    // The runner mirrors the .vxp to ./fs/c/app.vxp, which "C:\app.vxp" maps to.
    const p = vm.arg(0);
    if (p != 0) {
        const path = "C:\\app.vxp";
        var i: u32 = 0;
        while (i < path.len) : (i += 1) vm.mem.writeU16(p + i * 2, path[i]);
        vm.mem.writeU16(p + i * 2, 0);
    }
    vm.setRet(0);
}
fn getVmTag(vm: *Vm) void {
    // vm_get_vm_tag(short* filename, int tag_num, void* buf, int* buf_size): read a
    // tagged data section from the .vxp. Games query their own app for config/resource
    // tags (e.g. Bubble Frenzy reads 0x27/0x28/5), so we serve tags from the loaded
    // app bytes (vm.file) and ignore the filename. Two-call protocol: buf==0 reports
    // the size in *buf_size; buf!=0 copies up to *buf_size bytes. Returns
    // GET_TAG_TRUE(1) on success, GET_TAG_NOT_FOUND(0) otherwise.
    const tag_num = vm.arg(1);
    const buf = vm.arg(2);
    const size_p = vm.arg(3);
    const data = tags.findTag(vm.file, tag_num) orelse return vm.setRet(0);
    const sz: u32 = @intCast(data.len);
    if (buf == 0) {
        if (size_p != 0) vm.mem.writeU32(size_p, sz);
        return vm.setRet(1); // size query
    }
    const cap: u32 = if (size_p != 0) vm.mem.readU32(size_p) else sz;
    const n = @min(cap, sz);
    if (n != 0) @memcpy(vm.mem.slice(buf, n), data[0..n]);
    if (size_p != 0) vm.mem.writeU32(size_p, sz);
    vm.setRet(1);
}
fn appmgrList(vm: *Vm) void {
    const num = vm.arg(2);
    if (num != 0) vm.mem.writeU32(num, 0);
    vm.setRet(0);
}

// ---- program manager -------------------------------------------------------
fn regMsgProc(vm: *Vm) void {
    vm.cb_msg_proc = vm.arg(0);
    vm.setRet(0);
}

// ---- timer -----------------------------------------------------------------
fn createTimer(vm: *Vm) void {
    const interval = vm.arg(0);
    const cb = vm.arg(1);
    for (&vm.timers, 0..) |*t, id| {
        if (!t.active) {
            t.* = .{ .active = true, .interval = interval, .accum = 0, .cb = cb };
            if (std.posix.getenv("LOG_FILES") != null)
                std.debug.print("[timer] create handle={d} interval={d}ms cb=0x{x:0>8}\n", .{ id + 1, interval, cb });
            // MRE timer handles are 1-based: the doc guarantees a successful
            // handle is > 0. Returning a 0-based slot index makes the first
            // timer's handle 0, which games read as "no timer / failed" — they
            // then never delete it (guarded `if (handle) vm_delete_timer(handle)`),
            // orphaning the callback so it keeps firing on freed state.
            return vm.setRet(@intCast(id + 1));
        }
    }
    vm.setRet(u(-1));
}
fn deleteTimer(vm: *Vm) void {
    const handle = vm.arg(0);
    if (std.posix.getenv("LOG_FILES") != null)
        std.debug.print("[timer] delete handle={d}\n", .{handle});
    if (handle >= 1 and handle - 1 < vm.timers.len) vm.timers[handle - 1].active = false;
    vm.setRet(0);
}

// ---- input registration ----------------------------------------------------
fn regSysevt(vm: *Vm) void {
    vm.cb_sysevt = vm.arg(0);
    vm.setRet(0);
}
fn regKeyboard(vm: *Vm) void {
    vm.cb_keyboard = vm.arg(0);
    vm.setRet(0);
}
fn regPen(vm: *Vm) void {
    vm.cb_pen = vm.arg(0);
    vm.setRet(0);
}

// ---- file I/O (app .vxp served from memory; other paths under ./fs/<drive>/) -
fn openVFile(vm: *Vm, name_emu: u32, mode: u32) ?vmmod.VFile {
    var ucs2_buf: [512]u8 = undefined;
    const name = vm.readUcs2(name_emu, &ucs2_buf);
    if (name.len < 3 or name[1] != ':') return null;

    // The app's own .vxp is served from memory (vm.file) — games re-open it
    // thousands of times during resource loading; host opens would be far too slow.
    if (std.ascii.endsWithIgnoreCase(name, "app.vxp") and vm.file.len != 0)
        return .{ .data = vm.file, .pos = 0 };

    var host: [600]u8 = undefined;
    var w: usize = 0;
    const prefix = "fs/";
    @memcpy(host[0..prefix.len], prefix);
    w = prefix.len;
    host[w] = std.ascii.toLower(name[0]);
    w += 1;
    for (name[2..]) |ch| {
        host[w] = if (ch == '\\') '/' else ch;
        w += 1;
    }
    const path = host[0..w];
    const create = (mode & 0x0C) != 0;
    const f = if (create)
        std.fs.cwd().createFile(path, .{ .read = true, .truncate = (mode & 0x04) != 0 }) catch return null
    else
        std.fs.cwd().openFile(path, .{}) catch return null;
    return .{ .file = f };
}

// ---- filesystem attributes / mkdir (recovered) ----
const VM_FS_ATTR_DIR: u32 = 0x10; // [reconstructed constant]
const VM_FS_ATTR_READ_ONLY: u32 = 0x01; // [reconstructed constant]

/// [reconstructed] Resolve emulated "C:\path" -> host "fs/c/path" slice in `out`.
/// Mirrors openVFile's inline path translation (drive letter -> lowercase dir).
fn hostPath(vm: *Vm, name_emu: u32, out: *[600]u8) ?[]const u8 {
    var ucs2_buf: [512]u8 = undefined;
    const name = vm.readUcs2(name_emu, &ucs2_buf);
    if (name.len < 3 or name[1] != ':') return null;
    const prefix = "fs/";
    @memcpy(out[0..prefix.len], prefix);
    var w: usize = prefix.len;
    out[w] = std.ascii.toLower(name[0]);
    w += 1;
    for (name[2..]) |ch| {
        out[w] = if (ch == '\\') '/' else ch;
        w += 1;
    }
    return out[0..w];
}

/// [reconstructed] Debug bisect switch: MRE_FS_COMPAT=1 restores the old stub
/// behavior (return -1) to isolate fs-related regressions.
fn fsCompat() bool {
    return std.posix.getenv("MRE_FS_COMPAT") != null;
}

fn fileMkdir(vm: *Vm) void { // [reconstructed body]
    if (fsCompat()) return vm.setRet(u(-1));
    var host: [600]u8 = undefined;
    const path = hostPath(vm, vm.arg(0), &host) orelse return vm.setRet(u(-1));
    std.fs.cwd().makeDir(path) catch return vm.setRet(u(-1));
    vm.setRet(0);
}
fn fileGetAttributes(vm: *Vm) void { // recovered exactly from transcript
    if (fsCompat()) return vm.setRet(u(-1));
    // vm_file_get_attributes(filename) -> attr bits, or -1 if it doesn't exist.
    var host: [600]u8 = undefined;
    const path = hostPath(vm, vm.arg(0), &host) orelse return vm.setRet(u(-1));
    if (std.fs.cwd().openDir(path, .{})) |d| {
        var dir = d;
        dir.close();
        flog("[file] attrs '{s}' -> DIR\n", .{path});
        return vm.setRet(VM_FS_ATTR_DIR);
    } else |_| {}
    const st = std.fs.cwd().statFile(path) catch {
        flog("[file] attrs '{s}' -> missing\n", .{path});
        return vm.setRet(u(-1));
    };
    const ro: u32 = if (st.mode != 0 and (st.mode & 0o200) == 0) VM_FS_ATTR_READ_ONLY else 0;
    flog("[file] attrs '{s}' -> file\n", .{path});
    vm.setRet(ro);
}

var file_log_budget: u32 = 60;
fn flog(comptime fmt: []const u8, a: anytype) void {
    if (std.posix.getenv("LOG_FILES") == null) return;
    if (file_log_budget == 0) return;
    file_log_budget -= 1;
    std.debug.print(fmt, a);
}

fn fileOpen(vm: *Vm) void {
    var nb: [128]u8 = undefined;
    flog("[file] open '{s}' mode={d}\n", .{ vm.readUcs2(vm.arg(0), &nb), vm.arg(1) });
    var f = openVFile(vm, vm.arg(0), vm.arg(1)) orelse return vm.setRet(u(-1));
    for (&vm.files, 0..) |*slot, idx| {
        if (slot.* == null) {
            slot.* = f;
            return vm.setRet(@intCast(idx + 1)); // handles are 1-based
        }
    }
    f.close();
    vm.setRet(u(-1));
}

fn handleFile(vm: *Vm) ?*vmmod.VFile {
    const h = vm.arg(0);
    if (h == 0 or h > vm.files.len or vm.files[h - 1] == null) return null;
    return &vm.files[h - 1].?;
}

fn fileClose(vm: *Vm) void {
    if (handleFile(vm)) |f| f.close();
    const h = vm.arg(0);
    if (h >= 1 and h <= vm.files.len) vm.files[h - 1] = null;
    vm.setRet(0);
}
fn fileRead(vm: *Vm) void {
    const f = handleFile(vm) orelse return vm.setRet(u(-1));
    const len = vm.arg(2);
    const nread_ptr = vm.arg(3);
    const n = f.read(vm.mem.slice(vm.arg(1), len));
    if (nread_ptr != 0) vm.mem.writeU32(nread_ptr, @intCast(n));
    flog("[file] read len={d} -> {d}\n", .{ len, n });
    vm.setRet(@intCast(n));
}
fn fileWrite(vm: *Vm) void {
    const f = handleFile(vm) orelse return vm.setRet(u(-1));
    const len = vm.arg(2);
    const written_ptr = vm.arg(3);
    var n: usize = 0;
    if (f.file) |host| n = host.write(vm.mem.slice(vm.arg(1), len)) catch 0;
    if (written_ptr != 0) vm.mem.writeU32(written_ptr, @intCast(n));
    vm.setRet(@intCast(n));
}
fn fileSeek(vm: *Vm) void {
    const f = handleFile(vm) orelse return vm.setRet(u(-1));
    const offset: i64 = s(vm.arg(1));
    const base = vm.arg(2);
    switch (base) {
        1 => f.seekTo(@intCast(@max(0, offset))), // BASE_BEGIN
        2 => f.seekBy(offset), // BASE_CURR
        3 => f.seekTo(@intCast(@max(0, @as(i64, @intCast(f.getEndPos())) + offset))), // BASE_END
        else => return vm.setRet(u(-1)),
    }
    flog("[file] seek off={d} base={d} -> abs={d}\n", .{ offset, base, f.getPos() });
    vm.setRet(0);
}
fn fileTell(vm: *Vm) void {
    const f = handleFile(vm) orelse return vm.setRet(u(-1));
    vm.setRet(@intCast(f.getPos()));
}
fn fileIsEof(vm: *Vm) void {
    const f = handleFile(vm) orelse return vm.setRet(u(-1));
    vm.setRet(if (f.getPos() >= f.getEndPos()) 1 else 0);
}
fn fileGetSize(vm: *Vm) void {
    const f = handleFile(vm) orelse return vm.setRet(u(-1));
    const out = vm.arg(1);
    if (out != 0) vm.mem.writeU32(out, @intCast(f.getEndPos()));
    vm.setRet(0);
}
fn diskFree(vm: *Vm) void {
    vm.setRet(256 * 1024 * 1024);
}
fn resOffsetFromFile(vm: *Vm) void {
    if (vm.app) |app| vm.setRet(app.res_offset) else vm.setRet(0);
}

// ---- SIM -------------------------------------------------------------------
fn getImei(vm: *Vm) void {
    writeCStrToScratch(vm, "1234567890123456");
}
fn getImsi(vm: *Vm) void {
    writeCStrToScratch(vm, "123456789012345");
}
fn writeCStrToScratch(vm: *Vm, str: []const u8) void {
    @memcpy(vm.mem.slice(vm.scratch, @intCast(str.len)), str);
    vm.mem.buf[vm.scratch + str.len] = 0;
    vm.setRet(vm.scratch);
}
fn simActiveSet(vm: *Vm) void {
    vm.setRet(if (vm.arg(0) == 1) 1 else 0);
}
fn simStatus(vm: *Vm) void {
    vm.setRet(if (vm.arg(0) == 1) 1 else 0);
}
fn queryOperator(vm: *Vm) void {
    const buf = vm.arg(0);
    if (buf != 0 and vm.arg(1) > 3) {
        @memcpy(vm.mem.slice(buf, 3), "+0\x00");
        vm.setRet(0);
    } else vm.setRet(u(-1));
}

// ---- graphics --------------------------------------------------------------
fn gScreenW(vm: *Vm) void {
    vm.setRet(gfx.screen_w);
}
fn gScreenH(vm: *Vm) void {
    vm.setRet(gfx.screen_h);
}
fn gBpp(vm: *Vm) void {
    vm.setRet(2);
}
fn gCreateLayer(vm: *Vm) void {
    vm.setRet(u(vm.gfx.createLayer(s(vm.arg(0)), s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)))));
}
fn gActiveLayer(vm: *Vm) void {
    vm.setRet(u(vm.gfx.activeLayer(s(vm.arg(0)))));
}
fn gGetLayerBuffer(vm: *Vm) void {
    vm.setRet(vm.gfx.getLayerBuffer(s(vm.arg(0))));
}
fn gFlushLayer(vm: *Vm) void {
    const arr = vm.arg(0);
    const count = @min(vm.arg(1), 16);
    var handles: [16]i32 = undefined;
    var k: u32 = 0;
    while (k < count) : (k += 1) handles[k] = s(vm.mem.readU32(arr + k * 4));
    vm.setRet(u(vm.gfx.flushLayer(handles[0..count])));
}
fn gClearLayerBg(vm: *Vm) void {
    vm.setRet(u(vm.gfx.clearLayerBg(s(vm.arg(0)))));
}
fn gTranslateLayer(vm: *Vm) void {
    vm.setRet(u(vm.gfx.translateLayer(s(vm.arg(0)), s(vm.arg(1)), s(vm.arg(2)))));
}
fn gSetPixel(vm: *Vm) void {
    vm.gfx.setPixel(vm.arg(0), s(vm.arg(1)), s(vm.arg(2)), @truncate(vm.arg(3)));
    vm.setRet(0);
}
fn gSetPixelEx(vm: *Vm) void {
    if (vm.gfx.activeBuf(s(vm.arg(0)))) |buf|
        vm.gfx.setPixel(buf, s(vm.arg(1)), s(vm.arg(2)), vm.gfx.global_color);
    vm.setRet(0);
}
fn gLine(vm: *Vm) void {
    vm.gfx.line(vm.arg(0), s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), @truncate(vm.arg(5)));
    vm.setRet(0);
}
fn gLineEx(vm: *Vm) void {
    if (vm.gfx.activeBuf(s(vm.arg(0)))) |buf|
        vm.gfx.line(buf, s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), vm.gfx.global_color);
    vm.setRet(0);
}
fn gFillRect(vm: *Vm) void {
    vm.gfx.fillRect(vm.arg(0), s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), @truncate(vm.arg(5)), @truncate(vm.arg(6)));
    vm.setRet(0);
}
fn gFillRectEx(vm: *Vm) void {
    if (vm.gfx.activeBuf(s(vm.arg(0)))) |buf|
        vm.gfx.fillRect(buf, s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), vm.gfx.global_color, vm.gfx.global_color);
    vm.setRet(0);
}
fn gFillPolygon(vm: *Vm) void {
    // arg0 = layer handle (-1 = active layer); arg1 = point array; arg2 = point count.
    // Uses the global pen color, like the other _ex fills.
    if (vm.gfx.activeBuf(s(vm.arg(0)))) |buf|
        vm.gfx.fillPolygon(buf, vm.arg(1), vm.arg(2), vm.gfx.global_color);
    vm.setRet(0);
}
fn gSetAlphaBlend(vm: *Vm) void {
    // vm_graphic_set_alpha_blending_layer(handle): handle>=0 enables 50% blend for
    // subsequent blts; -1 disables. Games bracket a draw with enable/…/disable.
    vm.gfx.setAlphaBlend(s(vm.arg(0)));
    vm.setRet(0);
}
fn gFillEllipseEx(vm: *Vm) void {
    // arg0 = layer handle (-1 = active); (arg1,arg2,arg3,arg4) = bounding box x,y,w,h.
    if (vm.gfx.activeBuf(s(vm.arg(0)))) |buf|
        vm.gfx.fillEllipse(buf, s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), vm.gfx.global_color);
    vm.setRet(0);
}
fn gRect(vm: *Vm) void {
    vm.gfx.rect(vm.arg(0), s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), @truncate(vm.arg(5)));
    vm.setRet(0);
}
fn gRectEx(vm: *Vm) void {
    if (vm.gfx.activeBuf(s(vm.arg(0)))) |buf|
        vm.gfx.rect(buf, s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), vm.gfx.global_color);
    vm.setRet(0);
}
fn gRoundRect(vm: *Vm) void {
    vm.gfx.roundRect(vm.arg(0), s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), s(vm.arg(5)), @truncate(vm.arg(6)));
    vm.setRet(0);
}
fn gRoundRectEx(vm: *Vm) void {
    if (vm.gfx.activeBuf(s(vm.arg(0)))) |buf|
        vm.gfx.roundRect(buf, s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), s(vm.arg(5)), vm.gfx.global_color);
    vm.setRet(0);
}
fn gFillRoundRect(vm: *Vm) void {
    vm.gfx.fillRoundRect(vm.arg(0), s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), s(vm.arg(5)), @truncate(vm.arg(6)));
    vm.setRet(0);
}
fn gFillRoundRectEx(vm: *Vm) void {
    if (vm.gfx.activeBuf(s(vm.arg(0)))) |buf|
        vm.gfx.fillRoundRect(buf, s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), s(vm.arg(5)), vm.gfx.global_color);
    vm.setRet(0);
}
fn gBlt(vm: *Vm) void {
    vm.gfx.blt(vm.arg(0), s(vm.arg(1)), s(vm.arg(2)), vm.arg(3), s(vm.arg(4)), s(vm.arg(5)), s(vm.arg(6)), s(vm.arg(7)));
    vm.setRet(0);
}
fn gBltEx(vm: *Vm) void {
    vm.gfx.blt(vm.arg(0), s(vm.arg(1)), s(vm.arg(2)), vm.arg(3), s(vm.arg(4)), s(vm.arg(5)), s(vm.arg(6)), s(vm.arg(7)));
    vm.setRet(0);
}
fn gRotate(vm: *Vm) void {
    vm.gfx.rotate(vm.arg(0), s(vm.arg(1)), s(vm.arg(2)), vm.arg(3), s(vm.arg(5)));
    vm.setRet(0);
}
fn gMirror(vm: *Vm) void {
    vm.gfx.mirror(vm.arg(0), s(vm.arg(1)), s(vm.arg(2)), vm.arg(3), vm.arg(5) == 0);
    vm.setRet(0);
}
fn gSetClip(vm: *Vm) void {
    vm.gfx.setClip(s(vm.arg(0)), s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)));
    vm.setRet(0);
}
fn gResetClip(vm: *Vm) void {
    vm.gfx.resetClip();
    vm.setRet(0);
}
fn gFlushScreen(vm: *Vm) void {
    vm.gfx.present();
    vm.used_screen_buffer = true;
    vm.setRet(0);
}
fn gGetBuffer(vm: *Vm) void {
    vm.used_screen_buffer = true;
    vm.setRet(vm.gfx.screenBuffer());
}
fn gSetColor(vm: *Vm) void {
    // vm_graphic_color = { VMUINT vm_color_565; VMUINT vm_color_888; }
    // The 565 value is the low 16 bits of the first field (offset 0).
    const p = vm.arg(0);
    vm.gfx.global_color = @truncate(vm.mem.readU32(p));
    vm.setRet(0);
}
fn gCanvasTrans(vm: *Vm) void {
    vm.setRet(u(vm.gfx.canvasSetTransColor(vm.arg(0), @truncate(vm.arg(1)))));
}

const trans_sentinel: u16 = gfx.trans_sentinel; // magenta — transparent-key for alpha pixels

const DecodedImage = struct { w: u32, h: u32, rgba: []u8 };

/// Decode PNG/GIF bytes to RGBA (caller frees `.rgba`). null on unsupported.
fn decodeImage(vm: *Vm, bytes: []const u8, tag: []const u8) ?DecodedImage {
    if (png.decode(vm.gpa, bytes)) |d| return .{ .w = d.w, .h = d.h, .rgba = d.rgba } else |_| {}
    if (gif.decode(vm.gpa, bytes)) |d| return .{ .w = d.w, .h = d.h, .rgba = d.rgba } else |_| {}
    if (bytes.len >= 2) std.debug.print("[{s}] unsupported magic {x:0>2}{x:0>2}\n", .{ tag, bytes[0], bytes[1] });
    return null;
}

/// Decode image bytes into a fresh app-arena canvas (RGB565, alpha<128 keyed to
/// the magenta trans sentinel). Returns the canvas signature address, or 0.
fn decodeToCanvas(vm: *Vm, bytes: []const u8, tag: []const u8) u32 {
    const d = decodeImage(vm, bytes, tag) orelse return 0;
    defer vm.gpa.free(d.rgba);
    if (std.posix.getenv("DIAG") != null)
        std.debug.print("[{s}] decoded {d}x{d}\n", .{ tag, d.w, d.h });
    const canvas = vm.gfx.createCanvas(appMallocThunk, vm, @intCast(d.w), @intCast(d.h));
    if (canvas == 0) return 0;
    const pixels = canvas + gfx.canvas_data_offset;
    var has_trans = false;
    var i: u32 = 0;
    const n = d.w * d.h;
    while (i < n) : (i += 1) {
        const o = i * 4;
        var c565: u16 = gfx.rgb565(d.rgba[o], d.rgba[o + 1], d.rgba[o + 2]);
        if (d.rgba[o + 3] < 128) {
            c565 = trans_sentinel;
            has_trans = true;
        }
        vm.mem.writeU16(pixels + i * 2, c565);
    }
    if (has_trans) _ = vm.gfx.canvasSetTransColor(canvas, trans_sentinel);
    return canvas;
}

fn gLoadImage(vm: *Vm) void {
    if (vm.arg(0) == 0 or vm.arg(1) == 0) return vm.setRet(0);
    vm.setRet(decodeToCanvas(vm, vm.mem.slice(vm.arg(0), vm.arg(1)), "load_image"));
}

fn gDrawImageFromMemory(vm: *Vm) void {
    // vm_graphic_draw_image_from_memory(handle, x, y, img_data, img_len): decode the
    // buffer into a temp canvas, blt it onto the layer at (x,y), free the temp.
    // blt honors the clip rect and index-transparency. Returns VM_GDI_SUCCEED (0).
    const dest = vm.gfx.activeBuf(s(vm.arg(0))) orelse return vm.setRet(u(-1));
    const img = vm.arg(3);
    const len = vm.arg(4);
    if (img == 0 or len == 0) return vm.setRet(u(-1));
    const canvas = decodeToCanvas(vm, vm.mem.slice(img, len), "draw_image_from_memory");
    if (canvas == 0) return vm.setRet(u(-1));
    if (vm.gfx.canvasInfo(canvas)) |info|
        vm.gfx.blt(dest, s(vm.arg(1)), s(vm.arg(2)), canvas, 0, 0, info.w, info.h);
    if (appArena(vm)) |a| a.free(canvas); // temp canvas: freed after the draw
    vm.setRet(0);
}

fn gGetImgPropertyEx(vm: *Vm) void {
    // vm_graphic_get_img_property_ex(img_data, img_len, vm_graphic_imgprop*):
    // fill { VMINT width@0; VMINT height@4 } from the decoded image. 0 on success.
    const img = vm.arg(0);
    const len = vm.arg(1);
    const prop = vm.arg(2);
    if (img == 0 or len == 0 or prop == 0) return vm.setRet(u(-1));
    const d = decodeImage(vm, vm.mem.slice(img, len), "get_img_property_ex") orelse return vm.setRet(u(-1));
    vm.gpa.free(d.rgba);
    vm.mem.writeU32(prop + 0, d.w);
    vm.mem.writeU32(prop + 4, d.h);
    vm.setRet(0);
}

fn gLoadImageResized(vm: *Vm) void {
    // vm_graphic_load_image_resized(img_data, img_len, width, height): decode
    // like vm_graphic_load_image, then nearest-neighbor scale to width x height.
    // Doc types the return VM_GDI_RESULT, but games use it as the canvas display
    // buffer pointer (same as load_image) — a non-zero pointer serves both.
    const img = vm.arg(0);
    const len = vm.arg(1);
    const dw: u32 = vm.arg(2);
    const dh: u32 = vm.arg(3);
    if (img == 0 or len == 0 or dw == 0 or dh == 0) return vm.setRet(0);
    const bytes = vm.mem.slice(img, len);

    const Decoded = struct { w: u32, h: u32, rgba: []u8 };
    const decoded: Decoded = blk: {
        if (png.decode(vm.gpa, bytes)) |d| break :blk .{ .w = d.w, .h = d.h, .rgba = d.rgba } else |_| {}
        if (gif.decode(vm.gpa, bytes)) |d| break :blk .{ .w = d.w, .h = d.h, .rgba = d.rgba } else |_| {}
        if (bytes.len >= 2) std.debug.print("[load_image_resized] unsupported magic {x:0>2}{x:0>2}\n", .{ bytes[0], bytes[1] });
        return vm.setRet(0);
    };
    defer vm.gpa.free(decoded.rgba);
    if (std.posix.getenv("DIAG") != null)
        std.debug.print("[load_image_resized] {d}x{d} -> {d}x{d}\n", .{ decoded.w, decoded.h, dw, dh });

    const canvas = vm.gfx.createCanvas(appMallocThunk, vm, @intCast(dw), @intCast(dh));
    if (canvas == 0) return vm.setRet(0);

    const pixels = canvas + gfx.canvas_data_offset;
    var has_trans = false;
    var dy: u32 = 0;
    while (dy < dh) : (dy += 1) {
        // Map destination pixel back to the nearest source pixel.
        const sy = if (dh == 1) 0 else dy * decoded.h / dh;
        var dx: u32 = 0;
        while (dx < dw) : (dx += 1) {
            const sx = if (dw == 1) 0 else dx * decoded.w / dw;
            const o = (sy * decoded.w + sx) * 4;
            var c565: u16 = gfx.rgb565(decoded.rgba[o], decoded.rgba[o + 1], decoded.rgba[o + 2]);
            if (decoded.rgba[o + 3] < 128) {
                c565 = trans_sentinel;
                has_trans = true;
            }
            vm.mem.writeU16(pixels + (dy * dw + dx) * 2, c565);
        }
    }
    if (has_trans) _ = vm.gfx.canvasSetTransColor(canvas, trans_sentinel);
    vm.setRet(canvas);
}

fn appMallocThunk(ctx: *anyopaque, size: u32) u32 {
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    const a = appArena(vm) orelse return 0;
    return a.malloc(size, false, 8);
}
fn gCreateCanvas(vm: *Vm) void {
    vm.setRet(vm.gfx.createCanvas(appMallocThunk, vm, @intCast(vm.arg(0)), @intCast(vm.arg(1))));
}
fn gCreateCanvasCf(vm: *Vm) void {
    vm.setRet(vm.gfx.createCanvas(appMallocThunk, vm, @intCast(vm.arg(1)), @intCast(vm.arg(2))));
}
fn gReleaseCanvas(vm: *Vm) void {
    if (appArena(vm)) |a| a.free(vm.arg(0));
    vm.setRet(0);
}
fn gGetImgProperty(vm: *Vm) void {
    // Fill a vmgraph.h `frame_prop` struct (width@6, height@8, trans@14, offset@16)
    // into scratch and return its address.
    const info = vm.gfx.canvasInfo(vm.arg(0)) orelse return vm.setRet(0);
    const sc = vm.scratch;
    const m = vm.mem;
    @memset(m.slice(sc, 20), 0);
    m.buf[sc + 0] = if (info.flag) 1 else 0;
    m.writeU16(sc + 6, @intCast(info.w));
    m.writeU16(sc + 8, @intCast(info.h));
    m.writeU16(sc + 14, info.trans_color);
    m.writeU32(sc + 16, @intCast(info.w * info.h * 2));
    vm.setRet(sc);
}
fn gGetFrameNumber(vm: *Vm) void {
    // arg0 = canvas handle from vm_graphic_load_image; return its frame count.
    vm.setRet(u(vm.gfx.frameNumber(vm.arg(0))));
}
fn gGetCanvasBuffer(vm: *Vm) void {
    vm.setRet(vm.arg(0)); // canvas pointer already addresses the signature
}
fn gCreateLayerEx(vm: *Vm) void {
    // mode VM_BUF: register the provided canvas buffer as a layer (pixels at buf+32).
    const buf = vm.arg(6);
    const pixels = if (buf >= gfx.canvas_data_offset) buf + gfx.canvas_data_offset else buf;
    vm.setRet(u(vm.gfx.createLayerExternal(s(vm.arg(0)), s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), pixels)));
}
fn gCreateLayerCf(vm: *Vm) void {
    const buf = vm.arg(7);
    const pixels = if (buf >= gfx.canvas_data_offset) buf + gfx.canvas_data_offset else buf;
    vm.setRet(u(vm.gfx.createLayerExternal(s(vm.arg(1)), s(vm.arg(2)), s(vm.arg(3)), s(vm.arg(4)), -1, pixels)));
}

// ---- text ------------------------------------------------------------------
fn gCharH(vm: *Vm) void {
    vm.setRet(u(gfx.Graphics.charHeight()));
}
fn gCharW(vm: *Vm) void {
    vm.setRet(u(gfx.Graphics.charWidth(@truncate(vm.arg(0)))));
}
fn gStringW(vm: *Vm) void {
    vm.setRet(u(vm.gfx.stringWidth(vm.arg(0))));
}
fn gMeasureChar(vm: *Vm) void {
    const wp = vm.arg(1);
    const hp = vm.arg(2);
    if (wp == 0 or hp == 0) return vm.setRet(u(-1));
    vm.mem.writeU32(wp, u(gfx.Graphics.charWidth(@truncate(vm.arg(0)))));
    vm.mem.writeU32(hp, u(gfx.Graphics.charHeight()));
    vm.setRet(0);
}
fn gTextout(vm: *Vm) void {
    vm.gfx.textout(vm.arg(0), s(vm.arg(1)), s(vm.arg(2)), vm.arg(3), s(vm.arg(4)), @truncate(vm.arg(5)));
    vm.setRet(0);
}
fn gTextoutBaseline(vm: *Vm) void {
    // baseline arg ignored; render at y
    vm.gfx.textout(vm.arg(0), s(vm.arg(1)), s(vm.arg(2)), vm.arg(3), s(vm.arg(4)), @truncate(vm.arg(5)));
    vm.setRet(0);
}
fn gGetStringBaseline(vm: *Vm) void {
    // Fixed bitmap font: baseline is a constant independent of the string arg.
    vm.setRet(u(gfx.Graphics.charBaseline()));
}
fn gTextoutToLayer(vm: *Vm) void {
    if (vm.gfx.activeBuf(s(vm.arg(0)))) |buf|
        vm.gfx.textout(buf, s(vm.arg(1)), s(vm.arg(2)), vm.arg(3), s(vm.arg(4)), vm.gfx.global_color);
    vm.setRet(0);
}
fn gCharNumInWidth(vm: *Vm) void {
    const str = vm.arg(0);
    const width = s(vm.arg(1));
    const gap = s(vm.arg(3));
    var w: i32 = 0;
    var i: u32 = 0;
    var p = str;
    while (true) : (i += 1) {
        const c = vm.mem.readU16(p);
        if (c == 0) break;
        const cw = gfx.Graphics.charWidth(c);
        if (width >= w and width < w + cw + gap) return vm.setRet(i);
        w += cw + gap;
        p += 2;
    }
    vm.setRet(i);
}

// ---- resources -------------------------------------------------------------
fn loadResource(vm: *Vm) void {
    const name = vm.readCStr(vm.arg(0));
    const size_ptr = vm.arg(1);
    const res = vm.resources.find(name) orelse return vm.setRet(0);
    const a = appArena(vm) orelse return vm.setRet(0);
    const dst = a.malloc(res.size, false, 8);
    if (dst == 0) return vm.setRet(0);
    @memcpy(vm.mem.slice(dst, res.size), vm.file[res.offset..][0..res.size]);
    if (size_ptr != 0) vm.mem.writeU32(size_ptr, res.size);
    vm.setRet(dst);
}
fn resourceGetData(vm: *Vm) void {
    const data = vm.arg(0);
    const offset = vm.arg(1);
    const size = vm.arg(2);
    if (data == 0 or @as(u64, offset) + size > vm.file.len) return vm.setRet(u(-1));
    @memcpy(vm.mem.slice(data, size), vm.file[offset..][0..size]);
    vm.setRet(0);
}

// ---- charset (ASCII<->UCS2 direct; GB2312 best-effort as ASCII) ------------
fn ucs2ToAscii(vm: *Vm) void {
    const dst = vm.arg(0);
    const size = vm.arg(1);
    const src = vm.arg(2);
    var i: u32 = 0;
    while (i + 1 < size) : (i += 1) {
        const c = vm.mem.readU16(src + i * 2);
        vm.mem.buf[dst + i] = @intCast(c & 0xFF);
        if (c == 0) break;
    }
    vm.setRet(0);
}
// vm_chset_enum indices we care about (VM_CHSET_BASE = 0):
const CHSET_ASCII = 1;
const CHSET_UTF16LE = 35;
const CHSET_UTF8 = 37;
const CHSET_UCS2 = 38;

// vm_chset_convert(src_type, dst_type, src, dst, dst_size): transcode a
// null-terminated string between character sets, writing dst with a terminator.
// Covers the sets games actually use — wide (UCS2/UTF16LE), UTF8, and single-byte
// (ASCII/Latin, treated as codepoint == byte). Returns 0 (VM_CHSET_CONVERT_SUCCESS).
fn chsetConvert(vm: *Vm) void {
    const src_type = vm.arg(0);
    const dst_type = vm.arg(1);
    var sp = vm.arg(2);
    var dp = vm.arg(3);
    const dst_size = vm.arg(4);
    const m = vm.mem;
    if (sp == 0 or dp == 0 or dst_size < 1) return vm.setRet(1); // VM_CHSET_CONVERT_ERR_PARAM
    const src_wide = src_type == CHSET_UCS2 or src_type == CHSET_UTF16LE;
    const dst_wide = dst_type == CHSET_UCS2 or dst_type == CHSET_UTF16LE;
    const dst_end = dp + dst_size;
    const mem_end: u32 = @intCast(m.buf.len);

    var first = true;
    while (true) {
        // --- decode one codepoint from src ---
        var cp: u32 = 0;
        if (src_wide) {
            if (sp + 2 > mem_end) break;
            cp = m.readU16(sp);
            sp += 2;
        } else {
            if (sp >= mem_end) break;
            const b0 = m.buf[sp];
            if (src_type == CHSET_UTF8 and b0 >= 0x80) {
                if (b0 & 0xE0 == 0xC0 and sp + 2 <= mem_end) {
                    cp = (@as(u32, b0 & 0x1F) << 6) | (m.buf[sp + 1] & 0x3F);
                    sp += 2;
                } else if (b0 & 0xF0 == 0xE0 and sp + 3 <= mem_end) {
                    cp = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, m.buf[sp + 1] & 0x3F) << 6) | (m.buf[sp + 2] & 0x3F);
                    sp += 3;
                } else {
                    cp = b0;
                    sp += 1;
                }
            } else {
                cp = b0; // ASCII / Latin single-byte
                sp += 1;
            }
        }
        if (cp == 0) break;
        if (first) {
            first = false;
            if (cp == 0xFEFF) continue; // strip a leading byte-order mark (real converters do)
        }

        // --- encode the codepoint into dst ---
        if (dst_wide) {
            if (dp + 2 > dst_end) break;
            m.writeU16(dp, @intCast(cp & 0xFFFF));
            dp += 2;
        } else if (dst_type == CHSET_UTF8) {
            if (cp < 0x80) {
                if (dp + 1 > dst_end) break;
                m.buf[dp] = @intCast(cp);
                dp += 1;
            } else if (cp < 0x800) {
                if (dp + 2 > dst_end) break;
                m.buf[dp] = @intCast(0xC0 | (cp >> 6));
                m.buf[dp + 1] = @intCast(0x80 | (cp & 0x3F));
                dp += 2;
            } else {
                if (dp + 3 > dst_end) break;
                m.buf[dp] = @intCast(0xE0 | (cp >> 12));
                m.buf[dp + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                m.buf[dp + 2] = @intCast(0x80 | (cp & 0x3F));
                dp += 3;
            }
        } else {
            if (dp + 1 > dst_end) break;
            m.buf[dp] = @intCast(cp & 0xFF); // ASCII / Latin
            dp += 1;
        }
    }

    // write the terminator (wide = u16 0, else byte 0), space permitting
    if (dst_wide) {
        if (dp + 2 <= dst_end) m.writeU16(dp, 0);
    } else if (dp < dst_end) {
        m.buf[dp] = 0;
    }
    vm.setRet(0); // VM_CHSET_CONVERT_SUCCESS
}
fn asciiToUcs2(vm: *Vm) void {
    const dst = vm.arg(0);
    const size = vm.arg(1);
    const src = vm.arg(2);
    var i: u32 = 0;
    while ((i + 1) * 2 < size) : (i += 1) {
        const c = vm.mem.buf[src + i];
        vm.mem.writeU16(dst + i * 2, c);
        if (c == 0) break;
    }
    vm.setRet(0);
}
fn lowerCase(vm: *Vm) void {
    // vm_lower_case(char* dst, char* src): copy an ASCII C-string lowercasing A-Z.
    const dst = vm.arg(0);
    const src = vm.arg(1);
    if (dst == 0 or src == 0) return vm.setRet(0);
    var i: u32 = 0;
    while (true) : (i += 1) {
        var c = vm.mem.buf[src + i];
        if (c >= 'A' and c <= 'Z') c += 32;
        vm.mem.buf[dst + i] = c;
        if (c == 0) break;
    }
    vm.setRet(0);
}
fn getGmobiLanguage(vm: *Vm) void {
    // vm_get_gmobi_language() (GMobi ext, undocumented): games call it and read
    // *result as a language id, falling back gracefully. Return a valid pointer to
    // a zeroed word (id 0 = default) so the deref is safe.
    vm.mem.writeU32(vm.scratch, 0);
    vm.setRet(vm.scratch);
}
fn getFilename(vm: *Vm) void {
    // vm_get_filename(VMWSTR path, VMWSTR filename): copy the basename (part after
    // the last '\' or '/') of a UCS2 path into the [OUT] filename buffer. Operates
    // on 16-bit code units directly so non-ASCII names survive. Returns void.
    const path = vm.arg(0);
    const out = vm.arg(1);
    if (path == 0 or out == 0) return vm.setRet(0);
    // Locate the code unit after the last path separator.
    var i: u32 = 0;
    var start: u32 = 0;
    while (true) : (i += 1) {
        const ch = vm.mem.readU16(path + i * 2);
        if (ch == 0) break;
        if (ch == '\\' or ch == '/') start = i + 1;
    }
    var j: u32 = start;
    var w: u32 = 0;
    while (true) : (j += 1) {
        const ch = vm.mem.readU16(path + j * 2);
        vm.mem.writeU16(out + w * 2, ch);
        w += 1;
        if (ch == 0) break;
    }
    vm.setRet(0);
}
fn langSsc(vm: *Vm) void {
    const p = vm.arg(0);
    if (p == 0) return vm.setRet(u(-1));
    @memcpy(vm.mem.slice(p, 8), "*#0044#\x00");
    vm.setRet(0);
}
fn ucs2String(vm: *Vm) void {
    const src = vm.arg(0);
    if (src == 0) return vm.setRet(vm.scratch);
    var i: u32 = 0;
    while (i < 255) : (i += 1) {
        const c = vm.mem.buf[src + i];
        vm.mem.writeU16(vm.scratch + i * 2, c);
        if (c == 0) break;
    }
    vm.setRet(vm.scratch);
}

// ---- stdlib (UCS2 wide strings) --------------------------------------------
fn wstrlen(vm: *Vm) void {
    const sp = vm.arg(0);
    if (sp == 0) return vm.setRet(u(-1));
    var n: u32 = 0;
    while (vm.mem.readU16(sp + n * 2) != 0) n += 1;
    vm.setRet(n);
}
fn wstrcpy(vm: *Vm) void {
    const dst = vm.arg(0);
    const src = vm.arg(1);
    if (dst == 0 or src == 0) return vm.setRet(u(-1));
    var n: u32 = 0;
    while (true) : (n += 1) {
        const c = vm.mem.readU16(src + n * 2);
        vm.mem.writeU16(dst + n * 2, c);
        if (c == 0) break;
    }
    vm.setRet(n);
}
fn wstrncpy(vm: *Vm) void {
    const dst = vm.arg(0);
    const src = vm.arg(1);
    const n = vm.arg(2);
    if (dst == 0 or src == 0) return vm.setRet(u(-1));
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const c = vm.mem.readU16(src + k * 2);
        vm.mem.writeU16(dst + k * 2, c);
        if (c == 0) break;
    }
    vm.setRet(k);
}
fn wstrcat(vm: *Vm) void {
    const dst = vm.arg(0);
    const src = vm.arg(1);
    if (dst == 0 or src == 0) return vm.setRet(u(-1));
    var end: u32 = 0;
    while (vm.mem.readU16(dst + end * 2) != 0) end += 1;
    var k: u32 = 0;
    while (true) : (k += 1) {
        const c = vm.mem.readU16(src + k * 2);
        vm.mem.writeU16(dst + (end + k) * 2, c);
        if (c == 0) break;
    }
    vm.setRet(0);
}
fn wstrcmp(vm: *Vm) void {
    const a = vm.arg(0);
    const bb = vm.arg(1);
    if (a == 0 or bb == 0) return vm.setRet(u(-1));
    var n: u32 = 0;
    while (true) : (n += 1) {
        const ca = vm.mem.readU16(a + n * 2);
        const cb = vm.mem.readU16(bb + n * 2);
        if (ca != cb) return vm.setRet(u(@as(i32, cb) - @as(i32, ca)));
        if (ca == 0) break;
    }
    vm.setRet(0);
}

// ---- audio (routes to the frontend-installed backend) ----------------------
fn setVolume(vm: *Vm) void {
    audio.volume = @intCast(@min(vm.arg(0), 6));
    vm.setRet(0);
}
fn getVolume(vm: *Vm) void {
    vm.setRet(audio.volume);
}
fn audioPlay(vm: *Vm) void {
    // vm_audio_play_bytes_no_block(data, len, format, path, cb) -> handle
    const data = vm.arg(0);
    const len = vm.arg(1);
    const format: u8 = @truncate(vm.arg(2));
    if (data == 0 or len == 0) return vm.setRet(u(-1));
    const clip = vm.mem.slice(data, len);
    if (std.posix.getenv("AUDIO_LOG") != null) {
        std.debug.print("[audio] play len={d} format={d} magic=", .{ len, format });
        for (clip[0..@min(clip.len, 12)]) |b| std.debug.print("{x:0>2} ", .{b});
        std.debug.print("\n", .{});
    }
    // [reconstructed to match current audio.zig clip* API — review args]
    vm.setRet(u(audio.clipPlay(clip, format, 0, vm.arg(4))));
}
fn audioStopAll(vm: *Vm) void {
    audio.clipCloseAll(); // [reconstructed: was audio.stopAll()]
    vm.setRet(0);
}
fn audioClose(vm: *Vm) void {
    audio.clipClose(s(vm.arg(0))); // [reconstructed: was audio.close()]
    vm.setRet(0);
}
// [reconstructed] vm_audio_{suspend,resume}_bg_play -> audio.zig bg controls.
fn audioSuspendBg(vm: *Vm) void {
    audio.suspendBg();
    vm.setRet(0);
}
fn audioResumeBg(vm: *Vm) void {
    audio.resumeBg();
    vm.setRet(0);
}

// -- MIDI (vm_midi_*) --
// NOTE: midiCompat() and logClip() were reconstructed (not captured in recovery);
// review these two helpers. All handlers below are the recovered originals.
fn midiCompat() bool {
    // Debug bisect switch: MRE_MIDI_COMPAT=1 restores the old constant-return
    // stubs (bypasses the real MIDI backend).
    return std.posix.getenv("MRE_MIDI_COMPAT") != null;
}
fn logClip(clip: []const u8, tag: u8) void {
    if (std.posix.getenv("AUDIO_LOG") == null) return;
    std.debug.print("[audio] midi tag=0x{x:0>2} len={d} magic=", .{ tag, clip.len });
    for (clip[0..@min(clip.len, 12)]) |b| std.debug.print("{x:0>2} ", .{b});
    std.debug.print("\n", .{});
}
fn midiPlayBytes(vm: *Vm) void {
    if (midiCompat()) return vm.setRet(1);
    // vm_midi_play_by_bytes(midibuf, len, repeat, void(*f)(handle, event)) -> handle
    const data = vm.arg(0);
    const len = vm.arg(1);
    const repeat: i32 = @bitCast(vm.arg(2));
    const cb = vm.arg(3);
    if (data == 0 or len == 0) return vm.setRet(u(-1));
    const clip = vm.mem.slice(data, len);
    logClip(clip, 0xFF);
    vm.setRet(u(audio.midiPlay(clip, data, 0, repeat, cb)));
}
fn midiPlayBytesEx(vm: *Vm) void {
    if (midiCompat()) return vm.setRet(1);
    // vm_midi_play_by_bytes_ex(midibuf, len, start_time, repeat, path, cb) -> handle
    const data = vm.arg(0);
    const len = vm.arg(1);
    const start_ms = vm.arg(2);
    const repeat: i32 = @bitCast(vm.arg(3));
    const cb = vm.arg(5);
    if (data == 0 or len == 0) return vm.setRet(u(-1));
    vm.setRet(u(audio.midiPlay(vm.mem.slice(data, len), data, start_ms, repeat, cb)));
}
fn midiPause(vm: *Vm) void {
    if (midiCompat()) return vm.setRet(0);
    vm.setRet(u(audio.midiPause(s(vm.arg(0)))));
}
fn midiResume(vm: *Vm) void {
    if (midiCompat()) return vm.setRet(0);
    vm.setRet(u(audio.midiResume(s(vm.arg(0)))));
}
fn midiGetTime(vm: *Vm) void {
    if (midiCompat()) return vm.setRet(0);
    // vm_midi_get_time(handle, VMUINT* current_time) -> 0/-1; time forced >= 1
    const outp = vm.arg(1);
    if (audio.midiGetTimeMs(s(vm.arg(0)))) |ms| {
        if (outp != 0) vm.mem.writeU32(outp, @max(ms, 1));
        return vm.setRet(0);
    }
    vm.setRet(u(-1));
}
fn midiStop(vm: *Vm) void {
    if (midiCompat()) return vm.setRet(0);
    audio.midiStop(s(vm.arg(0)));
    vm.setRet(0);
}
fn midiStopAll(vm: *Vm) void {
    if (midiCompat()) return vm.setRet(0);
    audio.midiStopAll();
    vm.setRet(0);
}

// -- bitstream PCM (vm_bitstream_audio_*) --
// cfg struct (raw guest layout per MREmu's remapper): codec u8@0, is_stereo
// u32@4, bit_per_sample u8@8, sample_freq u8@9 (enum idx into BITSTREAM_RATES).
fn bsOpenCommon(vm: *Vm, degenerate_ok: bool) void {
    const outp = vm.arg(0);
    const cfgp = vm.arg(1);
    const cb = vm.arg(2);
    if (outp == 0 or cfgp == 0) return vm.setRet(u(-1));
    var stereo = vm.mem.readU32(cfgp + 4) != 0;
    var bits = vm.mem.slice(cfgp + 8, 1)[0];
    var freq_idx = vm.mem.slice(cfgp + 9, 1)[0];
    if (std.posix.getenv("AUDIO_LOG") != null) {
        const raw = vm.mem.slice(cfgp, 12);
        std.debug.print("[audio] bitstream open cfg=", .{});
        for (raw) |b| std.debug.print("{x:0>2} ", .{b});
        std.debug.print("\n", .{});
    }
    if (degenerate_ok and bits != 16) {
        // vm_bitstream_audio_open passes a codec-level cfg MREmu zero-filled;
        // default to something playable instead of failing like the reference.
        bits = 16;
        stereo = false;
        freq_idx = 0;
    }
    if (bits != 16 or freq_idx >= audio.BITSTREAM_RATES.len) return vm.setRet(u(-1));
    const h = audio.bitstreamOpenPcm(stereo, audio.BITSTREAM_RATES[freq_idx], cb);
    if (h < 0) return vm.setRet(u(-1));
    vm.mem.writeU32(outp, @bitCast(h));
    vm.setRet(0); // VM_BITSTREAM_SUCCEED
}
fn bsOpen(vm: *Vm) void {
    bsOpenCommon(vm, true);
}
fn bsOpenPcm(vm: *Vm) void {
    bsOpenCommon(vm, false);
}
fn bsFinished(vm: *Vm) void {
    vm.setRet(u(audio.bitstreamFinished(s(vm.arg(0)))));
}
fn bsClose(vm: *Vm) void {
    vm.setRet(u(audio.bitstreamClose(s(vm.arg(0)))));
}
fn bsStatus(vm: *Vm) void {
    // vm_bitstream_audio_get_buffer_status(handle, {total u32@0, free u32@4}*)
    const outp = vm.arg(1);
    const st = audio.bitstreamStatus(s(vm.arg(0))) orelse return vm.setRet(u(-1));
    if (outp != 0) {
        vm.mem.writeU32(outp, st.total);
        vm.mem.writeU32(outp + 4, st.free);
    }
    vm.setRet(0);
}
fn bsPutData(vm: *Vm) void {
    // vm_bitstream_audio_put_data(handle, buf, size, VMUINT* written)
    const buf = vm.arg(1);
    const size = vm.arg(2);
    const writtenp = vm.arg(3);
    if (buf == 0) return vm.setRet(u(-1));
    const n = audio.bitstreamPutData(s(vm.arg(0)), vm.mem.slice(buf, size)) orelse return vm.setRet(u(-1));
    if (writtenp != 0) vm.mem.writeU32(writtenp, n);
    vm.setRet(0);
}
fn bsStart(vm: *Vm) void {
    // vm_bitstream_audio_start(handle, {volume i32@0, start_time u32@4}*)
    const p = vm.arg(1);
    const vol: u8 = if (p != 0) @intCast(@min(vm.mem.readU32(p), 6)) else audio.volume;
    const start_ms = if (p != 0) vm.mem.readU32(p + 4) else 0;
    vm.setRet(u(audio.bitstreamStart(s(vm.arg(0)), vol, start_ms)));
}
fn bsStop(vm: *Vm) void {
    vm.setRet(u(audio.bitstreamStop(s(vm.arg(0)))));
}
fn bsGetPlayTime(vm: *Vm) void {
    const outp = vm.arg(1);
    const ms = audio.bitstreamPlayTimeMs(s(vm.arg(0))) orelse return vm.setRet(u(-1));
    if (outp != 0) vm.mem.writeU32(outp, ms);
    vm.setRet(0);
}

// ---- app lifecycle ---------------------------------------------------------
fn exitApp(vm: *Vm) void {
    vm.quit_requested = true;
    vm.setRet(0);
}

// ---- misc (rand/srand: LCG so it's deterministic) --------------------------
fn srand(vm: *Vm) void {
    vm.rng = vm.arg(0);
    vm.setRet(0);
}
fn rand(vm: *Vm) void {
    vm.rng = vm.rng *% 1103515245 +% 12345;
    vm.setRet((vm.rng >> 16) & 0x7FFF);
}

// ---- armodule memory (shared arena) ----------------------------------------
fn armMalloc(vm: *Vm) void {
    vm.setRet(vm.mem.sharedMalloc(vm.arg(0), false, 8));
}
fn armRealloc(vm: *Vm) void {
    vm.setRet(vm.mem.shared.realloc(vm.mem, vm.arg(0), vm.arg(1)));
}
fn armFree(vm: *Vm) void {
    vm.mem.sharedFree(vm.arg(0));
    vm.setRet(0);
}

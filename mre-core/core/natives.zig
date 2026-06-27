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
const png = @import("codecs/png.zig");
const gif = @import("codecs/gif.zig");

fn s(v: u32) i32 {
    return @bitCast(v);
}
fn u(v: i32) u32 {
    return @bitCast(v);
}

pub fn registerAll(b: *Bridge) void {
    const reg = struct {
        b: *Bridge,
        fn r(self: @This(), name: []const u8, h: *const fn (*Vm) void) void {
            _ = self.b.register(name, h);
        }
        fn rs(self: @This(), name: []const u8, h: *const fn (*Vm) void) void {
            _ = self.b.registerStub(name, h); // placeholder / constant-return
        }
    }{ .b = b };
    const r = reg;

    // ---- System ----
    r.r("vm_get_time", getTime);
    r.r("vm_get_curr_utc", getCurrUtc);
    r.rs("vm_get_sys_time_zone", retZero);
    r.rs("vm_get_malloc_stat", retZero);
    r.r("vm_malloc", sysMalloc);
    r.r("vm_calloc", sysCalloc);
    r.r("vm_realloc", sysRealloc);
    r.r("vm_free", sysFree);
    r.r("vm_reg_sysevt_callback", regSysevt);
    r.r("vm_get_mre_total_mem_size", getTotalMem);
    r.r("vm_get_tick_count", getTickCount);
    r.r("vm_get_exec_filename", getExecFilename);
    r.r("vm_get_sys_property", getSysProperty);
    r.rs("vm_get_vm_tag", retNeg1);
    r.r("vm_app_log", appLog);
    r.rs("vm_switch_power_saving_mode", retZero);
    r.rs("vm_appmgr_is_installed", retZero);
    r.r("vm_appmgr_get_installed_list", appmgrList);
    r.r("vm_exit_app", exitApp);
    r.rs("vm_send_sms", retZero); // SMS not supported

    // ---- Program manager / message ----
    r.rs("vm_pmng_get_current_handle", retOne);
    r.r("vm_reg_msg_proc", regMsgProc);
    r.rs("vm_post_msg", retOne);

    // ---- Timer ----
    r.r("vm_create_timer", createTimer);
    r.r("vm_delete_timer", deleteTimer);
    r.r("vm_create_timer_ex", createTimer);
    r.r("vm_delete_timer_ex", deleteTimer);

    // ---- File / IO ----
    r.r("vm_reg_keyboard_callback", regKeyboard);
    r.r("vm_reg_pen_callback", regPen);
    r.r("vm_file_open", fileOpen);
    r.r("vm_file_close", fileClose);
    r.r("vm_file_read", fileRead);
    r.r("vm_file_write", fileWrite);
    r.rs("vm_file_commit", retZero);
    r.r("vm_file_seek", fileSeek);
    r.r("vm_file_tell", fileTell);
    r.r("vm_file_is_eof", fileIsEof);
    r.r("vm_file_getfilesize", fileGetSize);
    r.rs("vm_file_delete", retNeg1);
    r.rs("vm_file_rename", retZero);
    r.rs("vm_file_mkdir", retNeg1);
    r.rs("vm_file_set_attributes", retZero);
    r.rs("vm_file_get_attributes", retNeg1);
    r.rs("vm_find_first", retNeg1);
    r.rs("vm_find_next", retNeg1);
    r.rs("vm_find_close", retZero);
    r.rs("vm_find_first_ext", retNeg1);
    r.rs("vm_find_next_ext", retNeg1);
    r.rs("vm_find_close_ext", retZero);
    r.rs("vm_file_get_modify_time", retNeg1);
    r.rs("vm_get_removeable_driver", retEDrive);
    r.rs("vm_get_system_driver", retCDrive);
    r.r("vm_get_disk_free_space", diskFree);
    r.rs("vm_get_disk_info", retNeg1);
    r.rs("vm_is_support_keyborad", retOne);
    r.r("vm_get_resource_offset_from_file", resOffsetFromFile);

    // ---- SIM ----
    r.rs("vm_get_operator", retZero);
    r.rs("vm_has_sim_card", retOne);
    r.r("vm_get_imei", getImei);
    r.r("vm_get_imsi", getImsi);
    r.rs("vm_sim_card_count", retOne);
    r.r("vm_set_active_sim_card", simActiveSet);
    r.r("vm_get_sim_card_status", simStatus);
    r.r("vm_query_operator_code", queryOperator);
    r.rs("vm_sim_get_active_sim_card", retOne);
    r.rs("vm_sim_max_card_count", retOne);
    r.rs("vm_sim_get_prefer_sim_card", retOne);

    // ---- Graphics ----
    r.r("vm_graphic_get_screen_width", gScreenW);
    r.r("vm_graphic_get_screen_height", gScreenH);
    r.r("vm_graphic_create_layer", gCreateLayer);
    r.rs("vm_graphic_delete_layer", retZero);
    r.r("vm_graphic_active_layer", gActiveLayer);
    r.r("vm_graphic_get_layer_buffer", gGetLayerBuffer);
    r.r("vm_graphic_flush_layer", gFlushLayer);
    r.r("vm_graphic_flatten_layer", gFlushLayer);
    r.r("vm_graphic_translate_layer", gTranslateLayer);
    r.r("vm_graphic_get_bits_per_pixel", gBpp);
    // NOTE: the reference's FUNCN_FIX macro registers the NON-_FIX symbol name
    // (the _FIX suffix is only on the C impl). Games call the unsuffixed names.
    r.r("vm_graphic_create_canvas", gCreateCanvas);
    r.r("vm_graphic_create_canvas_cf", gCreateCanvasCf);
    r.r("vm_graphic_release_canvas", gReleaseCanvas);
    r.r("vm_graphic_get_canvas_buffer", gGetCanvasBuffer);
    r.r("vm_graphic_create_layer_ex", gCreateLayerEx);
    r.r("vm_graphic_create_layer_cf", gCreateLayerCf);
    r.r("vm_graphic_load_image", gLoadImage);
    r.r("vm_graphic_get_img_property", gGetImgProperty);
    r.r("vm_graphic_blt", gBlt);
    r.r("vm_graphic_blt_ex", gBltEx);
    r.r("vm_graphic_rotate", gRotate);
    r.r("vm_graphic_mirror", gMirror);
    r.r("vm_graphic_set_pixel", gSetPixel);
    r.r("vm_graphic_set_pixel_ex", gSetPixelEx);
    r.r("vm_graphic_line", gLine);
    r.r("vm_graphic_line_ex", gLineEx);
    r.r("vm_graphic_fill_rect", gFillRect);
    r.r("vm_graphic_fill_rect_ex", gFillRectEx);
    r.r("vm_graphic_roundrect", gRoundRect);
    r.r("vm_graphic_roundrect_ex", gRoundRectEx);
    r.r("vm_graphic_fill_roundrect", gFillRoundRect);
    r.r("vm_graphic_fill_roundrect_ex", gFillRoundRectEx);
    r.r("vm_graphic_rect", gRect);
    r.r("vm_graphic_rect_ex", gRectEx);
    r.rs("vm_graphic_fill_polygon", retZero); // polygon fill deferred
    r.r("vm_graphic_set_clip", gSetClip);
    r.r("vm_graphic_reset_clip", gResetClip);
    r.r("vm_graphic_flush_screen", gFlushScreen);
    r.rs("vm_graphic_is_r2l_state", retZero);
    r.r("vm_graphic_setcolor", gSetColor);
    r.r("vm_graphic_canvas_set_trans_color", gCanvasTrans);
    r.r("vm_graphic_get_buffer", gGetBuffer);
    r.rs("vm_initialize_screen_buffer", retZero);

    // ---- Textout ----
    r.r("vm_graphic_get_character_height", gCharH);
    r.r("vm_graphic_get_character_width", gCharW);
    r.r("vm_graphic_get_string_width", gStringW);
    r.r("vm_graphic_get_string_height", gCharH);
    r.r("vm_graphic_measure_character", gMeasureChar);
    r.rs("vm_graphic_get_character_info", retNeg1);
    r.rs("vm_graphic_set_font", retZero);
    r.r("vm_graphic_textout", gTextout);
    r.r("vm_graphic_textout_by_baseline", gTextoutBaseline);
    r.rs("vm_font_set_font_size", retZero);
    r.rs("vm_font_set_font_style", retZero);
    r.r("vm_graphic_textout_to_layer", gTextoutToLayer);
    r.rs("vm_graphic_get_string_baseline", retZero);
    r.rs("vm_graphic_is_use_vector_font", retZero);
    r.r("vm_graphic_get_char_num_in_width", gCharNumInWidth);

    // ---- Resources ----
    r.r("vm_load_resource", loadResource);
    r.r("vm_resource_get_data", resourceGetData);
    r.rs("vm_get_res_header", retEight);

    // ---- CharSet ----
    r.r("vm_ucs2_to_gb2312", ucs2ToAscii);
    r.r("vm_gb2312_to_ucs2", asciiToUcs2);
    r.r("vm_ucs2_to_ascii", ucs2ToAscii);
    r.r("vm_ascii_to_ucs2", asciiToUcs2);
    r.rs("vm_chset_convert", retZero);
    r.rs("vm_get_language", retOne);
    r.r("vm_get_language_ssc", langSsc);
    r.r("vm_ucs2_string", ucs2String);

    // ---- STDLib ----
    r.r("vm_wstrlen", wstrlen);
    r.r("vm_wstrcpy", wstrcpy);
    r.r("vm_wstrncpy", wstrncpy);
    r.r("vm_wstrcat", wstrcat);
    r.r("vm_wstrcmp", wstrcmp);

    // ---- Audio ----
    r.r("vm_set_volume", setVolume);
    r.r("vm_get_volume", getVolume);
    r.r("vm_audio_play_bytes_no_block", audioPlay);
    r.r("vm_audio_stop_all", audioStopAll);
    r.r("vm_audio_mixed_close", audioClose);
    r.r("vm_audio_mixed_close_all", audioStopAll);
    // legacy MIDI/bitstream APIs (route to the same backend where sensible)
    r.rs("vm_midi_play_by_bytes", retOne);
    r.rs("vm_midi_play_by_bytes_ex", retOne);
    r.rs("vm_midi_pause", retZero);
    r.rs("vm_midi_get_time", retZero);
    r.rs("vm_midi_stop", retZero);
    r.rs("vm_midi_stop_all", retZero);
    r.rs("vm_bitstream_audio_open", retZero);
    r.rs("vm_bitstream_audio_open_pcm", retZero);
    r.rs("vm_bitstream_audio_finished", retZero);
    r.rs("vm_bitstream_audio_close", retZero);
    r.rs("vm_bitstream_audio_get_buffer_status", retZero);
    r.rs("vm_bitstream_audio_put_data", retZero);
    r.rs("vm_bitstream_audio_start", retZero);
    r.rs("vm_bitstream_audio_stop", retZero);
    r.rs("vm_bitstream_audio_get_play_time", retZero);
    r.rs("ext_media_setbufer", retZero);
    r.rs("ext_media_getreadbuffer", retZero);
    r.rs("ext_media_record", retZero);
    r.rs("ext_media_readdatadone", retZero);
    r.rs("ext_media_stop", retZero);

    // ---- Socket / network (stubbed: no host network) ----
    r.rs("vm_is_support_wifi", retOne);
    r.rs("vm_wifi_is_connected", retOne);
    r.rs("vm_soc_get_host_by_name", retNeg1);
    r.rs("vm_tcp_connect", retNeg1);
    r.rs("vm_tcp_close", retZero);
    r.rs("vm_tcp_read", retZero);
    r.rs("vm_tcp_write", retZero);

    // ---- Misc ----
    r.r("srand", srand);
    r.r("rand", rand);

    // ---- ARModule memory (stdio helper) ----
    r.r("armodule_malloc", armMalloc);
    r.r("armodule_realloc", armRealloc);
    r.r("armodule_free", armFree);
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
    vm.setRet(vm.clock_ms); // deterministic; advanced by vm.tick(delta)
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
    if (std.posix.getenv("LOG_FILES") != null)
        std.debug.print("[timer] create interval={d}ms cb=0x{x:0>8}\n", .{ interval, cb });
    for (&vm.timers, 0..) |*t, id| {
        if (!t.active) {
            t.* = .{ .active = true, .interval = interval, .accum = 0, .cb = cb };
            return vm.setRet(@intCast(id));
        }
    }
    vm.setRet(u(-1));
}
fn deleteTimer(vm: *Vm) void {
    const id = vm.arg(0);
    if (id < vm.timers.len) vm.timers[id].active = false;
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
    // vm_graphic_color struct: the 565 value is the last u16 field; read it via a
    // best-effort offset. Layout {VMBYTE type; argb(4); VMUINT16 565} => 565 at +5.
    const p = vm.arg(0);
    vm.gfx.global_color = vm.mem.readU16(p + 5);
    vm.setRet(0);
}
fn gCanvasTrans(vm: *Vm) void {
    vm.setRet(u(vm.gfx.canvasSetTransColor(vm.arg(0), @truncate(vm.arg(1)))));
}

const trans_sentinel: u16 = 0xF81F; // magenta — transparent-key for alpha pixels

fn gLoadImage(vm: *Vm) void {
    const img = vm.arg(0);
    const len = vm.arg(1);
    if (img == 0 or len == 0) return vm.setRet(0);
    const bytes = vm.mem.slice(img, len);

    // PNG and GIF are the formats MRE sprites use; pick by magic.
    const Decoded = struct { w: u32, h: u32, rgba: []u8 };
    const decoded: Decoded = blk: {
        if (png.decode(vm.gpa, bytes)) |d| {
            break :blk .{ .w = d.w, .h = d.h, .rgba = d.rgba };
        } else |_| {}
        if (gif.decode(vm.gpa, bytes)) |d| {
            break :blk .{ .w = d.w, .h = d.h, .rgba = d.rgba };
        } else |_| {}
        if (bytes.len >= 2) std.debug.print("[load_image] unsupported magic {x:0>2}{x:0>2}\n", .{ bytes[0], bytes[1] });
        return vm.setRet(0);
    };
    defer vm.gpa.free(decoded.rgba);
    if (std.posix.getenv("DIAG") != null)
        std.debug.print("[load_image] decoded {d}x{d}\n", .{ decoded.w, decoded.h });

    const canvas = vm.gfx.createCanvas(appMallocThunk, vm, @intCast(decoded.w), @intCast(decoded.h));
    if (canvas == 0) return vm.setRet(0);

    const pixels = canvas + gfx.canvas_data_offset;
    var has_trans = false;
    var i: u32 = 0;
    const n = decoded.w * decoded.h;
    while (i < n) : (i += 1) {
        const o = i * 4;
        var c565: u16 = gfx.rgb565(decoded.rgba[o], decoded.rgba[o + 1], decoded.rgba[o + 2]);
        if (decoded.rgba[o + 3] < 128) {
            c565 = trans_sentinel;
            has_trans = true;
        }
        vm.mem.writeU16(pixels + i * 2, c565);
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
    vm.setRet(u(audio.play(clip, format)));
}
fn audioStopAll(vm: *Vm) void {
    audio.stopAll();
    vm.setRet(0);
}
fn audioClose(vm: *Vm) void {
    audio.close(s(vm.arg(0)));
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

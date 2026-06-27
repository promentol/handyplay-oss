//! .vxp load orchestration (format detection + preparation).
//! Sniffs ELF vs zlib/ADS, allocates the app's memory region from the shared
//! arena, populates it, and returns everything `start()` needs.
const std = @import("std");
const Memory = @import("../memory.zig").Memory;
const Manager = @import("../memory.zig").Manager;
const tags_mod = @import("tags.zig");
const elf = @import("elf.zig");
const ads = @import("ads.zig");

const min_mem_size: u32 = 512 * 1024 * 4; // 2 MB floor
const app_align: u32 = 0x100000; // 1 MB

pub const Format = enum { elf, zlib, unknown };

pub const Error = error{ BadArgs, AllocFailed, NotApp, ZippedNonAds } ||
    tags_mod.Error || elf.Error || ads.Error;

pub const LoadedApp = struct {
    is_ads: bool,
    entry_point: u32, // absolute EMU address
    offset_mem: u32, // app region base (EMU)
    mem_size: u32,
    segments_size: u32,
    res_offset: u32,
    res_size: u32,
    app_memory: Manager, // arena over the app region, code already reserved
};

pub fn sniff(file: []const u8) Format {
    if (file.len < 4) return .unknown;
    if (std.mem.eql(u8, file[1..4], "ELF")) return .elf;
    if (file[0] == 0x78) switch (file[1]) {
        0x01, 0x5E, 0x9C, 0xDA => return .zlib,
        else => {},
    };
    return .unknown;
}

pub fn load(gpa: std.mem.Allocator, mem: *Memory, file: []const u8) Error!LoadedApp {
    const t = try tags_mod.parse(file);
    const is_ads = t.isAds();
    const is_zipped = t.isZipped();

    var mem_size: u32 = t.ram_kb *% 1024;
    mem_size = @max(min_mem_size, mem_size);

    const offset_mem = mem.sharedMalloc(mem_size, true, app_align);
    if (offset_mem == 0) return Error.AllocFailed;
    const region = mem.slice(offset_mem, mem_size);
    @memset(region, 0);

    var app: LoadedApp = .{
        .is_ads = is_ads,
        .entry_point = 0,
        .offset_mem = offset_mem,
        .mem_size = mem_size,
        .segments_size = 0,
        .res_offset = 0,
        .res_size = 0,
        .app_memory = Manager.init(gpa),
    };

    if (!is_zipped) {
        const loaded = try elf.load(file, region, offset_mem);
        app.entry_point = loaded.entry;
        app.segments_size = loaded.segments_size;
        app.res_offset = loaded.res_offset;
        app.res_size = loaded.res_size;
    } else if (is_ads) {
        const info = try ads.readInfo(file, t.tags_offset);
        app.segments_size = try ads.decompress(file, info, region);
        app.res_offset = info.res_offset;
        app.res_size = info.res_size;
        app.entry_point = offset_mem; // ADS entry is region base (ARM mode)
    } else {
        return Error.ZippedNonAds;
    }

    // App arena over the region, with the loaded code/data reserved up front.
    app.app_memory.setup(offset_mem, mem_size, 0);
    _ = app.app_memory.malloc(app.segments_size, false, 8);
    return app;
}

//! Minimal ELF32 little-endian loader for raw (uncompressed) .vxp apps — the
//! non-zipped branch of .vxp preparation. Loads PT_LOAD segments into the app's
//! mapped memory, applies ARM relocations (.rel.dyn/.rel.plt), and locates the
//! `.vm_res` resource section.
const std = @import("std");

const PT_LOAD = 1;

// ARM relocation types we handle (low byte of r_info).
const R_ARM_ABS32 = 0x02;
const R_ARM_RELATIVE = 0x17;
const R_ARM_GLOB_DAT = 0x16; // (also JUMP_SLOT-ish; reference zeroes these)

pub const Error = error{ NotElf, BadElf, SegmentOverflow };

pub const Loaded = struct {
    entry: u32, // relative to the app region base (vaddr-space)
    segments_size: u32,
    res_offset: u32 = 0,
    res_size: u32 = 0,
};

/// `dst` is the app's mapped memory window (length == mem_size). `app_base_emu` is
/// the EMU offset where `dst` lives, used to bias relocations and the entry point.
pub fn load(file: []const u8, dst: []u8, app_base_emu: u32) Error!Loaded {
    if (file.len < 52 or !std.mem.eql(u8, file[0..4], "\x7fELF")) return Error.NotElf;
    if (file[4] != 1) return Error.BadElf; // ELFCLASS32
    if (file[5] != 1) return Error.BadElf; // ELFDATA2LSB

    const e_entry = rd32(file, 24);
    const e_phoff = rd32(file, 28);
    const e_shoff = rd32(file, 32);
    const e_phentsize = rd16(file, 42);
    const e_phnum = rd16(file, 44);
    const e_shentsize = rd16(file, 46);
    const e_shnum = rd16(file, 48);
    const e_shstrndx = rd16(file, 50);

    var result: Loaded = .{ .entry = e_entry + app_base_emu, .segments_size = 0 };

    // --- program headers: load PT_LOAD segments ---
    var i: u16 = 0;
    while (i < e_phnum) : (i += 1) {
        const ph = e_phoff + @as(u32, i) * e_phentsize;
        if (ph + 32 > file.len) return Error.BadElf;
        const p_type = rd32(file, ph);
        if (p_type != PT_LOAD) continue;
        const p_offset = rd32(file, ph + 4);
        const p_vaddr = rd32(file, ph + 8);
        const p_filesz = rd32(file, ph + 16);
        const p_memsz = rd32(file, ph + 20);

        if (@as(u64, p_vaddr) + p_memsz > dst.len) return Error.SegmentOverflow;
        if (@as(u64, p_offset) + p_filesz > file.len) return Error.BadElf;
        @memcpy(dst[p_vaddr..][0..p_filesz], file[p_offset..][0..p_filesz]);
        result.segments_size = @max(result.segments_size, p_vaddr + p_memsz);
    }

    // --- section headers: relocations + .vm_res, located by name ---
    if (e_shoff != 0 and e_shnum != 0 and e_shstrndx < e_shnum) {
        const shstr_sh = e_shoff + @as(u32, e_shstrndx) * e_shentsize;
        const shstr_off = rd32(file, shstr_sh + 16);

        var s: u16 = 0;
        while (s < e_shnum) : (s += 1) {
            const sh = e_shoff + @as(u32, s) * e_shentsize;
            if (sh + 40 > file.len) return Error.BadElf;
            const name = sectionName(file, shstr_off, rd32(file, sh + 0));
            const sh_addr = rd32(file, sh + 12);
            const sh_offset = rd32(file, sh + 16);
            const sh_size = rd32(file, sh + 20);

            if (std.mem.eql(u8, name, ".rel.dyn") or std.mem.eql(u8, name, ".rel.plt")) {
                applyRel(dst, sh_addr, sh_size, app_base_emu);
            } else if (std.mem.eql(u8, name, ".vm_res")) {
                result.res_offset = sh_offset;
                result.res_size = sh_size;
            }
        }
    }

    return result;
}

/// Reloc entries are read from the already-loaded image at `rel_addr` (== sh_addr,
/// which for these base-0 shared objects equals the file offset). Each Elf32_Rel is
/// {r_offset:u32, r_info:u32}.
fn applyRel(dst: []u8, rel_addr: u32, rel_size: u32, app_base_emu: u32) void {
    if (@as(u64, rel_addr) + rel_size > dst.len) return;
    var off: u32 = 0;
    while (off + 8 <= rel_size) : (off += 8) {
        const base = rel_addr + off;
        const r_offset = std.mem.readInt(u32, dst[base..][0..4], .little);
        const r_info = std.mem.readInt(u32, dst[base + 4 ..][0..4], .little);
        if (@as(u64, r_offset) + 4 > dst.len) continue;
        const target = dst[r_offset..][0..4];
        switch (r_info & 0xFF) {
            R_ARM_RELATIVE => {
                const cur = std.mem.readInt(u32, target, .little);
                std.mem.writeInt(u32, target, cur +% app_base_emu, .little);
            },
            R_ARM_ABS32, R_ARM_GLOB_DAT => std.mem.writeInt(u32, target, 0, .little),
            else => {},
        }
    }
}

fn sectionName(file: []const u8, shstr_off: u32, name_idx: u32) []const u8 {
    const start = shstr_off + name_idx;
    if (start >= file.len) return "";
    const slice = file[start..];
    const end = std.mem.indexOfScalar(u8, slice, 0) orelse return "";
    return slice[0..end];
}

fn rd16(file: []const u8, off: u32) u16 {
    return std.mem.readInt(u16, file[off..][0..2], .little);
}
fn rd32(file: []const u8, off: u32) u32 {
    return std.mem.readInt(u32, file[off..][0..4], .little);
}

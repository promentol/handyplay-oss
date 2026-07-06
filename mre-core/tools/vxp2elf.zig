//! Load a .vxp through the emulator's loader (decompresses ADS, applies ARM
//! relocations, lays the image at its real base) and emit a clean ELF32-LE-ARM so
//! a decompiler (Binary Ninja / dogbolt) gets properly-relocated code at the correct
//! addresses — unlike a naive raw RO+RW concat, which yields an empty decompile.
//!
//! Usage: vxp2elf <in.vxp> <out.elf>
const std = @import("std");
const core = @import("core");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 3) {
        std.debug.print("usage: vxp2elf <in.vxp> <out.elf>\n", .{});
        return error.BadArgs;
    }

    const file = try std.fs.cwd().readFileAlloc(gpa, args[1], 64 * 1024 * 1024);
    defer gpa.free(file);

    var mem = try core.Memory.init(gpa, 32 * 1024 * 1024);
    defer mem.deinit();
    var app = try core.loader.load(gpa, &mem, file);
    defer app.app_memory.deinit();

    const base = app.offset_mem;
    const size = app.segments_size;
    const image = mem.slice(base, size);

    const ehsize: u32 = 52;
    const phsize: u32 = 32;
    const data_off: u32 = 0x1000; // image placement in the file

    // ".text" + ".shstrtab" string table for the section headers.
    const shstr = "\x00.text\x00.shstrtab\x00";
    const text_name: u32 = 1; // offset of ".text" in shstr
    const shstr_name: u32 = 7; // offset of ".shstrtab"
    const shstr_off = data_off + size;
    const shoff = std.mem.alignForward(u32, shstr_off + @as(u32, shstr.len), 4);

    var out = try std.fs.cwd().createFile(args[2], .{ .truncate = true });
    defer out.close();
    var buf: [4096]u8 = undefined;
    var w = out.writer(&buf);
    const o = &w.interface;

    // --- ELF32 header ---
    try o.writeAll(&[_]u8{ 0x7f, 'E', 'L', 'F', 1, 1, 1, 0 } ++ [_]u8{0} ** 8);
    try o.writeInt(u16, 2, .little); // e_type = ET_EXEC
    try o.writeInt(u16, 40, .little); // e_machine = EM_ARM
    try o.writeInt(u32, 1, .little); // e_version
    try o.writeInt(u32, app.entry_point, .little); // e_entry
    try o.writeInt(u32, ehsize, .little); // e_phoff
    try o.writeInt(u32, shoff, .little); // e_shoff
    try o.writeInt(u32, 0x05000000, .little); // e_flags = EABI v5
    try o.writeInt(u16, @intCast(ehsize), .little); // e_ehsize
    try o.writeInt(u16, @intCast(phsize), .little); // e_phentsize
    try o.writeInt(u16, 1, .little); // e_phnum
    try o.writeInt(u16, 40, .little); // e_shentsize
    try o.writeInt(u16, 3, .little); // e_shnum (null, .text, .shstrtab)
    try o.writeInt(u16, 2, .little); // e_shstrndx

    // --- one PT_LOAD program header (RWX) ---
    try o.writeInt(u32, 1, .little); // p_type = PT_LOAD
    try o.writeInt(u32, data_off, .little); // p_offset
    try o.writeInt(u32, base, .little); // p_vaddr
    try o.writeInt(u32, base, .little); // p_paddr
    try o.writeInt(u32, size, .little); // p_filesz
    try o.writeInt(u32, size, .little); // p_memsz
    try o.writeInt(u32, 7, .little); // p_flags = R|W|X
    try o.writeInt(u32, 0x1000, .little); // p_align

    // pad to data_off, image, then shstrtab, then pad to shoff
    try o.splatByteAll(0, data_off - (ehsize + phsize));
    try o.writeAll(image);
    try o.writeAll(shstr);
    try o.splatByteAll(0, shoff - (shstr_off + shstr.len));

    // --- section headers: null, .text (ALLOC|EXEC), .shstrtab ---
    try writeShdr(o, 0, 0, 0, 0, 0, 0, 0); // null
    try writeShdr(o, text_name, 1, 6, base, data_off, size, 4); // PROGBITS, ALLOC|EXEC
    try writeShdr(o, shstr_name, 3, 0, 0, shstr_off, shstr.len, 1); // STRTAB
    try o.flush();

    std.debug.print("wrote {s}: base=0x{x} entry=0x{x} size={d}\n", .{ args[2], base, app.entry_point, size });
}

fn writeShdr(o: anytype, name: u32, stype: u32, flags: u32, addr: u32, off: u32, size: u32, alignv: u32) !void {
    try o.writeInt(u32, name, .little); // sh_name
    try o.writeInt(u32, stype, .little); // sh_type
    try o.writeInt(u32, flags, .little); // sh_flags
    try o.writeInt(u32, addr, .little); // sh_addr
    try o.writeInt(u32, off, .little); // sh_offset
    try o.writeInt(u32, size, .little); // sh_size
    try o.writeInt(u32, 0, .little); // sh_link
    try o.writeInt(u32, 0, .little); // sh_info
    try o.writeInt(u32, alignv, .little); // sh_addralign
    try o.writeInt(u32, 0, .little); // sh_entsize
}

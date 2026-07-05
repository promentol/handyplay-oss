//! TheTerminator disassembler — dumps every class, every method, and
//! the full bytecode stream with opcode names + immediate operands.
//!
//!   zig run disasm.zig                          → dumps TheTerminator.exn to stdout
//!   zig run disasm.zig -- catalog.exn           → dumps the given .exn
//!   zig run disasm.zig -- TheTerminator.exn 4   → dumps only class index 4
//!
//! Operand decoding follows the JVM/ExEn 2 convention recovered in
//! `interp.zig`. The class file format is 4CVP, parsed via the
//! existing class_registry module.
const std = @import("std");
const core = @import("core");
const class_registry = core.class_registry;

const Op = struct { name: []const u8, operands: i32 };

/// Derived from `core.opcodes.op_specs` — the single source shared with
/// the VM dispatch table, so mnemonics/widths can't drift from runtime.
const OPS: [256]Op = blk: {
    var t: [256]Op = undefined;
    for (0..256) |i| t[i] = .{
        .name = core.opcodes.mnemonics[i],
        .operands = core.opcodes.operand_widths[i],
    };
    break :blk t;
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse "TheTerminator.exn";
    const filter_class: ?u16 = if (args.next()) |s| std.fmt.parseInt(u16, s, 10) catch null else null;

    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 16 << 20);
    defer allocator.free(raw);

    // The class records start after the simulator's offset table.
    // Same logic as exen.zig:loadExn — read the sentinel at file
    // offset 0x38 + 4*method_count.
    const method_count = std.mem.readInt(u32, raw[0x34..][0..4], .little);
    const sentinel_off = 0x38 + 4 * method_count;
    const tail_start = std.mem.readInt(u32, raw[sentinel_off..][0..4], .little);

    var reg = class_registry.Registry.init(allocator);
    defer reg.deinit();
    const n = try reg.scanBuffer(raw, tail_start, .gamelet);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};
    try stdout.print("=== {s}: {d} classes (tail_start=0x{x:0>5}) ===\n\n", .{ path, n, tail_start });

    var class_idx: u16 = 0;
    while (class_idx < n) : (class_idx += 1) {
        if (filter_class) |want| {
            if (class_idx != want) continue;
        }
        const hash = reg.by_index.get(class_idx) orelse continue;
        const cls = reg.lookup(hash) orelse continue;
        try dumpClass(stdout, class_idx, cls);
    }
}

fn dumpClass(out: anytype, idx: u16, cls: class_registry.ClassRecord) !void {
    const mc = cls.methodCount();
    const fc = cls.fieldCount();
    try out.print("─" ** 80 ++ "\n", .{});
    try out.print("CLASS[{d}] 0x{x:0>8}  size={d} bytes  methods={d}  fields={d}\n", .{
        idx, cls.hash, cls.bytes.len, mc, fc,
    });
    try out.print("─" ** 80 ++ "\n", .{});

    // Field table.
    if (fc > 0) {
        try out.print("  FIELDS:\n", .{});
        var p = cls.firstFieldInfoOffset();
        var i: u16 = 0;
        while (i < fc) : (i += 1) {
            if (p + 12 > cls.bytes.len) break;
            const h = std.mem.readInt(u32, cls.bytes[p..][0..4], .little);
            const tag = std.mem.readInt(u16, cls.bytes[p + 6 ..][0..2], .little);
            const slot = std.mem.readInt(u16, cls.bytes[p + 8 ..][0..2], .little);
            try out.print("    [{d:>2}] hash=0x{x:0>8} tag=0x{x:0>4} slot={d}\n", .{ i, h, tag, slot });
            p = (p + 15) & ~@as(usize, 3);
        }
        try out.print("\n", .{});
    }

    // Methods.
    var p = cls.firstMethodInfoOffset();
    var i: u16 = 0;
    while (i < mc) : (i += 1) {
        if (p + 12 > cls.bytes.len) break;
        const h = std.mem.readInt(u32, cls.bytes[p..][0..4], .little);
        const flags = std.mem.readInt(u16, cls.bytes[p + 4 ..][0..2], .little);
        const arg_count = std.mem.readInt(u16, cls.bytes[p + 6 ..][0..2], .little);
        const body_off = std.mem.readInt(u16, cls.bytes[p + 8 ..][0..2], .little);
        const is_native = (flags & 0x100) != 0;
        try out.print("  METHOD[{d:>2}] 0x{x:0>8}  flags=0x{x:0>4} args={d} body=0x{x:0>4}  ", .{
            i, h, flags, arg_count, body_off,
        });
        if (is_native) {
            const idx_native = std.mem.readInt(u32, cls.bytes[body_off..][0..4], .little);
            try out.print("NATIVE [{d}]\n", .{idx_native});
        } else if ((flags & 0x400) != 0 or body_off == 0) {
            // Abstract / bodyless — no bytecode to disassemble (walking
            // from body_off+6 would decode the class header as garbage).
            try out.print("ABSTRACT (no body)\n", .{});
        } else {
            const max_stack = std.mem.readInt(u16, cls.bytes[body_off..][0..2], .little);
            const locals = std.mem.readInt(u16, cls.bytes[body_off + 2 ..][0..2], .little);
            const code_off = body_off + 6;
            // body extends to either the next method's body_off or
            // the class's end; we walk until RETURN/IRETURN/ARETURN
            // to find a sensible cap.
            try out.print("BYTECODE  max_stack={d} locals={d}\n", .{ max_stack, locals });
            try dumpBytecode(out, cls.bytes, code_off);
        }
        p = (p + 15) & ~@as(usize, 3);
    }
    try out.print("\n", .{});
}

fn dumpBytecode(out: anytype, bytes: []const u8, start: usize) !void {
    var pc: usize = start;
    while (pc < bytes.len) {
        const op = bytes[pc];
        const info = OPS[op];
        try out.print("    {x:0>4}: {x:0>2}  {s:<16}", .{ pc - start, op, info.name });
        if (info.operands == -2) {
            // IINC: u8 slot, s8 delta — no alignment.
            if (pc + 3 > bytes.len) {
                try out.print("(truncated)\n", .{});
                break;
            }
            const slot = bytes[pc + 1];
            const delta: i8 = @bitCast(bytes[pc + 2]);
            try out.print("slot={d} delta={d}\n", .{ slot, delta });
            pc += 3;
        } else if (info.operands == -3 or info.operands == -4) {
            // NEWARRAY / MULTIANEWARRAY: aligned u16 type tag (MULTI has
            // a u8 dim first), plus a second u16 element-class ref iff
            // the tag low byte is 0x99 (canonical sub_40EE4D v0==153).
            const tag_off = if (info.operands == -3)
                (pc + 2) & ~@as(usize, 1)
            else
                (pc + 3) & ~@as(usize, 1);
            if (tag_off + 2 > bytes.len) {
                try out.print("(truncated)\n", .{});
                break;
            }
            const tag = std.mem.readInt(u16, bytes[tag_off..][0..2], .little);
            if (info.operands == -4) try out.print("dim={d} ", .{bytes[pc + 1]});
            if ((tag & 0xFF) == 0x99 and tag_off + 4 <= bytes.len) {
                const cls_ref = std.mem.readInt(u16, bytes[tag_off + 2 ..][0..2], .little);
                try out.print("0x{x:0>4} classref=0x{x:0>4}\n", .{ tag, cls_ref });
                pc = tag_off + 4;
            } else {
                try out.print("0x{x:0>4}\n", .{tag});
                pc = tag_off + 2;
            }
        } else if (info.operands == -1) {
            // TABLESWITCH / LOOKUPSWITCH — pad to 2-byte boundary,
            // read default(2) + low(2) + high(2), then (high-low+1)
            // pairs of 2 bytes. We approximate.
            const aligned = (pc + 1 + 1) & ~@as(usize, 1);
            if (op == 0xAA) {
                if (aligned + 6 > bytes.len) break;
                const def = std.mem.readInt(u16, bytes[aligned..][0..2], .little);
                const lo = std.mem.readInt(i16, bytes[aligned + 2 ..][0..2], .little);
                const hi = std.mem.readInt(i16, bytes[aligned + 4 ..][0..2], .little);
                try out.print("default=0x{x:0>4} low={d} high={d}\n", .{ def, lo, hi });
                const span: i32 = @as(i32, hi) - @as(i32, lo) + 1;
                const count: usize = if (span > 0) @intCast(span) else 0;
                pc = aligned + 6 + count * 2;
            } else if (op == 0xAB) { // LOOKUPSWITCH_W: u32 keys, 4-byte-aligned
                if (aligned + 4 > bytes.len) break;
                const def = std.mem.readInt(u16, bytes[aligned..][0..2], .little);
                const count = std.mem.readInt(u16, bytes[aligned + 2 ..][0..2], .little);
                const keys_base = (aligned + 4 + 3) & ~@as(usize, 3);
                try out.print("default=0x{x:0>4} count={d} (wide)\n", .{ def, count });
                pc = keys_base + @as(usize, count) * 6;
            } else { // LOOKUPSWITCH 0xCC: u16 key + u16 target pairs
                if (aligned + 4 > bytes.len) break;
                const def = std.mem.readInt(u16, bytes[aligned..][0..2], .little);
                const npairs = std.mem.readInt(u16, bytes[aligned + 2 ..][0..2], .little);
                try out.print("default=0x{x:0>4} npairs={d}\n", .{ def, npairs });
                pc = aligned + 4 + @as(usize, npairs) * 4;
            }
        } else if (info.operands == 0) {
            try out.print("\n", .{});
            pc += 1;
        } else {
            const n: usize = @intCast(info.operands);
            if (n == 2) {
                // 2-byte-aligned u16: PC = (PC + 1 + 1) & ~1, then
                // read 2 bytes from the aligned position.
                const aligned = (pc + 2) & ~@as(usize, 1);
                if (aligned + 2 > bytes.len) {
                    try out.print("(truncated)\n", .{});
                    break;
                }
                const v = std.mem.readInt(u16, bytes[aligned..][0..2], .little);
                try out.print("0x{x:0>4}\n", .{v});
                pc = aligned + 2;
            } else if (n == 1) {
                if (pc + 2 > bytes.len) {
                    try out.print("(truncated)\n", .{});
                    break;
                }
                try out.print("0x{x:0>2}\n", .{bytes[pc + 1]});
                pc += 2;
            } else {
                try out.print("\n", .{});
                pc += 1 + n;
            }
        }
        if (op == 0xAC or op == 0xB0 or op == 0xB1) {
            // Stop at the first return — handles overlapping method
            // bodies in the simulator's class-record format.
            try out.print("\n", .{});
            break;
        }
    }
}

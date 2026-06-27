//! Static coverage audit — walks a gamelet's bytecode and reports:
//!   (1) opcodes our VM doesn't have a handler bound for (= would halt),
//!   (2) INVOKE call sites whose method-hash doesn't resolve to a name
//!       in `core/debug/names.zig::methodName()` (= unknown bytecode
//!       methods or unnamed natives).
//!
//! Usage:
//!   zig run tools/coverage_audit.zig -- samples/wallbreaker.exn
//!   zig run tools/coverage_audit.zig -- samples/wallbreaker.exn 0xd836a3ce
//!
//! Output is grouped:
//!   ── UNBOUND OPCODES ──    (op → list of call sites class.method@pc)
//!   ── UNRESOLVED INVOKES ── ((class?, method_hash) → list of call sites)
//!
//! Distinct from the runtime trace: this finds gaps in code paths that
//! haven't been exercised at runtime, so we can pre-empt halts.

const std = @import("std");
const core = @import("core");
const class_registry = core.class_registry;
const dbg = core.debug;

/// Mirror of `core/vm/opcodes/mod.zig::buildOpTable`. Each entry is
/// `true` if the opcode is bound to a real handler (NOT `unimpl`).
const BOUND: [256]bool = blk: {
    var t: [256]bool = [_]bool{false} ** 256;
    // consts
    t[0x00] = true; t[0x01] = true;
    t[0x02] = true; t[0x03] = true; t[0x04] = true; t[0x05] = true;
    t[0x06] = true; t[0x07] = true; t[0x08] = true;
    t[0x10] = true; t[0x11] = true; t[0x12] = true; t[0x14] = true;
    t[0xD0] = true;
    // load/store
    t[0x19] = true; t[0x2A] = true; t[0x2B] = true; t[0x2C] = true; t[0x2D] = true;
    t[0x3A] = true; t[0x4A] = true; t[0x4B] = true; t[0x4C] = true; t[0x4D] = true; t[0x4E] = true;
    t[0xD5] = true; t[0xD6] = true;
    t[0xD9] = true; t[0xDA] = true; t[0xDB] = true; t[0xDC] = true;
    t[0xDD] = true; t[0xDE] = true; t[0xDF] = true; t[0xE0] = true;
    t[0xE1] = true; t[0xE2] = true; t[0xE3] = true; t[0xE4] = true;
    t[0xE5] = true; t[0xE6] = true; t[0xE7] = true; t[0xE8] = true;
    // stack
    t[0x56] = true; t[0x57] = true; t[0x58] = true; t[0x59] = true;
    t[0x5A] = true; t[0x5C] = true;
    // arithmetic + conversions
    t[0x60] = true; t[0x61] = true; t[0x64] = true; t[0x65] = true;
    t[0x68] = true; t[0x6C] = true; t[0x70] = true; t[0x74] = true;
    t[0x78] = true; t[0x7A] = true; t[0x7C] = true;
    t[0x7E] = true; t[0x80] = true; t[0x82] = true; t[0x84] = true;
    t[0x91] = true; t[0x92] = true; t[0x93] = true;
    // arrays
    t[0x2E] = true; t[0x32] = true; t[0x33] = true; t[0x34] = true; t[0x35] = true;
    t[0x4F] = true; t[0x50] = true; t[0x51] = true; t[0x52] = true;
    t[0x53] = true; t[0x54] = true; t[0x55] = true;
    t[0xBC] = true; t[0xBE] = true;
    // object
    t[0xBB] = true; t[0xC0] = true; t[0xC1] = true;
    // returns
    t[0xB0] = true; t[0xB1] = true; t[0xE9] = true; t[0xEA] = true;
    // branches
    t[0x99] = true; t[0x9A] = true; t[0x9B] = true; t[0x9C] = true;
    t[0x9D] = true; t[0x9E] = true;
    t[0x9F] = true; t[0xA0] = true; t[0xA1] = true; t[0xA2] = true;
    t[0xA3] = true; t[0xA4] = true;
    t[0xA5] = true; t[0xA6] = true; t[0xA7] = true;
    t[0xC6] = true; t[0xC7] = true;
    // switch
    t[0xCC] = true; t[0xCD] = true;
    // invoke
    t[0xED] = true; t[0xEE] = true; t[0xEF] = true;
    t[0xF0] = true; t[0xF1] = true; t[0xF2] = true;
    // field
    t[0xF3] = true; t[0xF4] = true; t[0xF5] = true; t[0xF6] = true;
    t[0xF7] = true; t[0xF8] = true; t[0xF9] = true; t[0xFA] = true;
    break :blk t;
};

/// Per-opcode operand widths. Mirrors `tools/disasm.zig::OPS`.
///   0   → no immediate
///   1   → one u8 immediate (no alignment)
///   2   → one u16 immediate, 2-byte aligned (PC = (PC+2) & ~1)
///   -1  → variable (TABLESWITCH/LOOKUPSWITCH)
///   -2  → IINC (u8 slot + s8 delta, no alignment)
const OPERANDS: [256]i32 = blk: {
    var t: [256]i32 = [_]i32{0} ** 256;
    // 1-byte immediates
    t[0x10] = 1; t[0x19] = 1; t[0x3A] = 1; t[0x4A] = 1;
    t[0xD5] = 1; t[0xD6] = 1;
    t[0x15] = 1; t[0x16] = 1; t[0x17] = 1; t[0x18] = 1;
    t[0x36] = 1; t[0x37] = 1; t[0x38] = 1; t[0x39] = 1;
    // 2-byte u16 immediates
    t[0x11] = 2; t[0x12] = 2; t[0x14] = 2; t[0xD0] = 2;
    t[0x99] = 2; t[0x9A] = 2; t[0x9B] = 2; t[0x9C] = 2;
    t[0x9D] = 2; t[0x9E] = 2;
    t[0x9F] = 2; t[0xA0] = 2; t[0xA1] = 2; t[0xA2] = 2;
    t[0xA3] = 2; t[0xA4] = 2;
    t[0xA5] = 2; t[0xA6] = 2; t[0xA7] = 2;
    t[0xA8] = 2;
    t[0xBB] = 2; t[0xBC] = 2; t[0xBD] = 2;
    t[0xC0] = 2; t[0xC1] = 2; t[0xC5] = 2;
    t[0xC6] = 2; t[0xC7] = 2;
    t[0xC8] = 2; t[0xC9] = 2;
    t[0xED] = 2; t[0xEE] = 2; t[0xEF] = 2;
    t[0xF0] = 2; t[0xF1] = 2; t[0xF2] = 2;
    t[0xF3] = 2; t[0xF4] = 2; t[0xF5] = 2; t[0xF6] = 2;
    t[0xF7] = 2; t[0xF8] = 2; t[0xF9] = 2; t[0xFA] = 2;
    t[0xB2] = 2; t[0xB3] = 2; t[0xB4] = 2; t[0xB5] = 2;
    t[0xB6] = 2; t[0xB7] = 2; t[0xB8] = 2; t[0xB9] = 2;
    // IINC
    t[0x84] = -2;
    // switches
    t[0xAA] = -1; t[0xAB] = -1; t[0xCC] = -1; t[0xCD] = -1;
    break :blk t;
};

const INVOKE_OPS = [_]u8{ 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF2 };
fn isInvoke(op: u8) bool {
    for (INVOKE_OPS) |i| if (i == op) return true;
    return false;
}

const CallSite = struct {
    class_hash: u32,
    method_hash: u32,
    pc: u32,
    op: u8,
    invoked_class: u32, // 0 = unknown (only INVOKEVIRTUAL_ALT has direct class context)
    invoked_method: u32,
};

const Report = struct {
    unbound: std.AutoArrayHashMap(u8, std.ArrayList(CallSite)),
    unresolved: std.AutoArrayHashMap(u64, std.ArrayList(CallSite)),
    allocator: std.mem.Allocator,

    fn init(a: std.mem.Allocator) Report {
        return .{
            .unbound = std.AutoArrayHashMap(u8, std.ArrayList(CallSite)).init(a),
            .unresolved = std.AutoArrayHashMap(u64, std.ArrayList(CallSite)).init(a),
            .allocator = a,
        };
    }
    fn deinit(self: *Report) void {
        var it1 = self.unbound.iterator();
        while (it1.next()) |e| e.value_ptr.deinit(self.allocator);
        self.unbound.deinit();
        var it2 = self.unresolved.iterator();
        while (it2.next()) |e| e.value_ptr.deinit(self.allocator);
        self.unresolved.deinit();
    }

    fn addUnbound(self: *Report, site: CallSite) !void {
        const gop = try self.unbound.getOrPut(site.op);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, site);
    }
    fn addUnresolved(self: *Report, site: CallSite) !void {
        const key = (@as(u64, site.invoked_class) << 32) | @as(u64, site.invoked_method);
        const gop = try self.unresolved.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, site);
    }
};

fn walkMethod(
    report: *Report,
    cls: class_registry.ClassRecord,
    method_hash: u32,
    body_off: usize,
) !void {
    if (body_off + 6 > cls.bytes.len) return;
    var pc: usize = body_off + 6;
    while (pc < cls.bytes.len) {
        const op = cls.bytes[pc];
        const op_start = pc;
        const operand = OPERANDS[op];

        // Find next-pc to advance.
        var next_pc: usize = pc + 1;
        if (operand == -2) {
            next_pc = pc + 3;
        } else if (operand == -1) {
            // align to 2-byte boundary AFTER the opcode
            const aligned = (pc + 1 + 1) & ~@as(usize, 1);
            if (op == 0xAA or op == 0xCD) {
                if (aligned + 6 > cls.bytes.len) break;
                const lo = std.mem.readInt(i16, cls.bytes[aligned + 2 ..][0..2], .little);
                const hi = std.mem.readInt(i16, cls.bytes[aligned + 4 ..][0..2], .little);
                const span: i32 = @as(i32, hi) - @as(i32, lo) + 1;
                const count: usize = if (span > 0) @intCast(span) else 0;
                next_pc = aligned + 6 + count * 2;
            } else { // LOOKUPSWITCH 0xAB / 0xCC
                if (aligned + 4 > cls.bytes.len) break;
                const npairs = std.mem.readInt(u16, cls.bytes[aligned + 2 ..][0..2], .little);
                next_pc = aligned + 4 + @as(usize, npairs) * 4;
            }
        } else if (operand == 1) {
            next_pc = pc + 2;
        } else if (operand == 2) {
            const aligned = (pc + 2) & ~@as(usize, 1);
            next_pc = aligned + 2;
        }

        // Record unbound opcodes (excluding stuff that's actually padding /
        // descriptor-region noise — we stop walking at return/branch as a
        // simple proxy for method boundary).
        if (!BOUND[op]) {
            try report.addUnbound(.{
                .class_hash = cls.hash,
                .method_hash = method_hash,
                .pc = @intCast(op_start - body_off),
                .op = op,
                .invoked_class = 0,
                .invoked_method = 0,
            });
        }

        // For INVOKE ops, decode descriptor to extract method hash.
        if (isInvoke(op) and operand == 2) {
            const aligned = (pc + 2) & ~@as(usize, 1);
            if (aligned + 2 <= cls.bytes.len) {
                const desc_off = std.mem.readInt(u16, cls.bytes[aligned..][0..2], .little);
                if (@as(usize, desc_off) + 4 <= cls.bytes.len) {
                    const m_hash = std.mem.readInt(u32, cls.bytes[desc_off..][0..4], .little);
                    // Try class-scoped name first; fall back to unscoped.
                    if (dbg.methodName(cls.hash, m_hash) == null) {
                        if (dbg.methodNameUnscoped(m_hash) == null) {
                            try report.addUnresolved(.{
                                .class_hash = cls.hash,
                                .method_hash = method_hash,
                                .pc = @intCast(op_start - body_off),
                                .op = op,
                                .invoked_class = 0,
                                .invoked_method = m_hash,
                            });
                        }
                    }
                }
            }
        }

        // Stop at first RETURN/IRETURN/ARETURN/LRETURN — same heuristic
        // as tools/disasm.zig::dumpBytecode (method bodies overlap in the
        // class record and this avoids walking into the next method).
        if (op == 0xAC or op == 0xB0 or op == 0xB1 or op == 0xE9 or op == 0xEA) break;

        if (next_pc <= pc) break; // safety: stop if no progress
        pc = next_pc;
    }
}

fn walkClass(report: *Report, cls: class_registry.ClassRecord, filter: ?u32) !void {
    if (filter) |want| if (cls.hash != want) return;
    const mc = cls.methodCount();
    var p = cls.firstMethodInfoOffset();
    var i: u16 = 0;
    while (i < mc) : (i += 1) {
        if (p + 12 > cls.bytes.len) break;
        const m_hash = std.mem.readInt(u32, cls.bytes[p..][0..4], .little);
        const flags = std.mem.readInt(u16, cls.bytes[p + 4 ..][0..2], .little);
        const body_off = std.mem.readInt(u16, cls.bytes[p + 8 ..][0..2], .little);
        const is_native = (flags & 0x100) != 0;
        if (!is_native) try walkMethod(report, cls, m_hash, body_off);
        p = (p + 15) & ~@as(usize, 3);
    }
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    var args = try std.process.argsWithAllocator(a);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse "samples/wallbreaker.exn";
    var class_filter: ?u32 = null;
    if (args.next()) |s| {
        const trimmed = if (std.mem.startsWith(u8, s, "0x")) s[2..] else s;
        class_filter = std.fmt.parseInt(u32, trimmed, 16) catch null;
    }

    const raw = try std.fs.cwd().readFileAlloc(a, path, 16 << 20);
    defer a.free(raw);
    const method_count = std.mem.readInt(u32, raw[0x34..][0..4], .little);
    const sentinel_off = 0x38 + 4 * method_count;
    const tail_start = std.mem.readInt(u32, raw[sentinel_off..][0..4], .little);

    var reg = class_registry.Registry.init(a);
    defer reg.deinit();
    const n = try reg.scanBuffer(raw, tail_start, .gamelet);

    var report = Report.init(a);
    defer report.deinit();

    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const hash = reg.by_index.get(i) orelse continue;
        const cls = reg.lookup(hash) orelse continue;
        try walkClass(&report, cls, class_filter);
    }

    // ── output ──
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    try out.print("=== coverage audit: {s} ({d} classes) ===\n\n", .{ path, n });

    try out.print("── UNBOUND OPCODES ──\n", .{});
    if (report.unbound.count() == 0) {
        try out.print("  (none — every opcode reached has a Zig handler)\n", .{});
    } else {
        var it = report.unbound.iterator();
        while (it.next()) |e| {
            const sites = e.value_ptr.items;
            try out.print("  op 0x{x:0>2}  ({d} site{s})\n", .{
                e.key_ptr.*, sites.len, if (sites.len == 1) "" else "s",
            });
            const cap = @min(sites.len, 5);
            for (sites[0..cap]) |s| {
                try out.print("    class=0x{x:0>8} method=0x{x:0>8} pc=0x{x:0>4}\n", .{
                    s.class_hash, s.method_hash, s.pc,
                });
            }
            if (sites.len > 5) try out.print("    ... +{d} more\n", .{sites.len - 5});
        }
    }

    try out.print("\n── UNRESOLVED INVOKES (method hash with no name in methodName/methodNameUnscoped) ──\n", .{});
    if (report.unresolved.count() == 0) {
        try out.print("  (none — every INVOKE target resolves)\n", .{});
    } else {
        var it = report.unresolved.iterator();
        while (it.next()) |e| {
            const sites = e.value_ptr.items;
            const m_hash: u32 = @truncate(e.key_ptr.*);
            try out.print("  method 0x{x:0>8}  ({d} call site{s})\n", .{
                m_hash, sites.len, if (sites.len == 1) "" else "s",
            });
            const cap = @min(sites.len, 5);
            for (sites[0..cap]) |s| {
                const op_name: []const u8 = switch (s.op) {
                    0xED => "INVOKEVIRTUAL_ALT",
                    0xEE => "INVOKEVIRTUAL",
                    0xEF => "INVOKE_OWN",
                    0xF0 => "INVOKESPECIAL",
                    0xF1 => "INVOKESTATIC_ALT",
                    0xF2 => "INVOKESTATIC",
                    else => "?",
                };
                try out.print("    {s:<18} from class=0x{x:0>8} method=0x{x:0>8} pc=0x{x:0>4}\n", .{
                    op_name, s.class_hash, s.method_hash, s.pc,
                });
            }
            if (sites.len > 5) try out.print("    ... +{d} more\n", .{sites.len - 5});
        }
    }

    try out.print("\n── totals ──\n", .{});
    var total_unbound: usize = 0;
    var it1 = report.unbound.iterator();
    while (it1.next()) |e| total_unbound += e.value_ptr.items.len;
    var total_unresolved: usize = 0;
    var it2 = report.unresolved.iterator();
    while (it2.next()) |e| total_unresolved += e.value_ptr.items.len;
    try out.print("  unbound opcode sites:        {d} (across {d} distinct opcode bytes)\n", .{
        total_unbound, report.unbound.count(),
    });
    try out.print("  unresolved INVOKE sites:     {d} (across {d} distinct method hashes)\n", .{
        total_unresolved, report.unresolved.count(),
    });
}

//! Static coverage audit — walks a gamelet's bytecode and reports:
//!   (1) opcodes our VM doesn't have a handler bound for (= would halt),
//!   (2) native methods this gamelet's bytecode invokes (or its own classes
//!       declare) whose `funcs_407AA2[]` idx has no real Zig handler
//!       (= would hit `defaultNativeStub` and silently push 0),
//!   (3) INVOKE call sites whose method-hash doesn't resolve to a name
//!       in `core/debug/names.zig::methodName()` (= unknown bytecode
//!       methods or unnamed natives).
//!
//! Usage:
//!   zig build coverage -- samples/wallbreaker.exn
//!   zig build coverage -- samples/wallbreaker.exn 0xd836a3ce
//!
//! Output is grouped:
//!   ── UNBOUND OPCODES ──    (op → list of call sites class.method@pc)
//!   ── UNBOUND NATIVES ──    (idx → name, canonical sub, call-site count)
//!   ── UNRESOLVED INVOKES ── ((class?, method_hash) → list of call sites)
//!
//! Opcode boundness comes from the REAL dispatch table
//! (`core.opcodes.buildOpTable()`), native boundness from the REAL entry
//! lists (`natives.bound_natives`) — neither can drift from the runtime.
//! Native declarations are read from the built-in classes
//! (`assets/unk_4494F0.bin`, same blob the VM boots from) plus the
//! gamelet's own classes; a native method's idx is the u32 at its
//! `body_offset`, exactly what `MethodInfo.nativeIndex()` reads.
//!
//! Distinct from the runtime trace: this finds gaps in code paths that
//! haven't been exercised at runtime, so we can pre-empt halts.

const std = @import("std");
const core = @import("core");
const natives = @import("natives");
const class_registry = core.class_registry;
const dbg = core.debug;

/// The real dispatch table. A slot still pointing at `unimpl` is unbound
/// (would halt the VM). Slots bound to `opNoop` are deliberate no-ops
/// (canonical empty slots) and count as bound.
const OP_TABLE: [256]core.opcodes.Handler = core.opcodes.buildOpTable();

fn opBound(op: u8) bool {
    return OP_TABLE[op] != core.opcodes.unimpl;
}

/// Per-opcode operand widths — straight from the op_specs single source
/// (encoding documented on `core.opcodes.OpSpec.width`).
const OPERANDS: [256]i8 = core.opcodes.operand_widths;

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

/// A native method declaration whose dispatch idx has no real Zig handler
/// (idx out of range, whole-class stub, or intra-range gap).
const NativeDecl = struct {
    class_hash: u32,
    method_hash: u32,
    idx: u32,
    origin: class_registry.ClassRecord.Origin,
    /// Direct INVOKE sites in the GAMELET's bytecode whose descriptor
    /// method-hash matches this decl. Matching is by hash only (receiver
    /// class unknown statically), so same-hash decls across classes each
    /// get the count — an over-approximation used purely as a priority
    /// hint. Indirect chains (gamelet → built-in bytecode → native) are
    /// NOT counted; a 0 here does not prove the native is unreachable.
    call_sites: u32 = 0,
};

const Report = struct {
    unbound: std.AutoArrayHashMap(u8, std.ArrayList(CallSite)),
    unresolved: std.AutoArrayHashMap(u64, std.ArrayList(CallSite)),
    /// Declared-but-stubbed natives (built-ins + gamelet classes).
    unbound_natives: std.ArrayList(NativeDecl),
    /// method_hash → indices into `unbound_natives` (hash collisions across
    /// classes are real — e.g. every class's `<init>` — hence a list).
    native_by_hash: std.AutoHashMap(u32, std.ArrayList(usize)),
    allocator: std.mem.Allocator,

    fn init(a: std.mem.Allocator) Report {
        return .{
            .unbound = std.AutoArrayHashMap(u8, std.ArrayList(CallSite)).init(a),
            .unresolved = std.AutoArrayHashMap(u64, std.ArrayList(CallSite)).init(a),
            .unbound_natives = .empty,
            .native_by_hash = std.AutoHashMap(u32, std.ArrayList(usize)).init(a),
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
        self.unbound_natives.deinit(self.allocator);
        var it3 = self.native_by_hash.valueIterator();
        while (it3.next()) |l| l.deinit(self.allocator);
        self.native_by_hash.deinit();
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
    fn addUnboundNative(self: *Report, decl: NativeDecl) !void {
        const list_idx = self.unbound_natives.items.len;
        try self.unbound_natives.append(self.allocator, decl);
        const gop = try self.native_by_hash.getOrPut(decl.method_hash);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, list_idx);
    }
    /// Called for every INVOKE descriptor hash seen in gamelet bytecode.
    fn countNativeCallSite(self: *Report, m_hash: u32) void {
        const list = self.native_by_hash.get(m_hash) orelse return;
        for (list.items) |ni| self.unbound_natives.items[ni].call_sites += 1;
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
        } else if (operand == -3 or operand == -4) {
            // NEWARRAY (-3) / MULTIANEWARRAY (-4): aligned u16 type tag
            // (MULTI has a u8 dim first), plus a second u16 element-class
            // ref iff the tag low byte is 0x99 (canonical sub_40EE4D
            // `v0 == 153`). Without this the walker reads the class-ref
            // bytes as opcodes and desyncs — the source of most phantom
            // "unbound opcode" reports across the corpus.
            const tag_off = if (operand == -3)
                (pc + 2) & ~@as(usize, 1)
            else
                (pc + 3) & ~@as(usize, 1);
            if (tag_off + 2 > cls.bytes.len) break;
            const tag = std.mem.readInt(u16, cls.bytes[tag_off..][0..2], .little);
            next_pc = tag_off + 2 + @as(usize, if ((tag & 0xFF) == 0x99) 2 else 0);
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
            } else if (op == 0xAB) {
                // LOOKUPSWITCH_W (opLookupswitchW): u16 default, u16 count,
                // pad to 4-byte boundary, u32 keys[count], u16 targets[count].
                // Distinct from 0xCC — mis-stepping this as the 0xCC layout
                // drifted the walker into the jump table (the source of the
                // Pikubi2/MutantAlert/AoE/MidtownMadness3 phantom opcodes).
                if (aligned + 4 > cls.bytes.len) break;
                const count = std.mem.readInt(u16, cls.bytes[aligned + 2 ..][0..2], .little);
                const keys_base = (aligned + 4 + 3) & ~@as(usize, 3);
                next_pc = keys_base + @as(usize, count) * 6; // u32 key + u16 target each
            } else { // LOOKUPSWITCH 0xCC — u16 default, u16 count, count×(u16 key, u16 target)
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
        if (!opBound(op)) {
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
                    // Count call sites against declared-but-stubbed natives.
                    report.countNativeCallSite(m_hash);
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

/// Pass A — record every native-flagged method whose dispatch idx has no
/// real Zig handler. Runs over ALL classes (built-ins + gamelet): natives
/// are declared by the built-in API classes, but which of them matter is
/// decided later by gamelet call sites (see NativeDecl.call_sites).
fn collectNatives(report: *Report, cls: class_registry.ClassRecord) !void {
    const mc = cls.methodCount();
    var p = cls.firstMethodInfoOffset();
    var i: u16 = 0;
    while (i < mc) : (i += 1) {
        if (p + 12 > cls.bytes.len) break;
        const m_hash = std.mem.readInt(u32, cls.bytes[p..][0..4], .little);
        const flags = std.mem.readInt(u16, cls.bytes[p + 4 ..][0..2], .little);
        const body_off = std.mem.readInt(u16, cls.bytes[p + 8 ..][0..2], .little);
        if ((flags & 0x100) != 0 and @as(usize, body_off) + 4 <= cls.bytes.len) {
            // For a native method the u32 at body_offset IS the
            // funcs_407AA2[] idx — same read as MethodInfo.nativeIndex().
            const idx = std.mem.readInt(u32, cls.bytes[body_off..][0..4], .little);
            if (idx >= natives.NATIVE_COUNT or !natives.bound_natives[idx]) {
                try report.addUnboundNative(.{
                    .class_hash = cls.hash,
                    .method_hash = m_hash,
                    .idx = idx,
                    .origin = cls.origin,
                });
            }
        }
        p = (p + 15) & ~@as(usize, 3);
    }
}

/// Pass B — bytecode walk (opcode audit + invoke resolution + native
/// call-site counting). Gamelet classes only.
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
        // Skip abstract methods (ACC_ABSTRACT 0x400) and any method with
        // no body: body_off == 0 means "no bytecode" — walking from
        // body_off+6 would disassemble the class-record header as
        // instructions (the source of the Pikubi/MotoGp/download1
        // phantom-opcode reports; verified all such sites are 0x400).
        const is_abstract = (flags & 0x400) != 0;
        if (!is_native and !is_abstract and body_off != 0) {
            try walkMethod(report, cls, m_hash, body_off);
        }
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

    // Built-ins first (same order as exen.boot) — they hold the native
    // method declarations. Missing blob = natives section degrades to
    // gamelet-declared natives only; warn but keep going.
    const builtins_blob: ?[]u8 = std.fs.cwd().readFileAlloc(a, "assets/unk_4494F0.bin", 1 << 20) catch null;
    defer if (builtins_blob) |b| a.free(b);
    var builtin_n: u32 = 0;
    if (builtins_blob) |blob| {
        builtin_n = try reg.scanBuffer(blob, 0, .builtin);
    }
    const gamelet_n = try reg.scanBuffer(raw, tail_start, .gamelet);
    const n: u32 = builtin_n + gamelet_n;

    var report = Report.init(a);
    defer report.deinit();

    // Pass A: native decls from every class (built-in + gamelet).
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const hash = reg.by_index.get(i) orelse continue;
        const cls = reg.lookup(hash) orelse continue;
        try collectNatives(&report, cls);
    }
    // Pass B: bytecode walk over the gamelet's classes only.
    i = 0;
    while (i < n) : (i += 1) {
        const hash = reg.by_index.get(i) orelse continue;
        const cls = reg.lookup(hash) orelse continue;
        if (cls.origin != .gamelet) continue;
        try walkClass(&report, cls, class_filter);
    }

    // ── output ──
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    try out.print("=== coverage audit: {s} ({d} gamelet classes + {d} built-ins) ===\n\n", .{ path, gamelet_n, builtin_n });
    if (builtins_blob == null) {
        try out.print("  ⚠ assets/unk_4494F0.bin not found — natives section covers\n", .{});
        try out.print("    gamelet-declared natives only (built-in decls unavailable)\n\n", .{});
    }

    try out.print("── UNBOUND OPCODES ──\n", .{});
    if (report.unbound.count() == 0) {
        try out.print("  (none — every opcode reached has a Zig handler)\n", .{});
    } else {
        var it = report.unbound.iterator();
        while (it.next()) |e| {
            const sites = e.value_ptr.items;
            try out.print("  op 0x{x:0>2} {s}  ({d} site{s})\n", .{
                e.key_ptr.*, core.opcodes.opName(e.key_ptr.*), sites.len, if (sites.len == 1) "" else "s",
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

    // Unbound natives: only rows this gamelet can plausibly hit — its
    // bytecode invokes the hash, or its own classes declare the native.
    // (A built-in decl with zero gamelet call sites is corpus-wide noise:
    // it would print identically for every gamelet.)
    try out.print("\n── UNBOUND NATIVES (would hit defaultNativeStub) ──\n", .{});
    {
        var rows: std.ArrayList(NativeDecl) = .empty;
        defer rows.deinit(a);
        for (report.unbound_natives.items) |d| {
            if (d.call_sites > 0 or d.origin == .gamelet) try rows.append(a, d);
        }
        std.mem.sort(NativeDecl, rows.items, {}, struct {
            fn lt(_: void, x: NativeDecl, y: NativeDecl) bool {
                return x.idx < y.idx;
            }
        }.lt);
        if (rows.items.len == 0) {
            try out.print("  (none — every native this gamelet touches has a real handler)\n", .{});
        } else for (rows.items) |d| {
            if (d.idx >= natives.NATIVE_COUNT) {
                try out.print("  idx {d:>3}  OUT OF RANGE — UnknownNative  declared by 0x{x:0>8} method=0x{x:0>8}\n", .{
                    d.idx, d.class_hash, d.method_hash,
                });
                continue;
            }
            // Verified (class,method)-scoped name first; else the
            // entries-derived table (single source with dispatch truth).
            const name = dbg.methodName(d.class_hash, d.method_hash) orelse natives.native_names[d.idx];
            try out.print("  idx {d:>3}  {s:<28} {s:<12} declared by {s} — {d} call site{s}{s}\n", .{
                d.idx,
                name,
                dbg.nativeSubName(d.idx),
                dbg.className(d.class_hash) orelse "0x????????",
                d.call_sites,
                if (d.call_sites == 1) "" else "s",
                if (d.call_sites == 0) " (declared by gamelet, never invoked directly)" else "",
            });
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
    var native_rows: usize = 0;
    var native_calls: usize = 0;
    for (report.unbound_natives.items) |d| {
        if (d.call_sites > 0 or d.origin == .gamelet) {
            native_rows += 1;
            native_calls += d.call_sites;
        }
    }
    try out.print("  unbound opcode sites:        {d} (across {d} distinct opcode bytes)\n", .{
        total_unbound, report.unbound.count(),
    });
    try out.print("  unbound natives touched:     {d} (with {d} direct call sites)\n", .{
        native_rows, native_calls,
    });
    try out.print("  unresolved INVOKE sites:     {d} (across {d} distinct method hashes)\n", .{
        total_unresolved, report.unresolved.count(),
    });
}

//! 2048-byte VM state buffer (mirrors `dword_45FE8C`).
//! Byte layout and init sequence ported from ref sub_402A20:5310-5360.

const std = @import("std");

pub const VmState = extern struct {
    bytes: [2048]u8 align(4),

    // ── named offsets ─────────────────────────────────────────────────────
    pub const off_pc: usize = 0;                   // u32 program counter — ref:5318
    pub const off_instr_word: usize = 4;           // 4 bytes: 00 85 00 80 — :5319-22
    pub const off_imsi: usize = 8;                 // "0033173440017" (13) — :5352
    pub const off_imsi_term: usize = 21;           // 0xFF              — :5353
    pub const off_b30: usize = 30;                 // = 0               — :5330
    pub const off_b33: usize = 33;                 // = 1               — :5333
    pub const off_oper_color: usize = 34;          // D5 0B 0A 4A       — :5346-49
    pub const off_oper: usize = 38;                // "oper3"           — :5354
    pub const off_oper_term: usize = 43;           // 0xFF              — :5355
    pub const off_bopr: usize = 70;                // "bopr3"           — :5356
    pub const off_bopr_term: usize = 75;           // 0xFF              — :5357
    pub const off_xcell: usize = 102;              // "XCELL"           — :5350
    pub const off_xcell_term: usize = 107;         // 0xFF              — :5351
    pub const off_counter_u32_120: usize = 120;    // = 53              — :5326
    pub const off_counter_u16_124: usize = 124;    // = 12              — :5325
    pub const off_b126: usize = 126;               // = 5               — :5327
    pub const off_method_name: usize = 128;        // "Begin news" (10) — :5323
    pub const off_method_name_term: usize = 138;   // 0xFF              — :5324
    pub const off_counter_u32_324: usize = 324;    // = 0               — :5343
    pub const off_currency_fusio: usize = 332;     // "FUSIO"           — :5344
    pub const off_currency_fusio_term: usize = 337;// 0xFF              — :5345
    pub const off_thread_a: usize = 348;           // = 0               — :5315
    pub const off_thread_run: usize = 349;         // = 2 (runnable)    — :5316
    pub const off_thread_b: usize = 350;           // = 0               — :5317
    pub const off_thread_c: usize = 351;           // = 0               — :5358
    pub const off_u16_352: usize = 352;            // = 0               — :5328
    pub const off_b354: usize = 354;               // = 0               — :5329
    pub const off_currency_euro: usize = 360;      // "EURO_\0\0" (7)   — :5341
    pub const off_currency_euro_term: usize = 367; // 0xFF              — :5342
    pub const off_thread_slots: usize = 400;       // 5 × 28-byte slots — :5335-40
    pub const off_method_count: usize = 540;       // u16 — read at sub_43D350:36959
    pub const off_u16_542: usize = 542;            // u16 = 0           — :5334
    pub const off_method_table: usize = 548;       // start of GameletRecord array

    pub const thread_slot_count: usize = 5;
    pub const thread_slot_stride: usize = 28;

    // ── typed accessors ───────────────────────────────────────────────────
    pub fn pc(self: *const VmState) u32 {
        return std.mem.readInt(u32, self.bytes[off_pc..][0..4], .little);
    }
    pub fn setPc(self: *VmState, v: u32) void {
        std.mem.writeInt(u32, self.bytes[off_pc..][0..4], v, .little);
    }
    pub fn methodCount(self: *const VmState) u16 {
        return std.mem.readInt(u16, self.bytes[off_method_count..][0..2], .little);
    }
    pub fn setMethodCount(self: *VmState, v: u16) void {
        std.mem.writeInt(u16, self.bytes[off_method_count..][0..2], v, .little);
    }

    // ── init (port of sub_402A20:5310-5360) ───────────────────────────────
    pub fn initBlank(self: *VmState) void {
        // line 5314 — memset(s+8, 0, 0x7F8): clears bytes 8..0x800.
        // We zero the whole buffer first; the explicit writes below fill it in.
        @memset(&self.bytes, 0);

        // PC + initial instruction word — 5318-22
        std.mem.writeInt(u32, self.bytes[off_pc..][0..4], 0, .little);
        self.bytes[4] = 0x00;
        self.bytes[5] = 0x85;
        self.bytes[6] = 0x00;
        self.bytes[7] = 0x80;

        // IMSI — 5352-53
        writeStr(self, off_imsi, "0033173440017");
        self.bytes[off_imsi_term] = 0xFF;

        // +30..+33: clear-then-set pattern — 5330-33
        self.bytes[30] = 0;
        self.bytes[31] = 0;
        self.bytes[32] = 0;
        self.bytes[33] = 1;

        // Operator color bytes — 5346-49
        self.bytes[34] = 0xD5;
        self.bytes[35] = 0x0B;
        self.bytes[36] = 0x0A;
        self.bytes[37] = 0x4A;

        // Operator strings — 5354-57
        writeStr(self, off_oper, "oper3");
        self.bytes[off_oper_term] = 0xFF;
        writeStr(self, off_bopr, "bopr3");
        self.bytes[off_bopr_term] = 0xFF;

        // Network identity — 5350-51
        writeStr(self, off_xcell, "XCELL");
        self.bytes[off_xcell_term] = 0xFF;

        // Counters — 5325-27
        std.mem.writeInt(u32, self.bytes[off_counter_u32_120..][0..4], 53, .little);
        std.mem.writeInt(u16, self.bytes[off_counter_u16_124..][0..2], 12, .little);
        self.bytes[off_b126] = 5;

        // Method-name slot — 5323-24
        writeStr(self, off_method_name, "Begin news");
        self.bytes[off_method_name_term] = 0xFF;

        // Currency strings — 5341-45
        const euro = "EURO_\x00\x00";
        @memcpy(self.bytes[off_currency_euro .. off_currency_euro + euro.len], euro);
        self.bytes[off_currency_euro_term] = 0xFF;
        std.mem.writeInt(u32, self.bytes[off_counter_u32_324..][0..4], 0, .little);
        writeStr(self, off_currency_fusio, "FUSIO");
        self.bytes[off_currency_fusio_term] = 0xFF;

        // Thread/runstate flags — 5315-17, 5358
        self.bytes[off_thread_a] = 0;
        self.bytes[off_thread_run] = 2;
        self.bytes[off_thread_b] = 0;
        self.bytes[off_thread_c] = 0;

        // Misc 352, 354 — 5328-29
        std.mem.writeInt(u16, self.bytes[off_u16_352..][0..2], 0, .little);
        self.bytes[off_b354] = 0;

        // u16 at 542 — 5334 (separate from method_count at 540)
        std.mem.writeInt(u16, self.bytes[off_u16_542..][0..2], 0, .little);

        // Five thread slots — 5335-40
        var i: usize = 0;
        while (i < thread_slot_count) : (i += 1) {
            const slot_off = off_thread_slots + thread_slot_stride * i;
            writeStr(self, slot_off, "20291");
            self.bytes[slot_off + 5] = 0xFF;
            const weight: u32 = (@as(u32, @intCast(10 * i + 1)) << 16) / 100;
            std.mem.writeInt(u32, self.bytes[slot_off + 24 ..][0..4], weight, .little);
        }
    }
};

pub const ThreadSlot = extern struct {
    label: [5]u8,       // +0..5  "20291"
    term: u8,           // +5     0xFF
    reserved: [18]u8,   // +6..24 zero
    weight_fp_16_16: u32, // +24..28
    comptime {
        std.debug.assert(@sizeOf(ThreadSlot) == 28);
    }
};

fn writeStr(self: *VmState, offset: usize, s: []const u8) void {
    @memcpy(self.bytes[offset .. offset + s.len], s);
}

test "initBlank produces expected byte pattern" {
    var vm: VmState = undefined;
    vm.initBlank();

    // PC = 0
    try std.testing.expectEqual(@as(u32, 0), vm.pc());

    // Initial instruction word: 00 85 00 80
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x85, 0x00, 0x80 }, vm.bytes[4..8]);

    // IMSI literal
    try std.testing.expectEqualStrings("0033173440017", vm.bytes[8..21]);
    try std.testing.expectEqual(@as(u8, 0xFF), vm.bytes[21]);

    // Operator color
    try std.testing.expectEqualSlices(u8, &.{ 0xD5, 0x0B, 0x0A, 0x4A }, vm.bytes[34..38]);

    // "oper3", "bopr3", "XCELL", "FUSIO", "Begin news"
    try std.testing.expectEqualStrings("oper3", vm.bytes[38..43]);
    try std.testing.expectEqualStrings("bopr3", vm.bytes[70..75]);
    try std.testing.expectEqualStrings("XCELL", vm.bytes[102..107]);
    try std.testing.expectEqualStrings("FUSIO", vm.bytes[332..337]);
    try std.testing.expectEqualStrings("Begin news", vm.bytes[128..138]);
    try std.testing.expectEqualStrings("EURO_", vm.bytes[360..365]);

    // Thread state = runnable
    try std.testing.expectEqual(@as(u8, 2), vm.bytes[VmState.off_thread_run]);

    // Counters
    try std.testing.expectEqual(@as(u32, 53), std.mem.readInt(u32, vm.bytes[120..124], .little));
    try std.testing.expectEqual(@as(u16, 12), std.mem.readInt(u16, vm.bytes[124..126], .little));
    try std.testing.expectEqual(@as(u8, 5), vm.bytes[126]);

    // Five thread slots: label "20291", weight fixed-point 16.16 = ((10i+1) << 16) / 100
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const slot = 400 + 28 * i;
        try std.testing.expectEqualStrings("20291", vm.bytes[slot .. slot + 5]);
        try std.testing.expectEqual(@as(u8, 0xFF), vm.bytes[slot + 5]);
        const got = std.mem.readInt(u32, vm.bytes[slot + 24 ..][0..4], .little);
        const expected: u32 = (@as(u32, @intCast(10 * i + 1)) << 16) / 100;
        try std.testing.expectEqual(expected, got);
    }

    // Method count = 0 (from memset)
    try std.testing.expectEqual(@as(u16, 0), vm.methodCount());

    // bytes[33] = 1 (explicitly set after zero)
    try std.testing.expectEqual(@as(u8, 1), vm.bytes[33]);
}

test "ThreadSlot sizeof" {
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(ThreadSlot));
}

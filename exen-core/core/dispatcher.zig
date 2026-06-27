//! Opcode dispatch core. Three layers mirror ref:
//!   invoke   ← sub_436E00:33765 (publish-with-handler-lookup wrapper)
//!   publish  ← sub_436F58:33828 (pack 3-DWORD packet, call dispatch)
//!   dispatch ← sub_402F10:5450  (the actual function-pointer indirection)

const std = @import("std");

/// 12-byte stack-local packet built by sub_436F58:33832-33836.
pub const OpcodeArgs = extern struct {
    opcode: u32,
    a: u32,
    b: u32,
    comptime {
        std.debug.assert(@sizeOf(OpcodeArgs) == 12);
    }
};

pub const Handler = *const fn (*OpcodeArgs) callconv(.c) i32;

/// 256-entry function-pointer table indexed by `(opcode >> 8) & 0xFF`.
/// Mirrors `dword_449298[]` in ref.
var handler_table: [256]?Handler = [_]?Handler{null} ** 256;

pub fn registerHandler(group: u8, h: Handler) void {
    handler_table[group] = h;
}

pub fn clearHandlers() void {
    handler_table = [_]?Handler{null} ** 256;
}

/// Port of sub_402F10:5450.
pub fn dispatch(args: *OpcodeArgs) i32 {
    const group: u8 = @truncate((args.opcode & 0xFF00) >> 8);
    if (group == 0) return -1;
    const h = handler_table[group] orelse {
        std.log.scoped(.dispatch).warn(
            "opcode 0x{x:0>4}: no handler for group 0x{x:0>2}",
            .{ args.opcode, group },
        );
        return -1;
    };
    const rv = h(args);
    if (rv == 2 or rv == 10) {
        // sub_402F10:5462 — savegame escalation. Stubbed.
        std.log.scoped(.dispatch).warn(
            "opcode 0x{x:0>4} returned {d} (would escalate)",
            .{ args.opcode, rv },
        );
    }
    return rv;
}

/// Port of sub_436F58:33828.
pub fn publish(opcode: u32, a: u32, b: u32) i32 {
    var args = OpcodeArgs{ .opcode = opcode, .a = a, .b = b };
    const rv = dispatch(&args);
    if (rv == 2 and opcode != 1537) {
        // sub_436F58:33838 — C calls _ms_p5_mp_test_fdiv() (noreturn). Stub: log+exit.
        std.log.scoped(.dispatch).err("fatal: opcode 0x{x:0>4} returned 2", .{opcode});
        std.process.exit(1);
    }
    return rv;
}

/// Port of sub_436E00:33765. In the C, this looks up an event ID via
/// sub_436F0F (dword_458094/458098 reverse map). For this milestone we
/// treat opcode IDs as identity — the lookup table content isn't recovered
/// yet (see plan: HandlerLookup deferred).
pub fn invoke(opcode: u32, a: u32, b: u32) i32 {
    return publish(opcode, a, b);
}

// ── declared-only structs (initialized but unused this milestone) ──────────

/// 24-byte font glyph cache (sub_4370D9:33881) — declared but unused this
/// milestone. The original layout assumes 32-bit pointers (the source binary is
/// x86); on a 64-bit host the size grows because of pointer width. We don't
/// assert the size — the struct is here to document the shape, not to match
/// the C binary layout (no font cache is shared with the gamelet yet).
pub const FontCache = extern struct {
    kind: u32,
    bpp_or_rows: u32 = 8,
    glyph_count: u32 = 16,
    src_size: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
    src_ptr: ?[*]u8 = null,
    glyphs_ptr: ?[*]u8 = null,
};

// ── tests ──────────────────────────────────────────────────────────────────

fn testHandler(args: *OpcodeArgs) callconv(.c) i32 {
    _ = args;
    return 1;
}

fn testHandlerReturnsTwo(args: *OpcodeArgs) callconv(.c) i32 {
    _ = args;
    return 2;
}

test "dispatch routes by opcode high byte" {
    clearHandlers();
    defer clearHandlers();

    registerHandler(6, testHandler);
    var args = OpcodeArgs{ .opcode = 0x0600, .a = 42, .b = 0 };
    try std.testing.expectEqual(@as(i32, 1), dispatch(&args));

    // No handler registered for group 7 → returns -1.
    var args7 = OpcodeArgs{ .opcode = 0x0700, .a = 0, .b = 0 };
    try std.testing.expectEqual(@as(i32, -1), dispatch(&args7));
}

test "dispatch group 0 returns -1" {
    clearHandlers();
    defer clearHandlers();

    registerHandler(0, testHandler); // even if registered, group 0 is rejected
    var args = OpcodeArgs{ .opcode = 0x0042, .a = 0, .b = 0 };
    try std.testing.expectEqual(@as(i32, -1), dispatch(&args));
}

test "publish escalation: opcode 1537 with rv=2 does NOT exit" {
    clearHandlers();
    defer clearHandlers();

    registerHandler(6, testHandlerReturnsTwo);
    // 1537 = 0x601, group 6. With rv == 2, publish would normally exit, but
    // opcode == 1537 is the documented exception (sub_436F58:33838).
    const rv = publish(1537, 0, 0);
    try std.testing.expectEqual(@as(i32, 2), rv);
}

test "OpcodeArgs sizeof" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(OpcodeArgs));
}

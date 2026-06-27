//! Rotating scratch buffers for class/method hash formatting in log
//! lines. We need a ring because a single `log.info(...)` call may
//! invoke `classStr` / `methodStr` MORE THAN ONCE in one args list
//! (e.g. "super of X" lines call `classStr` twice). The formatter
//! reads slices AFTER all args are evaluated, so a single buffer
//! would corrupt the first result.
//!
//! 8 slots × 80 bytes is plenty for any single log line in practice.

const std = @import("std");
const dbg = @import("../debug/names.zig");

const FmtRing = struct {
    threadlocal var bufs: [8][80]u8 = undefined;
    threadlocal var cursor: u3 = 0;

    fn nextBuf() *[80]u8 {
        const i = cursor;
        cursor +%= 1;
        return &bufs[i];
    }
};

/// Format a class hash as "name(0xHEX)" when known, else just the hex.
pub fn classStr(hash: u32) []const u8 {
    const buf = FmtRing.nextBuf();
    if (dbg.className(hash)) |n| {
        return std.fmt.bufPrint(buf, "{s}(0x{x:0>8})", .{ n, hash }) catch "?";
    }
    return std.fmt.bufPrint(buf, "0x{x:0>8}", .{hash}) catch "?";
}

/// Format a method hash. Resolves the name scoped to the receiver's
/// class — same hash can name different methods in different classes,
/// and the VM dispatches per class, so the formatter mirrors that.
pub fn methodStr(class_hash: u32, method_hash: u32) []const u8 {
    const buf = FmtRing.nextBuf();
    if (dbg.methodName(class_hash, method_hash)) |n| {
        return std.fmt.bufPrint(buf, "{s}(0x{x:0>8})", .{ n, method_hash }) catch "?";
    }
    return std.fmt.bufPrint(buf, "0x{x:0>8}", .{method_hash}) catch "?";
}

/// Format a field hash scoped to the owning class (same rationale as
/// methodStr).
pub fn fieldStr(class_hash: u32, field_hash: u32) []const u8 {
    const buf = FmtRing.nextBuf();
    if (dbg.fieldName(class_hash, field_hash)) |n| {
        return std.fmt.bufPrint(buf, "{s}(0x{x:0>8})", .{ n, field_hash }) catch "?";
    }
    return std.fmt.bufPrint(buf, "0x{x:0>8}", .{field_hash}) catch "?";
}

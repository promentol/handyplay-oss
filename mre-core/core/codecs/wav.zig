//! Minimal RIFF/WAVE reader for the audio engine: PCM (format 1) only,
//! 8-bit unsigned or 16-bit signed, mono or stereo, any sample rate.
//! Returns a view into the caller's buffer (no allocation) — the engine copies
//! what it needs to keep.
const std = @import("std");

pub const Wav = struct {
    channels: u8, // 1 or 2
    bits: u8, // 8 or 16
    sample_rate: u32,
    data: []const u8, // raw PCM bytes (little-endian for 16-bit)

    pub fn frameCount(self: Wav) usize {
        const bytes_per_frame = @as(usize, self.channels) * (self.bits / 8);
        return if (bytes_per_frame == 0) 0 else self.data.len / bytes_per_frame;
    }

    pub fn durationMs(self: Wav) u32 {
        if (self.sample_rate == 0) return 0;
        return @intCast(self.frameCount() * 1000 / self.sample_rate);
    }
};

fn readU32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}
fn readU16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .little);
}

/// Parse a RIFF/WAVE buffer. Returns null for anything that isn't plain PCM
/// (compressed WAV falls back to the caller's duration-only path).
pub fn parse(buf: []const u8) ?Wav {
    if (buf.len < 44) return null;
    if (!std.mem.eql(u8, buf[0..4], "RIFF") or !std.mem.eql(u8, buf[8..12], "WAVE")) return null;

    var w: Wav = .{ .channels = 0, .bits = 0, .sample_rate = 0, .data = &.{} };
    var pos: usize = 12;
    while (pos + 8 <= buf.len) {
        const id = buf[pos .. pos + 4];
        const size: usize = readU32(buf[pos + 4 ..]);
        const body_end = @min(pos + 8 + size, buf.len);
        const body = buf[pos + 8 .. body_end];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return null;
            const format = readU16(body[0..]);
            if (format != 1) return null; // PCM only
            const ch = readU16(body[2..]);
            const bits = readU16(body[14..]);
            if ((ch != 1 and ch != 2) or (bits != 8 and bits != 16)) return null;
            w.channels = @intCast(ch);
            w.bits = @intCast(bits);
            w.sample_rate = readU32(body[4..]);
        } else if (std.mem.eql(u8, id, "data")) {
            w.data = body;
        }
        pos += 8 + size + (size & 1); // chunks are word-aligned
    }
    if (w.channels == 0 or w.sample_rate == 0 or w.data.len == 0) return null;
    return w;
}

test "parse 16-bit mono PCM" {
    var buf: [44 + 8]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + 8, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, buf[22..24], 1, .little); // mono
    std.mem.writeInt(u32, buf[24..28], 8000, .little); // rate
    std.mem.writeInt(u32, buf[28..32], 16000, .little); // byte rate
    std.mem.writeInt(u16, buf[32..34], 2, .little); // block align
    std.mem.writeInt(u16, buf[34..36], 16, .little); // bits
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], 8, .little);
    for (buf[44..52], 0..) |*b, i| b.* = @intCast(i);

    const w = parse(&buf) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u8, 1), w.channels);
    try std.testing.expectEqual(@as(u8, 16), w.bits);
    try std.testing.expectEqual(@as(u32, 8000), w.sample_rate);
    try std.testing.expectEqual(@as(usize, 4), w.frameCount());
    try std.testing.expectEqual(@as(u32, 0), w.durationMs()); // 4 frames @8k -> <1ms
}

test "reject non-PCM" {
    var buf: [44]u8 = std.mem.zeroes([44]u8);
    @memcpy(buf[0..4], "RIFF");
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 0x11, .little); // ADPCM
    try std.testing.expect(parse(&buf) == null);
}

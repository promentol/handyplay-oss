//! Catalog persistence — the launcher-visible game registry + the
//! 4-byte registration token.
//!
//! Canonical keeps both inside the NVRAM blob (`dword_45FE8C`): records
//! at +548 (u16 count at +540; variable-length records with game id at
//! +12, downloaded flag at +24, device fingerprint at +36) and the
//! registration token at +30..33 (boot default {0,0,0,1} = registered).
//! Game validity additionally requires the record's fingerprint to
//! match the device (`sub_423BD0` / `sub_423C1F`); since we control
//! both writer and reader, our records are always fingerprint-valid.
//!
//! We persist an explicit file instead (see exen.zig for the I/O):
//!   "CAT1" magic | token[4] | u16 count | count × { u16 id, u8 downloaded }

const std = @import("std");

pub const MAGIC = "CAT1";
pub const MAX_RECORDS = 64;

pub const Record = struct { id: u16, downloaded: bool };

pub const State = struct {
    records: [MAX_RECORDS]Record = undefined,
    count: u16 = 0,
    /// Canonical boot default {0,0,0,1} — a fresh device reads as
    /// registered (isUserRegistred ORs the four bytes).
    reg_token: [4]u8 = .{ 0, 0, 0, 1 },

    pub fn find(self: *const State, id: u16) ?Record {
        for (self.records[0..self.count]) |r| {
            if (r.id == id) return r;
        }
        return null;
    }

    /// Insert or update a record (canonical sub_4156C9 append /
    /// re-mark). Silently drops inserts past MAX_RECORDS.
    pub fn put(self: *State, id: u16, downloaded: bool) void {
        for (self.records[0..self.count]) |*r| {
            if (r.id == id) {
                r.downloaded = downloaded;
                return;
            }
        }
        if (self.count < MAX_RECORDS) {
            self.records[self.count] = .{ .id = id, .downloaded = downloaded };
            self.count += 1;
        }
    }

    pub fn isRegistered(self: *const State) bool {
        return (self.reg_token[0] | self.reg_token[1] |
            self.reg_token[2] | self.reg_token[3]) != 0;
    }

    /// Serialize into `buf`; returns the used slice. Buffer must hold
    /// at least 4 + 4 + 2 + 3*MAX_RECORDS bytes.
    pub fn serialize(self: *const State, buf: []u8) []u8 {
        @memcpy(buf[0..4], MAGIC);
        @memcpy(buf[4..8], &self.reg_token);
        std.mem.writeInt(u16, buf[8..10], self.count, .little);
        var off: usize = 10;
        for (self.records[0..self.count]) |r| {
            std.mem.writeInt(u16, buf[off..][0..2], r.id, .little);
            buf[off + 2] = @intFromBool(r.downloaded);
            off += 3;
        }
        return buf[0..off];
    }

    /// Parse from `bytes`; returns a default state on any mismatch
    /// (missing/corrupt file = fresh device, matching canonical's
    /// blob-reinit-on-bad-signature behaviour).
    pub fn parse(bytes: []const u8) State {
        var st: State = .{};
        if (bytes.len < 10 or !std.mem.eql(u8, bytes[0..4], MAGIC)) return st;
        @memcpy(&st.reg_token, bytes[4..8]);
        const n = @min(std.mem.readInt(u16, bytes[8..10], .little), MAX_RECORDS);
        var off: usize = 10;
        var i: u16 = 0;
        while (i < n and off + 3 <= bytes.len) : (i += 1) {
            st.records[st.count] = .{
                .id = std.mem.readInt(u16, bytes[off..][0..2], .little),
                .downloaded = bytes[off + 2] != 0,
            };
            st.count += 1;
            off += 3;
        }
        return st;
    }
};

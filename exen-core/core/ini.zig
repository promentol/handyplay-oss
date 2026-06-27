//! Minimal INI parser for simulator.ini.
//! Sections are `[Name]` headers; entries are `Key=Value` lines. Lines starting
//! with `;` are comments. Whitespace around `=` is stripped. Values are stored
//! as raw strings; callers convert via getInt / getU32 as needed.

const std = @import("std");

const Section = std.StringHashMapUnmanaged([]const u8);

pub const Ini = struct {
    parent_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    sections: std.StringHashMapUnmanaged(Section),

    /// Free everything and destroy the Ini itself. Pair with `loadFromFile`.
    pub fn deinit(self: *Ini) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self);
    }

    /// Heap-allocates an Ini so its arena's address stays stable across
    /// borrows of `arena.allocator()`. Callers MUST call `ini.deinit()` to
    /// release both the arena and the Ini wrapper.
    pub fn loadFromFile(parent_allocator: std.mem.Allocator, path: []const u8) !*Ini {
        const ini = try parent_allocator.create(Ini);
        errdefer parent_allocator.destroy(ini);
        ini.* = .{
            .parent_allocator = parent_allocator,
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .sections = .empty,
        };
        errdefer ini.arena.deinit();

        const a = ini.arena.allocator();
        const data = try std.fs.cwd().readFileAlloc(a, path, 16 * 1024 * 1024);

        var cur_section: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            const line = trim(raw);
            if (line.len == 0) continue;
            if (line[0] == ';' or line[0] == '#') continue;

            if (line[0] == '[') {
                const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
                cur_section = line[1..end];
                if (ini.sections.get(cur_section.?) == null) {
                    try ini.sections.put(a, cur_section.?, .empty);
                }
                continue;
            }

            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = trim(line[0..eq]);
            const value = trim(line[eq + 1 ..]);
            if (cur_section) |sec_name| {
                if (ini.sections.getPtr(sec_name)) |sec| {
                    try sec.put(a, key, value);
                }
            }
        }

        return ini;
    }

    pub fn get(self: *const Ini, section: []const u8, key: []const u8) ?[]const u8 {
        const sec = self.sections.get(section) orelse return null;
        return sec.get(key);
    }

    pub fn getInt(self: *const Ini, section: []const u8, key: []const u8, default: i32) i32 {
        const raw = self.get(section, key) orelse return default;
        return std.fmt.parseInt(i32, raw, 10) catch default;
    }

    pub fn getU32(self: *const Ini, section: []const u8, key: []const u8, default: u32) u32 {
        const raw = self.get(section, key) orelse return default;
        return std.fmt.parseInt(u32, raw, 10) catch default;
    }

    pub fn sectionCount(self: *const Ini) usize {
        return self.sections.count();
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

test "parses simulator.ini-ish content" {
    const content =
        \\; comment
        \\[Path]
        \\FLASH_PATH=flash\
        \\SERVER_PATH=server\
        \\
        \\[Manuf.005]
        \\NAME=TRIUM M6B
        \\EXEN_VM_SIZE_SMALL=18050
        \\EXEN_DISPLAY_WIDTH=128
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.ini", .data = content });

    var path_buf: [256]u8 = undefined;
    const path = try tmp.dir.realpath("t.ini", &path_buf);

    const ini = try Ini.loadFromFile(std.testing.allocator, path);
    defer ini.deinit();

    try std.testing.expectEqualStrings("flash\\", ini.get("Path", "FLASH_PATH").?);
    try std.testing.expectEqualStrings("TRIUM M6B", ini.get("Manuf.005", "NAME").?);
    try std.testing.expectEqual(@as(u32, 18050), ini.getU32("Manuf.005", "EXEN_VM_SIZE_SMALL", 0));
    try std.testing.expectEqual(@as(u32, 128), ini.getU32("Manuf.005", "EXEN_DISPLAY_WIDTH", 0));
    try std.testing.expectEqual(@as(i32, 42), ini.getInt("Path", "MISSING", 42));
}

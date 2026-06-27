//! Host file layer (open/close/read/write/seek/getLen/remove/rename/mkDir/rmDir/
//! info/opendir/readdir/closedir).
//!
//! File and directory handles are small 1-based integers (0 == failure for open,
//! -1 == MR_FAILED for opendir). Paths are resolved relative to the process cwd,
//! so frontends chdir into the asset root before booting.
const std = @import("std");

pub const MR_SUCCESS: i32 = 0;
pub const MR_FAILED: i32 = -1;

// fileLib.h open modes
pub const MR_FILE_RDONLY: u32 = 1;
pub const MR_FILE_WRONLY: u32 = 2;
pub const MR_FILE_RDWR: u32 = 4;
pub const MR_FILE_CREATE: u32 = 8;

// info() results
pub const MR_IS_FILE: i32 = 1;
pub const MR_IS_DIR: i32 = 2;
pub const MR_IS_INVALID: i32 = 8;

// seek methods (MR_SEEK_SET/CUR/END == 0/1/2 == posix SEEK_*)

pub const FileSystem = struct {
    gpa: std.mem.Allocator,
    files: std.AutoHashMapUnmanaged(i32, std.posix.fd_t) = .{},
    dirs: std.AutoHashMapUnmanaged(i32, *std.c.DIR) = .{},
    namebuf: [256]u8 = undefined, // backing for the returned d_name
    file_counter: i32 = 0,
    dir_counter: i32 = 0,

    pub fn init(gpa: std.mem.Allocator) FileSystem {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FileSystem) void {
        var fit = self.files.valueIterator();
        while (fit.next()) |fd| std.posix.close(fd.*);
        self.files.deinit(self.gpa);
        var dit = self.dirs.valueIterator();
        while (dit.next()) |d| _ = std.c.closedir(d.*);
        self.dirs.deinit(self.gpa);
    }

    /// Returns a handle >= 1, or 0 on failure.
    pub fn open(self: *FileSystem, path: []const u8, mode: u32) i32 {
        var flags: std.posix.O = .{};
        if (mode & MR_FILE_WRONLY != 0) flags.ACCMODE = .WRONLY;
        if (mode & MR_FILE_RDWR != 0) flags.ACCMODE = .RDWR;
        if (mode & MR_FILE_RDONLY != 0 and (mode & (MR_FILE_WRONLY | MR_FILE_RDWR)) == 0) flags.ACCMODE = .RDONLY;
        if (mode & MR_FILE_CREATE != 0) flags.CREAT = true;

        const fd = std.posix.openatZ(std.fs.cwd().fd, toZ(path) catch return 0, flags, 0o777) catch return 0;
        self.file_counter += 1;
        self.files.put(self.gpa, self.file_counter, fd) catch {
            std.posix.close(fd);
            return 0;
        };
        return self.file_counter;
    }

    pub fn close(self: *FileSystem, f: i32) i32 {
        const fd = self.files.get(f) orelse return MR_FAILED;
        _ = self.files.remove(f);
        if (f == self.file_counter) self.file_counter -= 1;
        std.posix.close(fd);
        return MR_SUCCESS;
    }

    pub fn seek(self: *FileSystem, f: i32, pos: i32, method: u32) i32 {
        const fd = self.files.get(f) orelse return MR_FAILED;
        const whence: i32 = @intCast(method);
        const r = lseek(fd, pos, whence);
        return if (r < 0) MR_FAILED else MR_SUCCESS;
    }

    pub fn read(self: *FileSystem, f: i32, buf: []u8) i32 {
        const fd = self.files.get(f) orelse return MR_FAILED;
        const n = std.posix.read(fd, buf) catch return MR_FAILED;
        return @intCast(n);
    }

    pub fn write(self: *FileSystem, f: i32, buf: []const u8) i32 {
        const fd = self.files.get(f) orelse return MR_FAILED;
        const n = std.posix.write(fd, buf) catch return MR_FAILED;
        return @intCast(n);
    }

    pub fn getLen(_: *FileSystem, path: []const u8) i32 {
        const st = std.fs.cwd().statFile(path) catch return -1;
        return @intCast(st.size);
    }

    pub fn remove(_: *FileSystem, path: []const u8) i32 {
        std.fs.cwd().deleteFile(path) catch return MR_FAILED;
        return MR_SUCCESS;
    }

    pub fn rename(_: *FileSystem, oldname: []const u8, newname: []const u8) i32 {
        std.fs.cwd().rename(oldname, newname) catch return MR_FAILED;
        return MR_SUCCESS;
    }

    pub fn mkDir(_: *FileSystem, path: []const u8) i32 {
        std.fs.cwd().makeDir(path) catch |e| switch (e) {
            error.PathAlreadyExists => return MR_SUCCESS,
            else => return MR_FAILED,
        };
        return MR_SUCCESS;
    }

    pub fn rmDir(_: *FileSystem, path: []const u8) i32 {
        std.fs.cwd().deleteDir(path) catch return MR_FAILED;
        return MR_SUCCESS;
    }

    pub fn info(_: *FileSystem, path: []const u8) i32 {
        const st = std.fs.cwd().statFile(path) catch return MR_IS_INVALID;
        return switch (st.kind) {
            .directory => MR_IS_DIR,
            .file => MR_IS_FILE,
            else => MR_IS_INVALID,
        };
    }

    pub fn opendir(self: *FileSystem, path: []const u8) i32 {
        const d = std.c.opendir(toZ(path) catch return MR_FAILED) orelse return MR_FAILED;
        self.dir_counter += 1;
        self.dirs.put(self.gpa, self.dir_counter, d) catch {
            _ = std.c.closedir(d);
            return MR_FAILED;
        };
        return self.dir_counter;
    }

    /// Returns the next entry name (into a shared buffer), or null.
    pub fn readdir(self: *FileSystem, f: i32) ?[]const u8 {
        const d = self.dirs.get(f) orelse return null;
        const ent = std.c.readdir(d) orelse return null;
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        const n = @min(name.len, self.namebuf.len - 1);
        @memcpy(self.namebuf[0..n], name[0..n]);
        self.namebuf[n] = 0;
        return self.namebuf[0..n];
    }

    pub fn closedir(self: *FileSystem, f: i32) i32 {
        const d = self.dirs.get(f) orelse return MR_FAILED;
        _ = self.dirs.remove(f);
        if (f == self.dir_counter) self.dir_counter -= 1;
        _ = std.c.closedir(d);
        return MR_SUCCESS;
    }
};

// std.posix.lseek_* are split per-whence; provide one entry point.
fn lseek(fd: std.posix.fd_t, offset: i32, whence: i32) i64 {
    return switch (whence) {
        0 => blk: {
            std.posix.lseek_SET(fd, @intCast(@max(offset, 0))) catch break :blk -1;
            break :blk 0;
        },
        1 => blk: {
            std.posix.lseek_CUR(fd, offset) catch break :blk -1;
            break :blk 0;
        },
        2 => blk: {
            std.posix.lseek_END(fd, offset) catch break :blk -1;
            break :blk 0;
        },
        else => -1,
    };
}

var z_scratch: [1024]u8 = undefined;
fn toZ(path: []const u8) ![:0]const u8 {
    if (path.len >= z_scratch.len) return error.NameTooLong;
    @memcpy(z_scratch[0..path.len], path);
    z_scratch[path.len] = 0;
    return z_scratch[0..path.len :0];
}

//! Every file system call the builtins make, relative to the current
//! directory. A freestanding build has no file system, so each one fails
//! there with `error.FileError` and the standard library's file code is
//! never compiled in.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const available = !build_options.freestanding and builtin.os.tag != .freestanding;

pub const FsError = error{ FileError, OutOfMemory };

fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

/// The file's contents, owned by `allocator`.
pub fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) FsError![]u8 {
    if (!available) return error.FileError;
    const file = cwd().openFile(io, path, .{}) catch return error.FileError;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &read_buf);
    var contents: std.ArrayList(u8) = .empty;
    errdefer contents.deinit(allocator);
    file_reader.interface.appendRemainingUnlimited(allocator, &contents) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FileError,
    };
    return contents.toOwnedSlice(allocator);
}

/// Replace the file's contents with `bytes`, creating it if need be.
pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) FsError!void {
    if (!available) return error.FileError;
    const file = cwd().createFile(io, path, .{}) catch return error.FileError;
    defer file.close(io);
    var write_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(file, io, &write_buf);
    file_writer.interface.writeAll(bytes) catch return error.FileError;
    file_writer.interface.flush() catch return error.FileError;
}

pub fn modified(io: std.Io, path: []const u8) FsError!std.Io.Timestamp {
    if (!available) return error.FileError;
    const info = cwd().statFile(io, path, .{}) catch return error.FileError;
    return info.mtime;
}

/// The absolute name of the file, owned by `allocator`. WASI names files
/// inside its preopened directories and has no realpath, so there it is
/// the name given, once the file is found.
pub fn realPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) FsError![:0]u8 {
    if (!available) return error.FileError;
    if (builtin.os.tag == .wasi) {
        _ = cwd().statFile(io, path, .{}) catch return error.FileError;
        return allocator.dupeSentinel(u8, path, 0);
    }
    return cwd().realPathFileAlloc(io, path, allocator) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FileError,
    };
}

pub fn deleteFile(io: std.Io, path: []const u8) FsError!void {
    if (!available) return error.FileError;
    cwd().deleteFile(io, path) catch return error.FileError;
}

pub fn deleteDirectory(io: std.Io, path: []const u8) FsError!void {
    if (!available) return error.FileError;
    cwd().deleteDir(io, path) catch return error.FileError;
}

pub fn rename(io: std.Io, from: []const u8, to: []const u8) FsError!void {
    if (!available) return error.FileError;
    cwd().rename(from, cwd(), to, io) catch return error.FileError;
}

/// True when a directory had to be made, false when they all existed.
pub fn createDirectories(io: std.Io, path: []const u8) FsError!bool {
    if (!available) return error.FileError;
    const status = cwd().createDirPathStatus(io, path, .default_dir) catch return error.FileError;
    return status == .created;
}

/// The names in the directory, each owned by `allocator`, with a `/`
/// after the name of a subdirectory.
pub fn directoryEntries(io: std.Io, allocator: std.mem.Allocator, path: []const u8) FsError![][]u8 {
    if (!available) return error.FileError;
    var dir = cwd().openDir(io, path, .{ .iterate = true }) catch return error.FileError;
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (it.next(io) catch return error.FileError) |entry| {
        const slash: []const u8 = if (entry.kind == .directory) "/" else "";
        try names.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ entry.name, slash }));
    }
    return names.toOwnedSlice(allocator);
}

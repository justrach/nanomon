//! Config IO shared by client setup. No symlink traversal, bounded reads,
//! private exclusive backups, optimistic change detection and atomic replace.
const std = @import("std");
const max_bytes = 1 << 20;
const windows = @import("builtin").os.tag == .windows;
const private_dir: std.Io.File.Permissions = if (windows) .default_dir else .fromMode(0o700);
const private_file: std.Io.File.Permissions = if (windows) .default_file else .fromMode(0o600);

pub const Store = struct {
    home: std.Io.Dir,
    io: std.Io,
    gpa: std.mem.Allocator,

    const Parent = struct { dir: std.Io.Dir, name: []const u8 };

    fn parent(s: Store, path: []const u8, create: bool) !Parent {
        if (std.fs.path.isAbsolute(path)) return error.UnsafePath;
        var dir = try s.home.openDir(s.io, ".", .{ .follow_symlinks = false });
        errdefer dir.close(s.io);
        var parts = std.mem.tokenizeScalar(u8, std.fs.path.dirname(path) orelse "", '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafePath;
            const next = dir.openDir(s.io, part, .{ .follow_symlinks = false }) catch |err| blk: {
                if (err != error.FileNotFound or !create) return err;
                dir.createDir(s.io, part, private_dir) catch |e| if (e != error.PathAlreadyExists) return e;
                break :blk try dir.openDir(s.io, part, .{ .follow_symlinks = false });
            };
            dir.close(s.io);
            dir = next;
        }
        const name = std.fs.path.basename(path);
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.UnsafePath;
        return .{ .dir = dir, .name = name };
    }

    /// The caller's arena owns the returned bytes; null means absent only.
    pub fn read(s: Store, path: []const u8) !?[]u8 {
        const p = s.parent(path, false) catch |err| return if (err == error.FileNotFound) null else err;
        defer p.dir.close(s.io);
        const file = p.dir.openFile(s.io, p.name, .{ .follow_symlinks = false, .allow_directory = false }) catch |err|
            return if (err == error.FileNotFound) null else err;
        defer file.close(s.io);
        if ((try file.stat(s.io)).kind != .file) return error.UnsafePath;
        var buf: [4096]u8 = undefined;
        var reader = file.readerStreaming(s.io, &buf);
        return try reader.interface.allocRemaining(s.gpa, .limited(max_bytes));
    }

    pub fn matches(s: Store, path: []const u8, old: ?[]const u8) !bool {
        const now = try s.read(path);
        defer if (now) |b| s.gpa.free(b);
        if (old == null or now == null) return old == null and now == null;
        return std.mem.eql(u8, old.?, now.?);
    }

    /// Back up every changed existing file, never clobber a previous backup.
    pub fn backup(s: Store, path: []const u8, old: ?[]const u8) !?[]const u8 {
        const bytes = old orelse return null;
        const p = try s.parent(path, false);
        defer p.dir.close(s.io);
        var random: [8]u8 = undefined;
        std.Io.random(s.io, &random);
        const hex = std.fmt.bytesToHex(random, .lower);
        const name = try std.fmt.allocPrint(s.gpa, "{s}.nanomon-backup-{s}", .{ p.name, hex });
        defer s.gpa.free(name);
        const file = try p.dir.createFile(s.io, name, .{ .exclusive = true, .permissions = private_file });
        defer file.close(s.io);
        try file.writeStreamingAll(s.io, bytes);
        try file.sync(s.io);
        return try std.fs.path.join(s.gpa, &.{ std.fs.path.dirname(path) orelse "", name });
    }

    pub fn prepareParent(s: Store, path: []const u8) !void {
        const p = try s.parent(path, true);
        p.dir.close(s.io);
    }

    pub fn replace(s: Store, path: []const u8, old: ?[]const u8, bytes: []const u8) !?[]const u8 {
        if (bytes.len > max_bytes) return error.ConfigTooLarge;
        if (!try s.matches(path, old)) return error.ConcurrentModification;
        const backup_path = try s.backup(path, old);
        const p = try s.parent(path, true);
        defer p.dir.close(s.io);
        var atomic = try p.dir.createFileAtomic(s.io, p.name, .{ .permissions = private_file, .replace = old != null });
        defer atomic.deinit(s.io);
        try atomic.file.writeStreamingAll(s.io, bytes);
        try atomic.file.sync(s.io);
        if (!try s.matches(path, old)) return error.ConcurrentModification;
        if (old != null) try atomic.replace(s.io) else try atomic.link(s.io);
        return backup_path;
    }
};

//! Bounded reads of Linux's virtual files. /proc can allow open() but
//! reject read() after a ptrace permission check, or lose a process in
//! between. Zig 0.17's file reader treats those errnos as unexpected and
//! prints a stack trace even if the caller catches the error.
const std = @import("std");
const linux = std.os.linux;

pub fn readFile(io: std.Io, dir: std.Io.Dir, path: []const u8, buf: []u8) ![]u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    return readOpened(file, buf);
}

fn readOpened(file: std.Io.File, buf: []u8) ![]u8 {
    var n: usize = 0;
    while (n < buf.len) {
        const rc = linux.read(file.handle, buf[n..].ptr, buf.len - n);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                n += rc;
            },
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .SRCH, .NOENT => return error.FileNotFound,
            .IO, .NXIO => return error.InputOutput,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
    return buf[0..n];
}

test "virtual file reader: contents, short buffer, empty file and vanished path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "stat", .data = "cpu 1 2 3\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("cpu 1 2 3\n", try readFile(io, tmp.dir, "stat", &buf));
    try std.testing.expectEqualStrings("cpu", try readFile(io, tmp.dir, "stat", buf[0..3]));
    try std.testing.expectEqualStrings("", try readFile(io, tmp.dir, "empty", &buf));
    try std.testing.expectError(error.FileNotFound, readFile(io, tmp.dir, "gone", &buf));
}

const child = struct {
    extern "c" fn fork() c_int;
    extern "c" fn pipe(*[2]c_int) c_int;
    extern "c" fn close(c_int) c_int;
    extern "c" fn read(c_int, [*]u8, usize) isize;
    extern "c" fn write(c_int, [*]const u8, usize) isize;
    extern "c" fn prctl(c_int, c_ulong, c_ulong, c_ulong, c_ulong) c_int;
    extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
    extern "c" fn _exit(c_int) noreturn;
};

test "proc io denied at read time returns AccessDenied quietly" {
    // Open a child's io while it is dumpable; then revoke ptrace access.
    // No real processes or user state are changed, only this test's child.
    var commands: [2]c_int = undefined;
    try std.testing.expectEqual(0, child.pipe(&commands));
    defer _ = child.close(commands[0]);
    defer _ = child.close(commands[1]);
    var replies: [2]c_int = undefined;
    try std.testing.expectEqual(0, child.pipe(&replies));
    defer _ = child.close(replies[0]);
    defer _ = child.close(replies[1]);
    const pid = child.fork();
    if (pid == -1) return error.ForkFailed;
    if (pid == 0) {
        _ = child.close(commands[1]);
        _ = child.close(replies[0]);
        var byte: [1]u8 = .{0};
        if (child.prctl(4, 1, 0, 0, 0) != 0) child._exit(1); // PR_SET_DUMPABLE
        if (child.write(replies[1], &byte, 1) != 1) child._exit(2);
        if (child.read(commands[0], &byte, 1) != 1) child._exit(3);
        if (child.prctl(4, 0, 0, 0, 0) != 0) child._exit(4);
        if (child.write(replies[1], &byte, 1) != 1) child._exit(5);
        _ = child.read(commands[0], &byte, 1); // Stay alive until the parent is done.
        child._exit(0);
    }
    _ = child.close(commands[0]);
    commands[0] = -1;
    _ = child.close(replies[1]);
    replies[1] = -1;
    defer {
        _ = child.close(commands[1]);
        commands[1] = -1;
        var status: c_int = 0;
        _ = child.waitpid(pid, &status, 0);
    }
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(1, child.read(replies[0], &byte, 1));
    var path: [64]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, try std.fmt.bufPrint(&path, "/proc/{d}/io", .{pid}), .{});
    defer file.close(std.testing.io);
    try std.testing.expectEqual(1, child.write(commands[1], "x", 1));
    try std.testing.expectEqual(1, child.read(replies[0], &byte, 1));
    var buf: [4096]u8 = undefined;
    if (readOpened(file, &buf)) |_| {
        // CAP_SYS_PTRACE (some root containers) bypasses the restriction.
        return error.SkipZigTest;
    } else |err| try std.testing.expectEqual(error.AccessDenied, err);
}

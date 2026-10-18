//! What `/bin/ps` knows of processes nanomon may not read itself (the
//! system's: ps is setuid, as top), asked every few samples without
//! waiting for it: its output is read as it comes (`nanoui.fdwatch`) and
//! the last complete answer is kept.
const std = @import("std");
const nanoui = @import("nanoui");

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn posix_spawn(pid: *c_int, path: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_init(a: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_destroy(a: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(a: *?*anyopaque, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(a: *?*anyopaque, fd: c_int) c_int;

/// Samples between two asks.
const every = 3;

pub const Known = struct { rss: u64, time_ns: u64 };

pub const Notify = @import("sample.zig").Notify;

pub const Ps = struct {
    known: std.AutoHashMapUnmanaged(i32, Known) = .empty,
    /// The ask in flight.
    pid: c_int = 0,
    fd: c_int = -1,
    watch: ?nanoui.fdwatch.Watch = null,
    out: std.ArrayList(u8) = .empty,
    gpa: ?std.mem.Allocator = null,
    /// Told when an answer has come.
    notify: ?Notify = null,

    pub fn deinit(p: *Ps, gpa: std.mem.Allocator) void {
        p.stop();
        p.known.deinit(gpa);
        p.out.deinit(gpa);
    }

    pub fn get(p: *const Ps, pid: i32) ?Known {
        return p.known.get(pid);
    }

    /// Asks ps again on every `every`th sample, if no ask is in flight.
    pub fn refresh(p: *Ps, gpa: std.mem.Allocator, n: usize) void {
        if (p.fd >= 0 or n % every != 0) return;
        p.gpa = gpa;
        var fds: [2]c_int = undefined;
        if (pipe(&fds) != 0) return;
        var fa: ?*anyopaque = null;
        _ = posix_spawn_file_actions_init(&fa);
        defer _ = posix_spawn_file_actions_destroy(&fa);
        _ = posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
        _ = posix_spawn_file_actions_addclose(&fa, fds[0]);
        const argv = [_:null]?[*:0]const u8{ "/bin/ps", "-axo", "pid=,rss=,time=" };
        const envp = [_:null]?[*:0]const u8{"LC_ALL=C"};
        var pid: c_int = 0;
        const rc = posix_spawn(&pid, "/bin/ps", @ptrCast(&fa), null, &argv, &envp);
        _ = close(fds[1]);
        if (rc != 0) {
            _ = close(fds[0]);
            return;
        }
        p.pid = pid;
        p.fd = fds[0];
        _ = fcntl(p.fd, 4, @as(c_int, 0x4)); // O_NONBLOCK
        p.out.clearRetainingCapacity();
        p.watch = nanoui.fdwatch.readable(p.fd, p, onReadable) catch {
            p.stop();
            return;
        };
    }

    fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Ps = @ptrCast(@alignCast(ctx));
        const gpa = p.gpa orelse return;
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = read(p.fd, &buf, buf.len);
            if (n > 0) {
                p.out.appendSlice(gpa, buf[0..@intCast(n)]) catch {};
                continue;
            }
            if (n == 0) {
                // The end: what it said replaces what it said before.
                p.known.clearRetainingCapacity();
                parse(gpa, &p.known, p.out.items);
                p.stop();
                if (p.notify) |tell| tell.func(tell.ctx);
            }
            return;
        }
    }

    fn stop(p: *Ps) void {
        if (p.watch) |w| w.cancel();
        p.watch = null;
        if (p.fd >= 0) _ = close(p.fd);
        p.fd = -1;
        if (p.pid > 0) {
            var status: c_int = 0;
            _ = waitpid(p.pid, &status, 0);
        }
        p.pid = 0;
    }
};

/// `ps -o pid=,rss=,time=` lines: pid, resident KB, `[[dd-]hh:]mm:ss.cc`.
pub fn parse(gpa: std.mem.Allocator, out: *std.AutoHashMapUnmanaged(i32, Known), text: []const u8) void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const pid = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue;
        const rss = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
        const t = f.next() orelse continue;
        out.put(gpa, pid, .{ .rss = rss * 1024, .time_ns = time(t) }) catch return;
    }
}

fn time(t: []const u8) u64 {
    var days: u64 = 0;
    var rest = t;
    if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
        days = std.fmt.parseInt(u64, rest[0..dash], 10) catch 0;
        rest = rest[dash + 1 ..];
    }
    var secs: f64 = 0;
    var it = std.mem.splitScalar(u8, rest, ':');
    while (it.next()) |part| secs = secs * 60 + (std.fmt.parseFloat(f64, part) catch 0);
    return @intFromFloat((secs + @as(f64, @floatFromInt(days)) * 86400) * 1e9);
}

test "what ps says" {
    var m: std.AutoHashMapUnmanaged(i32, Known) = .empty;
    defer m.deinit(std.testing.allocator);
    parse(std.testing.allocator, &m, "    1  36032 648:41.66\n  123   1024 1-02:00:00.50\nbad line\n");
    try std.testing.expectEqual(@as(u64, 36032 * 1024), m.get(1).?.rss);
    try std.testing.expectEqual(@as(u64, 38921_660_000_000), m.get(1).?.time_ns);
    try std.testing.expectEqual(@as(u64, (86400 + 7200) * 1_000_000_000 + 500_000_000), m.get(123).?.time_ns);
}

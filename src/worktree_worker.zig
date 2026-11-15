//! One explicit GUI errand at a time. Pipe wake on the UI event loop, never
//! polling; cancel the watch and join before freeing owner/Io. MCP never
//! imports this module. No worker exists until Review/Refresh/Clear is clicked.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const wt = @import("worktrees.zig");
const discovery = @import("worktree_discovery.zig");
const checks = @import("worktree_git.zig");
const App = @import("app.zig").App;
const A = std.mem.Allocator;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
pub const supported = builtin.os.tag == .macos or (builtin.os.tag == .linux and !builtin.abi.isAndroid());

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: wt.Snapshot = .{},
    activity_incomplete: bool = false,
    failure: []const u8 = "",
    removed: usize = 0,
    skipped: usize = 0,
};
const Request = struct {
    arena: std.heap.ArenaAllocator,
    pids: []i32,
    executable_dirs: []const []const u8,
    repo: ?[]const u8,
    selected: ?wt.Entry,
    now: i64,
};
pub const Manager = struct {
    open: bool = false,
    confirm: ?usize = null,
    selected_repo: ?[]const u8 = null,
    days: usize = 14,
    busy: bool = false,
    message: []const u8 = "Review repositories used by your processes, or choose one. Nothing is scanned until you ask.",
    latest: ?Result = null,
    notify: ?@import("sample.zig").Notify = null,
    thread: ?std.Thread = null,
    request: ?Request = null,
    slot: ?Result = null,
    ready: std.atomic.Value(bool) = .init(false),
    stopping: checks.Cancel = .init(false),
    watch: ?nanoui.fdwatch.Watch = null,
    fds: [2]c_int = .{ -1, -1 },
    gpa: ?A = null,
    io: ?std.Io = null,

    /// Main-thread only; a must be stable as for the sampler's callbacks.
    pub fn start(m: *Manager, a: *App, selected: ?usize) void {
        if (comptime !supported) {
            m.message = "Worktree review is supported on macOS and Linux.";
            return;
        }
        if (m.busy) return;
        const gpa = a.sampler.gpa;
        const io = a.sampler.io;
        if (m.fds[0] < 0) {
            if (pipe(&m.fds) != 0) {
                m.message = "Cannot create worker wake pipe.";
                return;
            }
            const nonblock: c_int = if (builtin.os.tag == .macos) 0x4 else 0o4000;
            if (fcntl(m.fds[0], 4, nonblock) < 0 or fcntl(m.fds[1], 4, nonblock) < 0 or
                fcntl(m.fds[0], 2, @as(c_int, 1)) < 0 or fcntl(m.fds[1], 2, @as(c_int, 1)) < 0)
            {
                _ = close(m.fds[0]);
                _ = close(m.fds[1]);
                m.fds = .{ -1, -1 };
                m.message = "Cannot configure the nonblocking worker pipe.";
                return;
            }
            m.watch = nanoui.fdwatch.readable(m.fds[0], m, completed) catch {
                _ = close(m.fds[0]);
                _ = close(m.fds[1]);
                m.fds = .{ -1, -1 };
                m.message = "Cannot register worker wake.";
                return;
            };
        }
        var arena = std.heap.ArenaAllocator.init(gpa);
        const alloc = arena.allocator();
        var pids: std.ArrayList(i32) = .empty;
        for (a.sampler.procs.items) |p| {
            if (p.uid == a.uid) pids.append(alloc, p.pid) catch {
                arena.deinit();
                return;
            };
            if (pids.items.len == 513) break;
        }
        const repo = if (m.selected_repo) |p| alloc.dupe(u8, p) catch {
            arena.deinit();
            return;
        } else null;
        // The previous snapshot lives until completion; entries are borrowed
        // by the request and never freed while the worker can reach them.
        const chosen = if (selected) |i| block: {
            const latest = m.latest orelse {
                arena.deinit();
                return;
            };
            if (i >= latest.snapshot.entries.len) {
                arena.deinit();
                return;
            }
            break :block latest.snapshot.entries[i];
        } else null;
        const executable_dirs = discovery.executablePaths(alloc, &a.sampler, pids.items) catch {
            arena.deinit();
            return;
        };
        m.request = .{ .arena = arena, .pids = pids.items, .executable_dirs = executable_dirs, .repo = repo, .selected = chosen, .now = std.Io.Clock.real.now(io).toMilliseconds() };
        m.gpa = gpa;
        m.io = io;
        m.busy = true;
        m.confirm = null;
        m.stopping.store(false, .release);
        m.message = if (chosen != null) "Rechecking before clearing…" else "Reviewing repositories…";
        m.thread = std.Thread.spawn(.{}, work, .{m}) catch {
            m.request.?.arena.deinit();
            m.request = null;
            m.busy = false;
            m.message = "Cannot start the worktree worker.";
            return;
        };
    }

    fn work(m: *Manager) void {
        var result: Result = .{ .arena = .init(m.gpa.?) };
        const alloc = result.arena.allocator();
        m.perform(alloc, &result) catch |err| {
            result.failure = @errorName(err);
        };
        m.slot = result;
        m.ready.store(true, .release);
        const byte = [_]u8{1};
        // One byte per errand: the nonblocking pipe never fills. Retry EINTR.
        while (write(m.fds[1], &byte, 1) < 0) {
            if (std.c.errno(@as(c_int, -1)) != .INTR) break;
        }
    }
    fn perform(m: *Manager, alloc: A, result: *Result) !void {
        const req = m.request.?;
        const io = m.io.?;
        const paths = try discovery.paths(alloc, io, req.pids);
        var active: std.ArrayList([]const u8) = .empty;
        try active.appendSlice(alloc, paths.roots);
        try active.appendSlice(alloc, req.executable_dirs);
        result.activity_incomplete = paths.incomplete;
        if (m.stopping.load(.acquire)) return error.Canceled;
        if (req.selected) |e| {
            checks.remove(alloc, io, e, active.items, req.now, m.days) catch |err| {
                result.skipped = 1;
                result.failure = @errorName(err);
            };
            if (result.skipped == 0) result.removed = 1;
        }
        const roots = if (req.repo) |repo| &[_][]const u8{repo} else active.items;
        result.snapshot = try wt.scan(alloc, io, roots, req.now, m.days);
        for (result.snapshot.entries) |*e| {
            if (m.stopping.load(.acquire)) return error.Canceled;
            checks.probe(alloc, io, e, active.items);
            // Sizing is lazy: only stale, existing secondary checkouts.
            if (!e.is_primary and e.stale() and e.missing == false)
                e.size_bytes = checks.size(io, e.path, &m.stopping);
        }
    }
    fn completed(ctx: ?*anyopaque) callconv(.c) void {
        const m: *Manager = @ptrCast(@alignCast(ctx orelse return));
        var buf: [16]u8 = undefined;
        _ = read(m.fds[0], &buf, buf.len);
        m.take();
    }
    pub fn take(m: *Manager) void {
        if (!m.ready.swap(false, .acquire)) return;
        if (m.thread) |t| t.join();
        m.thread = null;
        if (m.latest) |*r| r.arena.deinit();
        m.latest = m.slot;
        m.slot = null;
        m.request.?.arena.deinit();
        m.request = null;
        m.busy = false;
        m.message = if (m.latest.?.failure.len > 0) m.latest.?.failure else if (m.latest.?.removed > 0) "Worktree cleared. Branch and committed history retained." else "Review complete. Select a clean candidate to preview clearing.";
        if (m.notify) |n| n.func(n.ctx);
    }
    pub fn deinit(m: *Manager) void {
        m.notify = null;
        if (comptime supported) if (m.watch) |watch| watch.cancel();
        m.watch = null;
        m.stopping.store(true, .release);
        if (m.thread) |t| t.join();
        if (m.slot) |*r| r.arena.deinit();
        if (m.latest) |*r| r.arena.deinit();
        if (m.request) |*r| r.arena.deinit();
        if (comptime supported) for (m.fds) |fd| if (fd >= 0) {
            _ = close(fd);
        };
        if (m.selected_repo) |repo| if (m.gpa) |gpa| gpa.free(repo);
        m.* = .{};
    }
};

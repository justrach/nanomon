//! One first-launch consent, then additive client setup off the UI thread.
//! MCP/headless/dev invocations never configure this controller.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const clients = @import("mcp_clients.zig");
const cli = @import("mcp_setup_cli.zig");
const reg = @import("mcp_register.zig");
const choice = @import("mcp_setup_choice.zig");

pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;
extern "c" fn pipe(*[2]c_int) c_int;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn close(c_int) c_int;

pub const Setup = struct {
    pub const State = enum { off, closed, offer, running, done };
    state: State = .off,
    opened: ?cli.Opened = null,
    gpa: ?std.mem.Allocator = null,
    notify: ?@import("sample.zig").Notify = null,
    detected: [clients.all.len]bool = @splat(false),
    report: reg.Report = undefined,
    failed: bool = false,
    choice_failed: bool = false,
    thread: ?std.Thread = null,
    watch: ?nanoui.fdwatch.Watch = null,
    fds: [2]c_int = .{ -1, -1 },

    pub fn configure(s: *Setup, init: std.process.Init, args: []const [:0]const u8) void {
        if (comptime !supported) return;
        for (args) |arg| if (std.mem.startsWith(u8, arg, "--nanoui-")) return;
        const opened = cli.Opened.open(init) catch return;
        if (!clients.validExecutable(opened.context.exe)) {
            opened.close();
            return;
        }
        s.attach(init.gpa, opened);
    }

    /// Also used by tests, always with a private temporary home.
    pub fn attach(s: *Setup, gpa: std.mem.Allocator, opened: cli.Opened) void {
        s.gpa = gpa;
        s.opened = opened;
        s.scan();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        s.state = if (!choice.decided(arena.allocator(), opened.context) and s.count() > 0) .offer else .closed;
    }

    pub fn scan(s: *Setup) void {
        const ctx = (s.opened orelse return).context;
        for (clients.all, &s.detected) |c, *found| found.* = clients.present(c, ctx.home, ctx.io) or (c == .codex and ctx.codex_program != null);
    }

    pub fn count(s: *const Setup) usize {
        var n: usize = 0;
        for (s.detected) |found| if (found) {
            n += 1;
        };
        return n;
    }

    pub fn show(s: *Setup) void {
        if (s.opened == null or s.state == .running) return;
        s.scan();
        s.state = .offer;
    }

    pub fn dismiss(s: *Setup) void {
        if (s.state == .running) return;
        s.saveChoice("dismissed");
        s.state = .closed;
    }

    fn saveChoice(s: *Setup, decision: []const u8) void {
        const ctx = (s.opened orelse return).context;
        var arena: std.heap.ArenaAllocator = .init(s.gpa.?);
        defer arena.deinit();
        choice.save(arena.allocator(), ctx, if (std.mem.eql(u8, decision, "connected")) .connected else .dismissed) catch {
            s.choice_failed = true;
        };
    }

    pub fn connect(s: *Setup) void {
        if (comptime !supported) return;
        if (s.opened == null or s.state == .running or s.count() == 0) return;
        s.failed = false;
        if (pipe(&s.fds) != 0) {
            s.failed = true;
            s.state = .done;
            return;
        }
        s.watch = nanoui.fdwatch.readable(s.fds[0], s, complete) catch {
            s.failed = true;
            s.stop();
            s.state = .done;
            return;
        };
        s.state = .running;
        s.thread = std.Thread.spawn(.{}, work, .{s}) catch {
            s.failed = true;
            s.stop();
            s.state = .done;
            return;
        };
    }

    fn work(s: *Setup) void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa.?);
        defer arena.deinit();
        s.report = reg.run(arena.allocator(), s.opened.?.context, .install, false, null) catch {
            s.failed = true;
            _ = write(s.fds[1], "x", 1);
            return;
        };
        // Paths belong to this job's arena. The UI needs only states and
        // static reasons; the full backup paths are printed by the CLI.
        for (&s.report) |*r| r.backup = null;
        _ = write(s.fds[1], "x", 1);
    }

    fn complete(ptr: ?*anyopaque) callconv(.c) void {
        const s: *Setup = @ptrCast(@alignCast(ptr));
        s.stop(); // join establishes visibility of the worker's report.
        s.state = .done;
        if (!s.failed) s.saveChoice("connected");
        if (s.notify) |n| n.func(n.ctx);
    }

    fn stop(s: *Setup) void {
        if (s.watch) |w| w.cancel();
        s.watch = null;
        if (s.thread) |t| t.join();
        s.thread = null;
        if (comptime supported) for (&s.fds) |*fd| {
            if (fd.* >= 0) _ = close(fd.*);
            fd.* = -1;
        };
    }

    pub fn deinit(s: *Setup) void {
        s.stop();
        if (s.opened) |o| o.close();
        s.opened = null;
    }
};

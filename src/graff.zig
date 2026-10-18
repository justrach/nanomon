//! The graff bubble's errand: ask graff (Codegraff's agent) a question
//! about the machine, one-shot (`graff -p`), with its local tools turned
//! off (`--no-local-tools`: no shell, no files) and from an empty
//! temporary directory, so it can answer but not act; read its answer as
//! it comes (`nanoui.fdwatch`); and take from its last line, `KILL: …`, the
//! processes it suggests quitting, which nanomon only marks for the user
//! to look over. Nothing here sends a signal.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");

pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" var environ: [*:null]?[*:0]u8;
extern "c" fn posix_spawn(pid: *c_int, path: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_init(a: *FileActions) c_int;
extern "c" fn posix_spawn_file_actions_destroy(a: *FileActions) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(a: *FileActions, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(a: *FileActions, fd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addopen(a: *FileActions, fd: c_int, path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn posix_spawn_file_actions_addchdir_np(a: *FileActions, path: [*:0]const u8) c_int;

/// posix_spawn_file_actions_t: a pointer on macOS, a larger struct in glibc.
const FileActions = if (builtin.os.tag == .macos) ?*anyopaque else extern struct { pad: [10]u64 = undefined };

const O_NONBLOCK: c_int = if (builtin.os.tag == .macos) 0x4 else 0o4000;
const F_SETFL = 4;

pub const State = enum { idle, running, done, failed };

pub const Notify = struct { ctx: *anyopaque, func: *const fn (*anyopaque) void };

pub const Graff = struct {
    state: State = .idle,
    /// The bubble is open.
    open: bool = false,
    question: nanoui.ui.TextBuffer = .{},
    /// The question being answered, as shown.
    asked: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    /// The answer without its `KILL:` line, and the pids on it.
    answer: []const u8 = "",
    suggested: std.ArrayList(i32) = .empty,
    failure: []const u8 = "",
    pid: c_int = 0,
    fd: c_int = -1,
    watch: ?nanoui.fdwatch.Watch = null,
    dir: [64]u8 = undefined,
    dir_len: usize = 0,
    gpa: ?std.mem.Allocator = null,
    io: ?std.Io = null,
    /// Told when the answer is complete.
    notify: ?Notify = null,
    /// The program run: graff found on PATH unless set (tests: a fake).
    program: ?[]const u8 = null,
    started: f64 = 0,

    pub fn deinit(g: *Graff, gpa: std.mem.Allocator) void {
        g.cancel();
        g.asked.deinit(gpa);
        g.out.deinit(gpa);
        g.suggested.deinit(gpa);
    }

    /// Asks `prompt` (the question with the machine around it), showing
    /// `question`; an earlier errand is dropped.
    pub fn ask(g: *Graff, gpa: std.mem.Allocator, io: std.Io, prompt: []const u8, question: []const u8, now: f64) void {
        g.cancel();
        g.gpa = gpa;
        g.io = io;
        g.started = now;
        g.asked.clearRetainingCapacity();
        g.asked.appendSlice(gpa, question) catch {};
        g.out.clearRetainingCapacity();
        g.suggested.clearRetainingCapacity();
        g.answer = "";
        g.failure = "";
        if (comptime !supported) return g.fail("graff can't be asked from here yet.");
        var found: [1024]u8 = undefined;
        const program = g.program orelse find(&found) orelse return g.fail("graff isn't installed (looked on PATH and in ~/.local/bin).");
        // An empty directory of its own: no project around it to read.
        const template = "/tmp/nanomon-graff-XXXXXX";
        @memcpy(g.dir[0..template.len], template);
        g.dir[template.len] = 0;
        if (mkdtemp(@ptrCast(&g.dir)) == null) return g.fail("Couldn't make a directory for graff.");
        g.dir_len = template.len;
        const prog_z = gpa.dupeSentinel(u8, program, 0) catch return g.fail("Out of memory.");
        defer gpa.free(prog_z);
        const prompt_z = gpa.dupeSentinel(u8, prompt, 0) catch return g.fail("Out of memory.");
        defer gpa.free(prompt_z);
        const argv = [_:null]?[*:0]const u8{ prog_z, "-p", "--no-local-tools", "--output-format", "text", prompt_z };
        var fds: [2]c_int = undefined;
        if (pipe(&fds) != 0) return g.fail("Couldn't start graff.");
        var fa: FileActions = if (builtin.os.tag == .macos) null else .{};
        _ = posix_spawn_file_actions_init(&fa);
        defer _ = posix_spawn_file_actions_destroy(&fa);
        _ = posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", 0, 0);
        _ = posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
        _ = posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", 1, 0);
        _ = posix_spawn_file_actions_addclose(&fa, fds[0]);
        _ = posix_spawn_file_actions_addchdir_np(&fa, @ptrCast(&g.dir));
        var pid: c_int = 0;
        const rc = posix_spawn(&pid, prog_z, @ptrCast(&fa), null, &argv, @ptrCast(environ));
        _ = close(fds[1]);
        if (rc != 0) {
            _ = close(fds[0]);
            return g.fail("Couldn't start graff.");
        }
        g.pid = pid;
        g.fd = fds[0];
        _ = fcntl(g.fd, F_SETFL, O_NONBLOCK);
        g.watch = nanoui.fdwatch.readable(g.fd, g, onReadable) catch {
            g.cancel();
            return g.fail("Couldn't listen to graff.");
        };
        g.state = .running;
    }

    fn fail(g: *Graff, why: []const u8) void {
        g.state = .failed;
        g.failure = why;
    }

    fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
        const g: *Graff = @ptrCast(@alignCast(ctx));
        const gpa = g.gpa orelse return;
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = read(g.fd, &buf, buf.len);
            if (n > 0) {
                g.out.appendSlice(gpa, buf[0..@intCast(n)]) catch {};
                continue;
            }
            if (n == 0) g.finish();
            return;
        }
    }

    /// The answer is all here: what it says, and what it suggests.
    fn finish(g: *Graff) void {
        var status: c_int = 0;
        g.stop();
        if (g.pid > 0) _ = waitpid(g.pid, &status, 0);
        g.pid = 0;
        g.removeDir();
        const parsed = parse(g.out.items);
        g.answer = parsed.text;
        if (g.gpa) |gpa| for (parsed.pids.slice()) |p| g.suggested.append(gpa, p) catch {};
        if (g.answer.len == 0) g.fail("graff didn't answer. Is it signed in? Try `graff login` in a terminal.") else g.state = .done;
        if (g.notify) |n| n.func(n.ctx);
    }

    fn stop(g: *Graff) void {
        if (g.watch) |w| w.cancel();
        g.watch = null;
        if (g.fd >= 0) _ = close(g.fd);
        g.fd = -1;
    }

    fn removeDir(g: *Graff) void {
        if (g.dir_len == 0) return;
        if (g.io) |io| std.Io.Dir.cwd().deleteTree(io, g.dir[0..g.dir_len]) catch {};
        g.dir_len = 0;
    }

    /// Stops an errand under way.
    pub fn cancel(g: *Graff) void {
        if (comptime !supported) return;
        g.stop();
        if (g.pid > 0) {
            _ = kill(g.pid, 15);
            var status: c_int = 0;
            _ = waitpid(g.pid, &status, 0);
        }
        g.pid = 0;
        g.removeDir();
        if (g.state == .running) g.state = .idle;
    }
};

/// graff on PATH, or where its installer puts it (an app opened from the
/// Dock has a short PATH).
fn find(buf: []u8) ?[]const u8 {
    if (comptime !supported) return null;
    var it = std.mem.tokenizeScalar(u8, if (getenv("PATH")) |p| std.mem.span(p) else "", ':');
    while (it.next()) |dir| if (exec(buf, dir, "graff")) |p| return p;
    if (getenv("HOME")) |home| {
        var dir: [512]u8 = undefined;
        if (std.fmt.bufPrint(&dir, "{s}/.local/bin", .{std.mem.span(home)})) |d| {
            if (exec(buf, d, "graff")) |p| return p;
        } else |_| {}
    }
    for ([_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin" }) |d| if (exec(buf, d, "graff")) |p| return p;
    return null;
}

fn exec(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    const path = std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, name }, 0) catch return null;
    return if (access(path, 1) == 0) path else null; // X_OK
}

pub const Pids = struct {
    items: [32]i32 = undefined,
    len: usize = 0,

    pub fn slice(p: *const Pids) []const i32 {
        return p.items[0..p.len];
    }
};

/// The answer, and the pids on its last `KILL:` line ("none" for none).
pub fn parse(out: []const u8) struct { text: []const u8, pids: Pids } {
    var pids: Pids = .{};
    var text = std.mem.trim(u8, out, " \r\n\t");
    const at = blk: {
        var i: usize = text.len;
        while (i > 0) {
            const start = if (std.mem.lastIndexOfScalar(u8, text[0 .. i - 1], '\n')) |nl| nl + 1 else 0;
            const line = std.mem.trim(u8, text[start..i], " \r\t*`");
            if (std.ascii.startsWithIgnoreCase(line, "kill:")) break :blk start;
            if (start == 0) break;
            i = start - 1;
        }
        break :blk null;
    };
    if (at) |start| {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const line = std.mem.trim(u8, text[start..end], " \r\t*`");
        var nums = std.mem.tokenizeAny(u8, line[5..], " ,;\t");
        while (nums.next()) |n| {
            const pid = std.fmt.parseInt(i32, std.mem.trim(u8, n, "()[]."), 10) catch continue;
            if (pids.len < pids.items.len) {
                pids.items[pids.len] = pid;
                pids.len += 1;
            }
        }
        // The line goes from what is shown.
        text = std.mem.trim(u8, text[0..start], " \r\n\t");
    }
    return .{ .text = text, .pids = pids };
}

test "graff's answer and the processes it suggests" {
    const r = parse("Safari is busiest.\nMail is idle.\n\nKILL: 412, 9001\n");
    try std.testing.expectEqualStrings("Safari is busiest.\nMail is idle.", r.text);
    try std.testing.expectEqualSlices(i32, &.{ 412, 9001 }, r.pids.slice());
    const none = parse("All is well.\n**KILL: none**");
    try std.testing.expectEqualStrings("All is well.", none.text);
    try std.testing.expectEqual(@as(usize, 0), none.pids.len);
    const bare = parse("Nothing to suggest.");
    try std.testing.expectEqualStrings("Nothing to suggest.", bare.text);
}

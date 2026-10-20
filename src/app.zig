//! nanomon's state: the sampler, when it last sampled (unless paused), the
//! page shown and the time its graphs span, which processes show (all, the
//! user's, the system's) and in what order, processes grouped as apps, the
//! selection, the inspector and a process to quit once asked.
const std = @import("std");
const model = @import("model.zig");
const sample = @import("sample.zig");
const icons = @import("icons.zig");
const nanoui = @import("nanoui");
const builtin = @import("builtin");

extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn getuid() c_uint;
extern "c" fn getpid() c_int;

fn sendSignal(pid: c_int, sig: c_int) callconv(.c) c_int {
    if (comptime builtin.os.tag == .windows) return -1;
    return kill(pid, sig);
}

/// Seconds between samples, as Activity Monitor's default.
pub const interval = 2.0;

/// Activity Monitor's View menu: which processes the table shows.
pub const Filter = enum {
    all,
    mine,
    system,

    pub fn title(f: Filter) []const u8 {
        return switch (f) {
            .all => "All Processes",
            .mine => "My Processes",
            .system => "System Processes",
        };
    }
};

/// The sidebar's pages.
pub const Page = enum { overview, processes, cpu, memory, gpu, disk, network, apps, about };

/// How far back the graphs reach.
pub const Range = enum {
    m1,
    m5,
    m15,
    h1,

    pub fn seconds(r: Range) f32 {
        return switch (r) {
            .m1 => 60,
            .m5 => 300,
            .m15 => 900,
            .h1 => 3600,
        };
    }

    pub fn samples(r: Range) usize {
        return @intFromFloat(r.seconds() / interval);
    }

    pub fn title(r: Range) []const u8 {
        return switch (r) {
            .m1 => "1m",
            .m5 => "5m",
            .m15 => "15m",
            .h1 => "1h",
        };
    }
};

/// An app: its processes together (Chrome and its helpers).
pub const AppRow = struct {
    name: []const u8,
    bundle: []const u8,
    processes: u32 = 0,
    cpu: f32 = 0,
    memory: u64 = 0,
    threads: u32 = 0,
    /// Its first process, for the inspector.
    pid: i32 = 0,
};

pub const AppSort = enum { name, processes, cpu, memory, threads };

/// What a graph's column under the pointer holds: how long ago, and each
/// series' value.
pub const Hover = struct { ago: f32, values: [4]f32 = @splat(0) };

/// The graphs that read out their column under the pointer.
pub const Graph = enum { cpu, memory, gpu, disk, network };

pub const App = struct {
    sampler: sample.Sampler,
    icons: icons.Icons,
    /// Samples by itself (tests fill it instead).
    live: bool = true,
    last: f64 = -1e9,
    tab: model.Tab = .cpu,
    page: Page = .overview,
    range: Range = .m1,
    /// Sampling stopped: the graphs hold still.
    paused: bool = false,
    apps: std.ArrayList(AppRow) = .empty,
    app_sort: AppSort = .cpu,
    app_ascending: bool = false,
    /// Where the filter's menu opens, under its button.
    menu_at: [2]f32 = .{ 0, 0 },
    /// Each graph's column under the pointer, as last drawn.
    hovers: std.EnumArray(Graph, ?Hover) = .initFill(null),
    /// Processes marked to quit together, and the sheet asking first.
    marked: std.AutoArrayHashMapUnmanaged(i32, void) = .empty,
    confirm_marked: bool = false,
    /// What quitting did, shown for a while.
    notice: [120]u8 = undefined,
    notice_len: usize = 0,
    notice_until: f64 = 0,
    /// The clock as the view last saw it.
    now: f64 = 0,
    /// The graff bubble.
    graff: @import("graff.zig").Graff = .{},
    /// How a signal is sent (tests record instead).
    send: *const fn (pid: c_int, sig: c_int) callconv(.c) c_int = sendSignal,
    filter: Filter = .all,
    sort: model.Sort = .cpu,
    ascending: bool = false,
    query: nanoui.ui.TextBuffer = .{},
    /// The table's order: indices into the sample's processes.
    rows: std.ArrayList(u32) = .empty,
    dirty: bool = true,
    selected: ?i32 = null,
    /// A process to quit, waiting for the user to confirm; one inspected.
    confirm: ?i32 = null,
    inspect: ?i32 = null,
    /// The View menu (the toolbar's ⋯) is open.
    menu: bool = false,
    /// The keyboard moved the selection: scroll it into view.
    reveal: bool = false,
    /// ⌘F: the search takes the keys.
    find_search: bool = false,
    /// The user running nanomon: "My Processes".
    uid: u32 = 0,
    /// Light or dark, fixed (tests); else as the system shows.
    dark: ?bool = null,
    /// Drawn again when figures come between samples.
    window: ?*nanoui.Window = null,
    /// ps has answered since the last frame.
    fresh: bool = false,
    /// Updates from the releases, and the app to quit to install one.
    updater: ?*nanoui.Updater = null,
    nanoapp: ?*nanoui.App = null,
    /// The menu bar's readout and panel (macOS), what it shows, and whether
    /// the panel shows its settings.
    menubar: ?*@import("menubar.zig").MenuBar = null,
    bar_items: @import("menubar.zig").Items = .{},
    settings_open: bool = false,
    /// The clock samples go by when several views share them (the window
    /// and the panel each have their own frame clock); tests leave it null.
    clock: ?*const fn () f64 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) App {
        const uid: u32 = if (comptime builtin.os.tag != .windows) getuid() else 0;
        return .{ .sampler = .{ .gpa = gpa, .io = io }, .icons = .{ .gpa = gpa }, .uid = uid };
    }

    /// Hears of ps's answers; `a` must stay where it is from now on.
    pub fn listen(a: *App, window: ?*nanoui.Window) void {
        a.window = window;
        a.sampler.on_update = .{ .ctx = a, .func = answered };
        a.graff.notify = .{ .ctx = a, .func = graffAnswered };
    }

    /// Opens the window (again, once closed: nanomon stays in the menu bar).
    pub fn openWindow(a: *App) void {
        if (a.menubar) |m| m.hidePopover();
        if (a.window) |w| return w.focus();
        const app = a.nanoapp orelse return;
        const theme = @import("theme.zig");
        a.window = app.newWindow(.{
            .title = "nanomon",
            .width = 1020,
            .height = 660,
            .min_width = 720,
            .min_height = 420,
            // The toolbar is the title bar, as Activity Monitor's.
            .title_bar = .hidden,
            .theme = theme.ui(nanoui.isDark()),
            .content = .{ .view = .init(a, @import("view.zig").view) },
            .on_close = .{ .ctx = a, .func = windowClosed },
        }) catch return;
        a.window.?.focus();
    }

    fn windowClosed(ctx: *anyopaque, _: *nanoui.Window) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.window = null;
    }

    /// The menu bar panel's height for what it shows.
    pub fn popoverHeight(a: *App) f64 {
        return @import("view_popover.zig").height(a);
    }

    /// Draws again: an answer came, or an update is ready.
    pub fn graffAnswered(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        if (a.window) |w| w.redraw();
    }

    fn answered(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.fresh = true;
        if (a.window) |w| w.redraw();
        if (a.menubar) |m| if (m.popover) |p| if (p.isVisible()) p.redraw();
    }

    pub fn deinit(a: *App) void {
        a.rows.deinit(a.sampler.gpa);
        a.apps.deinit(a.sampler.gpa);
        a.marked.deinit(a.sampler.gpa);
        a.graff.deinit(a.sampler.gpa);
        a.icons.deinit();
        a.sampler.deinit();
    }

    /// Samples when it is time; returns the seconds until the next.
    pub fn tick(a: *App, now: f64) f32 {
        if (a.paused) {
            if (a.dirty) a.order();
            return 3600;
        }
        if (a.live and now - a.last >= interval) {
            a.sampler.sample(now);
            a.last = now;
            a.dirty = true;
            // The first percentages soon, not a whole interval later.
            if (a.sampler.samples == 1) a.last = now - interval + 0.6;
        }
        a.now = now;
        if (a.fresh) {
            a.fresh = false;
            a.sampler.refill(now);
            a.dirty = true;
        }
        if (a.dirty) a.order();
        return @floatCast(@max(0.05, interval - (now - a.last)));
    }

    /// The table: shown by the filter, matching the search, in order.
    pub fn order(a: *App) void {
        a.dirty = false;
        const procs = a.sampler.procs.items;
        model.sort(procs, a.sort, a.ascending);
        a.rows.clearRetainingCapacity();
        const q = std.mem.trim(u8, a.query.text(), " ");
        for (procs, 0..) |p, i| {
            switch (a.filter) {
                .all => {},
                .mine => if (p.uid != a.uid) continue,
                .system => if (p.uid != 0) continue,
            }
            if (q.len > 0 and !matches(p, q)) continue;
            a.rows.append(a.sampler.gpa, @intCast(i)) catch return;
        }
        a.group();
    }

    /// Processes from the same app bundle, together, in the apps' order.
    fn group(a: *App) void {
        const gpa = a.sampler.gpa;
        a.apps.clearRetainingCapacity();
        var at: std.StringHashMapUnmanaged(usize) = .empty;
        defer at.deinit(gpa);
        const q = std.mem.trim(u8, a.query.text(), " ");
        for (a.sampler.procs.items) |p| {
            if (p.bundle.len == 0) continue;
            // Helpers inside an app count as the outermost app.
            const outer = outerBundle(p.bundle);
            const gop = at.getOrPut(gpa, outer) catch return;
            if (!gop.found_existing) {
                gop.value_ptr.* = a.apps.items.len;
                const name = std.fs.path.stem(outer);
                a.apps.append(gpa, .{ .name = name, .bundle = outer, .pid = p.pid }) catch return;
            }
            const r = &a.apps.items[gop.value_ptr.*];
            r.processes += 1;
            r.cpu += p.cpu;
            r.memory += p.memory;
            r.threads += p.threads;
        }
        if (q.len > 0) {
            var keep: usize = 0;
            for (a.apps.items) |r| if (contains(r.name, q)) {
                a.apps.items[keep] = r;
                keep += 1;
            };
            a.apps.shrinkRetainingCapacity(keep);
        }
        const Ctx = struct { by: AppSort, asc: bool };
        std.mem.sort(AppRow, a.apps.items, Ctx{ .by = a.app_sort, .asc = a.app_ascending }, struct {
            fn lt(ctx: Ctx, x: AppRow, y: AppRow) bool {
                const o: std.math.Order = switch (ctx.by) {
                    .name => std.ascii.orderIgnoreCase(x.name, y.name),
                    .processes => std.math.order(x.processes, y.processes),
                    .cpu => std.math.order(x.cpu, y.cpu),
                    .memory => std.math.order(x.memory, y.memory),
                    .threads => std.math.order(x.threads, y.threads),
                };
                if (o == .eq) return std.ascii.lessThanIgnoreCase(x.name, y.name);
                return (o == .lt) == ctx.asc;
            }
        }.lt);
    }

    pub fn sortApps(a: *App, by: AppSort) void {
        if (a.app_sort == by) a.app_ascending = !a.app_ascending else {
            a.app_sort = by;
            a.app_ascending = by == .name;
        }
        a.dirty = true;
    }

    /// The outermost app bundle in `path`: Chrome for its helpers.
    pub fn outerBundle(path: []const u8) []const u8 {
        const end = std.mem.indexOf(u8, path, ".app") orelse return path;
        return path[0 .. end + 4];
    }

    fn matches(p: model.Process, q: []const u8) bool {
        if (contains(p.name, q) or contains(p.user, q)) return true;
        var buf: [16]u8 = undefined;
        const pid = std.fmt.bufPrint(&buf, "{d}", .{p.pid}) catch return false;
        return std.mem.startsWith(u8, pid, q);
    }

    fn contains(s: []const u8, q: []const u8) bool {
        if (q.len > s.len) return false;
        for (0..s.len - q.len + 1) |i| if (std.ascii.eqlIgnoreCase(s[i..][0..q.len], q)) return true;
        return false;
    }

    /// Sorts by `key`; again on the same key turns the order around.
    pub fn sortBy(a: *App, key: model.Sort) void {
        if (a.sort == key) a.ascending = !a.ascending else {
            a.sort = key;
            a.ascending = key == .name or key == .user or key == .pid;
        }
        a.dirty = true;
    }

    /// Shows another tab, sorted by what it is about.
    pub fn show(a: *App, tab: model.Tab) void {
        if (a.tab == tab) return;
        a.tab = tab;
        a.sort = switch (tab) {
            .cpu => .cpu,
            .memory => .memory,
            .disk => .written,
        };
        a.ascending = false;
        a.dirty = true;
    }

    pub fn setFilter(a: *App, f: Filter) void {
        a.filter = f;
        a.menu = false;
        a.dirty = true;
    }

    pub fn find(a: *App, pid: i32) ?model.Process {
        for (a.sampler.procs.items) |p| if (p.pid == pid) return p;
        return null;
    }

    /// The selection moved up or down the table by `by` rows.
    pub fn step(a: *App, by: i32) void {
        const procs = a.sampler.procs.items;
        if (a.rows.items.len == 0) return;
        const last: i32 = @intCast(a.rows.items.len - 1);
        const at: i32 = if (a.selectedRow()) |i| @intCast(i) else -1;
        const next: i32 = if (at < 0) 0 else std.math.clamp(at + by, 0, last);
        a.selected = procs[a.rows.items[@intCast(next)]].pid;
    }

    /// The selected row's place in the table, if it is shown.
    pub fn selectedRow(a: *App) ?usize {
        const pid = a.selected orelse return null;
        const procs = a.sampler.procs.items;
        for (a.rows.items, 0..) |r, i| if (procs[r].pid == pid) return i;
        return null;
    }

    /// Marks `pid` to quit with others, or unmarks it.
    pub fn mark(a: *App, pid: i32) void {
        if (a.marked.swapRemove(pid)) return;
        a.marked.put(a.sampler.gpa, pid, {}) catch {};
    }

    /// Marks every row from the selected one to `pid`'s, as a shift-click.
    pub fn markTo(a: *App, pid: i32) void {
        const procs = a.sampler.procs.items;
        const from = a.selectedRow() orelse return a.mark(pid);
        var to: usize = from;
        for (a.rows.items, 0..) |r, i| if (procs[r].pid == pid) {
            to = i;
        };
        for (a.rows.items[@min(from, to) .. @max(from, to) + 1]) |r| a.marked.put(a.sampler.gpa, procs[r].pid, {}) catch {};
    }

    /// Marks every row shown, or (if they all are) none.
    pub fn markAll(a: *App) void {
        const procs = a.sampler.procs.items;
        var all = a.rows.items.len > 0;
        for (a.rows.items) |r| if (!a.marked.contains(procs[r].pid)) {
            all = false;
            break;
        };
        if (all) return a.marked.clearRetainingCapacity();
        for (a.rows.items) |r| a.marked.put(a.sampler.gpa, procs[r].pid, {}) catch {};
    }

    /// Marks that still name a process, and what they hold together.
    pub fn markedSummary(a: *App) struct { count: usize, cpu: f32, memory: u64, system: usize } {
        var cpu: f32 = 0;
        var memory: u64 = 0;
        var system: usize = 0;
        var n: usize = 0;
        for (a.marked.keys()) |pid| if (a.find(pid)) |p| {
            n += 1;
            cpu += p.cpu;
            memory += p.memory;
            if (p.uid != a.uid) system += 1;
        };
        return .{ .count = n, .cpu = cpu, .memory = memory, .system = system };
    }

    /// Whether quitting `pid` is out of the question: nanomon itself,
    /// launchd, the kernel.
    pub fn untouchable(pid: i32) bool {
        return pid <= 1 or (comptime builtin.os.tag != .windows) and pid == getpid();
    }

    /// Quits every marked process (asks, or with `force` makes it); says
    /// how many did and how many could not be (not the user's).
    pub fn quitMarked(a: *App, force: bool) void {
        var done: usize = 0;
        var refused: usize = 0;
        var i: usize = 0;
        while (i < a.marked.count()) {
            const pid = a.marked.keys()[i];
            if (a.find(pid) == null or untouchable(pid)) {
                a.marked.swapRemoveAt(i);
                continue;
            }
            const ok = a.send(pid, if (force) 9 else 15) == 0;
            if (ok) {
                done += 1;
                a.marked.swapRemoveAt(i);
            } else {
                refused += 1;
                i += 1;
            }
        }
        a.confirm_marked = false;
        a.last = -1e9;
        const verb = if (force) "Force quit" else "Asked";
        const text: anyerror![]u8 = if (refused == 0)
            std.fmt.bufPrint(&a.notice, "{s} {d} process{s} to quit", .{ verb, done, if (done == 1) "" else "es" })
        else
            std.fmt.bufPrint(&a.notice, "{s} {d} to quit · {d} not yours to quit (left marked)", .{ verb, done, refused });
        a.notice_len = if (text) |t| t.len else |_| 0;
        a.notice_until = a.now + 6;
    }

    pub fn noticeText(a: *App) ?[]const u8 {
        if (a.notice_len == 0 or a.now > a.notice_until) return null;
        return a.notice[0..a.notice_len];
    }

    /// Asks process `pid` to quit (SIGTERM), or makes it (SIGKILL).
    pub fn quit(a: *App, pid: i32, force: bool) void {
        if (!untouchable(pid)) _ = a.send(pid, if (force) 9 else 15);
        a.confirm = null;
        a.last = -1e9;
    }
};

test "the table follows the filter, the search and the sort" {
    var a: App = .init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    a.live = false;
    a.uid = 501;
    try a.sampler.procs.appendSlice(std.testing.allocator, &.{
        .{ .pid = 10, .ppid = 1, .uid = 0, .name = "launchd", .user = "root", .cpu = 1, .known = true },
        .{ .pid = 20, .ppid = 1, .uid = 501, .name = "Safari", .user = "me", .cpu = 30, .known = true, .memory = 5 },
        .{ .pid = 30, .ppid = 1, .uid = 501, .name = "Mail", .user = "me", .cpu = 3, .known = true, .memory = 9 },
    });
    _ = a.tick(0);
    try std.testing.expectEqualStrings("Safari", a.sampler.procs.items[a.rows.items[0]].name);
    a.query.set("ma");
    a.dirty = true;
    _ = a.tick(0);
    try std.testing.expectEqual(@as(usize, 1), a.rows.items.len);
    a.sortBy(.name);
    a.query.set("");
    _ = a.tick(0);
    try std.testing.expectEqualStrings("launchd", a.sampler.procs.items[a.rows.items[0]].name);
    a.setFilter(.mine);
    _ = a.tick(0);
    try std.testing.expectEqual(@as(usize, 2), a.rows.items.len);
    a.setFilter(.system);
    _ = a.tick(0);
    try std.testing.expectEqual(@as(usize, 1), a.rows.items.len);
    a.setFilter(.all);
    a.show(.memory);
    _ = a.tick(0);
    try std.testing.expectEqualStrings("Mail", a.sampler.procs.items[a.rows.items[0]].name);
    a.step(1);
    try std.testing.expectEqual(@as(?i32, 30), a.selected);
    a.step(1);
    try std.testing.expectEqual(@as(?i32, 20), a.selected);
}

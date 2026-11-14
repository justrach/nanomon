//! Nanolight's shared updater: download/verify, then restart out of sight.
//! Only UI preferences survive; never persist process IDs or sample history.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const app_mod = @import("app.zig");
const App = app_mod.App;
const model = @import("model.zig");

pub fn asset() []const u8 {
    return switch (builtin.os.tag) {
        .macos => if (builtin.cpu.arch == .aarch64) "nanomon-macos-arm64.zip" else "",
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "nanomon-linux-aarch64.tar.gz",
            .x86_64 => "nanomon-linux-x86_64.tar.gz",
            else => "",
        },
        else => "",
    };
}

pub fn start(init: std.process.Init, a: *App, app: *nanoui.App) !*nanoui.Updater {
    const u = try nanoui.Updater.start(init, .{
        .repo = "justrach/nanomon",
        .asset = asset(),
        .version = @import("nanomon_options").update_version,
        .name = "nanomon",
        .changed = .{ .ctx = a, .func = App.graffAnswered },
    });
    if (u.phase.load(.acquire) != .off) {
        if (u.restoredState()) |state| if (restore(a, state)) |main_open| {
            // With the main window closed, the old app had only its menu
            // bar popover. Keep the same window order for nanoui's restore.
            if (!main_open) if (a.window) |w| w.close();
        };
        u.autoRestart(app, .{ .idle_ms = 10_000, .save = .{ .ctx = a, .func = save } });
    }
    return u;
}

const State = struct {
    schema: u8 = 1,
    main_open: bool = true,
    page: app_mod.Page = .overview,
    range: app_mod.Range = .m1,
    tab: model.Tab = .cpu,
    filter: app_mod.Filter = .all,
    sort: model.Sort = .cpu,
    ascending: bool = false,
    app_sort: app_mod.AppSort = .cpu,
    app_ascending: bool = false,
    query: []const u8 = "",
    bar_items: @import("menubar.zig").Items = .{},
};

/// Declining a snapshot defers an automatic restart, not a user-requested
/// restart. Don't interrupt a paused graph, pending action or agent request.
pub fn save(ctx: *anyopaque, out: *std.Io.Writer) anyerror!void {
    const a: *App = @ptrCast(@alignCast(ctx));
    if (a.paused or a.confirm != null or a.confirm_marked or a.marked.count() > 0 or
        a.graff.state == .running or a.agents.state == .running or a.query.text().len > 1024) return error.Busy;
    try std.json.Stringify.value(State{
        .main_open = a.window != null,
        .page = a.page,
        .range = a.range,
        .tab = a.tab,
        .filter = a.filter,
        .sort = a.sort,
        .ascending = a.ascending,
        .app_sort = a.app_sort,
        .app_ascending = a.app_ascending,
        .query = a.query.text(),
        .bar_items = a.bar_items,
    }, .{}, out);
}

/// Returns whether the main window existed; malformed state changes nothing.
pub fn restore(a: *App, bytes: []const u8) ?bool {
    if (bytes.len > 8192) return null;
    const parsed = std.json.parseFromSlice(State, a.sampler.gpa, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const s = parsed.value;
    if (s.schema != 1 or !std.unicode.utf8ValidateSlice(s.query)) return null;
    a.page = s.page;
    a.range = s.range;
    a.tab = s.tab;
    a.filter = s.filter;
    a.sort = s.sort;
    a.ascending = s.ascending;
    a.app_sort = s.app_sort;
    a.app_ascending = s.app_ascending;
    a.query.set(s.query);
    a.bar_items = s.bar_items;
    if (a.menubar) |m| m.update();
    a.dirty = true;
    return s.main_open;
}

pub fn printVersion(io: std.Io) !void {
    var buf: [128]u8 = undefined;
    var file = std.Io.File.stdout().writerStreaming(io, &buf);
    try file.interface.print("nanomon {s}\n", .{@import("nanomon_options").version});
    try file.interface.flush();
}

test "automatic updates retain preferences but never process identities/history" {
    var a: App = .init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    a.page = .processes;
    a.range = .h1;
    a.tab = .memory;
    a.filter = .mine;
    a.sort = .memory;
    a.query.set("Mail");
    a.bar_items.cpu = false;
    a.selected = 12345;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try save(&a, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "12345") == null);
    var b: App = .init(std.testing.allocator, std.testing.io);
    defer b.deinit();
    try std.testing.expectEqual(false, restore(&b, out.written()).?);
    try std.testing.expectEqual(a.page, b.page);
    try std.testing.expectEqual(a.range, b.range);
    try std.testing.expectEqual(a.tab, b.tab);
    try std.testing.expectEqual(a.filter, b.filter);
    try std.testing.expectEqual(a.sort, b.sort);
    try std.testing.expectEqualStrings("Mail", b.query.text());
    try std.testing.expect(!b.bar_items.cpu and b.selected == null and b.marked.count() == 0);
    try std.testing.expect(restore(&b, "{bad") == null);
    try std.testing.expect(restore(&b, "{\"schema\":2,\"page\":\"cpu\"}") == null);
    try std.testing.expectEqual(a.page, b.page);
}

test "automatic update waits for paused monitoring and pending user actions" {
    var a: App = .init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    var out: std.Io.Writer.Discarding = .init(&.{});
    a.paused = true;
    try std.testing.expectError(error.Busy, save(&a, &out.writer));
    a.paused = false;
    a.confirm = 42;
    try std.testing.expectError(error.Busy, save(&a, &out.writer));
    a.confirm = null;
    a.graff.state = .running;
    try std.testing.expectError(error.Busy, save(&a, &out.writer));
    a.graff.state = .idle;
    a.agents.state = .running;
    try std.testing.expectError(error.Busy, save(&a, &out.writer));
    a.agents.state = .off;
    try a.marked.put(std.testing.allocator, 42, {});
    try std.testing.expectError(error.Busy, save(&a, &out.writer));
    a.marked.clearRetainingCapacity();
    a.query.set(&@as([1025]u8, @splat('x')));
    try std.testing.expectError(error.Busy, save(&a, &out.writer));
}

test "updater sidebar distinguishes off, checking and ready without real work" {
    const ui = nanoui.ui;
    var a: App = .init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    try @import("tests.zig").fake(&a);
    var updater: nanoui.Updater = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .options = .{ .repo = "unused", .asset = "unused", .name = "unused" },
    };
    a.updater = &updater;
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1020, .height = 760 });
    defer t.deinit();
    t.settle(2);
    try std.testing.expect(!t.hasText("Check for updates"));
    updater.phase.store(.idle, .release);
    t.settle(1);
    try std.testing.expect(t.hasText("Check for updates"));
    updater.working.store(true, .release);
    t.settle(1);
    try t.clickText("Checking for updates…"); // Must not spawn a real checker.
    try std.testing.expect(updater.working.load(.acquire));
    updater.working.store(false, .release);
    @memcpy(updater.version_buf[0..5], "9.9.9");
    updater.version_len = 5;
    updater.phase.store(.ready, .release);
    t.settle(1);
    try std.testing.expect(t.hasText("Restart to update") and t.hasText("9.9.9"));
}

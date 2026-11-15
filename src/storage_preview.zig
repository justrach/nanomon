//! Offscreen previews of the implemented feature, with synthetic readings.
//! Only Review/Cancel/Done are clicked; never Scan, the picker, or Clear.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
pub fn run(a: *App, init: std.process.Init, dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    try @import("storage_fixture.zig").attach(a);
    for ([_]bool{ false, true }) |dark| {
        a.dark = dark;
        a.page = .overview;
        a.worktrees.open = false;
        a.worktrees.confirm = null;
        var t: ui.Tester = undefined;
        try t.init(init.gpa, .init(a, @import("view.zig").view), .{
            .width = 1100,
            .height = 820,
            .scale = 2,
            .dark = dark,
            .theme = @import("theme.zig").ui(dark),
        });
        defer t.deinit();
        const appearance = if (dark) "dark" else "light";
        t.settle(0.5);
        try save(&t, init, dir, appearance, "overview");
        try t.clickText("Disk");
        t.settle(0.5);
        try save(&t, init, dir, appearance, "disk");
        try t.clickText("Review worktrees…");
        t.settle(0.5);
        try save(&t, init, dir, appearance, "worktrees");
        try t.clickText("Review clearing…");
        t.settle(0.5);
        try save(&t, init, dir, appearance, "confirmation");
        try t.clickText("Cancel");
        try t.clickText("Done");
    }
}
fn save(t: *ui.Tester, init: std.process.Init, dir: []const u8, appearance: []const u8, view: []const u8) !void {
    const path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}-{s}.png", .{ dir, appearance, view });
    try t.screenshot(path);
}

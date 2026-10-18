//! nanomon: a small activity monitor on nanoui, laid out as Activity
//! Monitor: processes with their CPU, memory and disk, the system's below,
//! sampled every two seconds while the window shows.
const std = @import("std");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const view = @import("view.zig");
const theme = @import("theme.zig");

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "nanomon" });
    defer app.destroy();
    var a: App = .init(init.gpa, init.io);
    defer a.deinit();
    const window = try app.newWindow(.{
        .title = "nanomon",
        .width = 1020,
        .height = 660,
        .min_width = 720,
        .min_height = 420,
        // The toolbar is the title bar, as Activity Monitor's.
        .title_bar = .hidden,
        .theme = theme.ui(nanoui.isDark()),
        .content = .{ .view = .init(&a, view.view) },
    });
    a.listen(window);
    try app.run();
}

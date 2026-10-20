//! nanomon: a small activity monitor on nanoui, laid out as Activity
//! Monitor: processes with their CPU, memory and disk, the system's below,
//! sampled every two seconds while the window shows; on macOS it lives in
//! the menu bar too, with a panel of the machine under it.
const std = @import("std");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const menubar = @import("menubar.zig");

pub fn main(init: std.process.Init) !void {
    // In the menu bar, closing the window leaves nanomon running there.
    const app = try nanoui.App.create(init, .{ .name = "nanomon", .quit_on_last_window_closed = !menubar.supported });
    defer app.destroy();
    var a: App = .init(init.gpa, init.io);
    defer a.deinit();
    a.nanoapp = app;
    a.listen(null);
    if (menubar.supported) a.clock = menubar.clock;
    a.openWindow();
    var bar: menubar.MenuBar = .{ .a = &a, .app = app };
    defer bar.deinit();
    bar.start();
    a.updater = try nanoui.Updater.start(init, .{
        .repo = "justrach/nanomon",
        .asset = "nanomon-macos-arm64.zip",
        .name = "nanomon",
        .changed = .{ .ctx = &a, .func = App.graffAnswered },
    });
    defer a.updater.?.deinit();
    try app.run();
}

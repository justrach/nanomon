//! nanomon: a small activity monitor on nanoui, laid out as Activity
//! Monitor: processes with their CPU, memory and disk, the system's below,
//! sampled every two seconds while the window shows; on macOS it lives in
//! the menu bar too, with a panel of the machine under it.
const std = @import("std");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const menubar = @import("menubar.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) return @import("updates.zig").printVersion(init.io);
    if (args.len > 1 and std.mem.eql(u8, args[1], "mcp")) {
        if (args.len > 2) return @import("mcp_setup_cli.zig").run(init, args[2..]);
        return @import("mcp_stdio.zig").run(init);
    }
    // In the menu bar, closing the window leaves nanomon running there.
    const app = try nanoui.App.create(init, .{ .name = "nanomon", .quit_on_last_window_closed = !menubar.supported });
    defer app.destroy();
    var a: App = .init(init.gpa, init.io);
    defer a.deinit();
    a.nanoapp = app;
    a.listen(null);
    a.agents.configure(init, args);
    if (menubar.supported) a.clock = menubar.clock;
    a.openWindow();
    // No trays, updater/cache work or activation in dev/headless checks.
    if (app.flags.hidden) return app.run();
    var bar: menubar.MenuBar = .{ .a = &a, .app = app };
    defer bar.deinit();
    bar.start();
    a.updater = @import("updates.zig").start(init, &a, app) catch null;
    defer if (a.updater) |u| u.deinit();
    try app.run();
}

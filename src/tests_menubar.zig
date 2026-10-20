//! The menu bar's readout and panel through the Tester (nothing goes in
//! the real menu bar): the panel shows the CPU, its cores as rings, the
//! busiest processes, the GPU's dials, load and uptime; the gear turns it
//! to what the menu bar shows; the readout comes out as a template image
//! cut to what it draws, narrower without the items turned off.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const menubar = @import("menubar.zig");
const popover = @import("view_popover.zig");
const fake = @import("tests.zig").fake;

test "the panel under the menu bar, and its settings" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try fake(&a);
    a.sampler.system.cpu_temp = 42;
    a.sampler.system.cpu_temp_max = 47;
    a.sampler.system.soc_temp = 52;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, popover.view), .{ .width = menubar.popover_w, .height = @floatCast(popover.height(&a)), .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("CPU") and t.hasText("75") and t.hasText("42 °C") and t.hasText("hottest 47 °C"));
    try std.testing.expect(t.hasText("Efficiency Cores") and t.hasText("Super Cores"));
    // The busiest first: Safari (38.5%), its web content, kernel_task.
    try std.testing.expect(t.hasText("38.5%") and t.hasText("11.5%"));
    const safari = t.findText("Safari").?;
    const kernel = t.findText("kernel_task").?;
    try std.testing.expect(safari.y < kernel.y);
    try std.testing.expect(t.hasText("GPU") and t.hasText("59.0") and t.hasText("SoC") and t.hasText("Render"));
    try std.testing.expect(t.hasText("12.50  9.10  6.00") and t.hasText("27d 20h") and t.hasText("Open nanomon"));
    // Everything fits: Open nanomon is inside the panel.
    const open = t.findText("Open nanomon").?;
    try std.testing.expect(open.y + open.h < popover.height(&a));
    try t.screenshot("/tmp/nanomon-popover.png");

    // The gear: what the menu bar shows.
    const gear = t.findText("Open nanomon").?;
    t.click(menubar.popover_w - 30, gear.y + gear.h / 2);
    t.settle(0.5);
    try std.testing.expect(a.settings_open and t.hasText("In the menu bar") and t.hasText("Quit nanomon"));
    try t.clickText("Network");
    t.settle(0.3);
    try std.testing.expect(!a.bar_items.network);
    try t.screenshot("/tmp/nanomon-popover-settings.png");
}

/// The readout drawn as the menu bar shows it; its width in pixels.
fn readoutWidth(a: *App) !usize {
    const gpa = std.testing.allocator;
    var th = theme.ui(true);
    th.background = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(a, menubar.readout), .{ .width = menubar.readout_w, .height = menubar.readout_h, .scale = 2, .theme = th });
    defer t.deinit();
    t.frame();
    try t.screenshot("/tmp/nanomon-readout.png");
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    const w = menubar.template(px.bytes, px.width, px.height);
    // Only coverage is left: black, its alpha what was drawn.
    var drawn: usize = 0;
    var i: usize = 0;
    while (i < px.bytes.len) : (i += 4) {
        try std.testing.expectEqual(@as(u8, 0), px.bytes[i] | px.bytes[i + 1] | px.bytes[i + 2]);
        if (px.bytes[i + 3] > 128) drawn += 1;
    }
    try std.testing.expect(drawn > 200);
    return w;
}

test "the menu bar readout: a template image, as wide as what it shows" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try fake(&a);
    a.sampler.system.cpu_temp = 42;
    const all = try readoutWidth(&a);
    try std.testing.expect(all > 200 and all < menubar.readout_w * 2);
    a.bar_items.network = false;
    const fewer = try readoutWidth(&a);
    try std.testing.expect(fewer + 80 < all);
}

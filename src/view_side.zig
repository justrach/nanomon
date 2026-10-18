//! The sidebar: the pages, each with its colored chip and, beside its
//! name, its figure now (CPU and memory in use, the GPU's load, the disk's
//! and network's rates, how many processes and apps), and at the bottom
//! whether sampling runs.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

pub const width = 214;

const Item = struct { page: app_mod.Page, icon: []const u8, name: []const u8 };

pub fn sidebar(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = ui.div(c).column().w(width).hFull().bg(k.sidebar).px(10).gap(2);
    defer s.end();
    // The window's buttons sit here on macOS; elsewhere, the app's name.
    {
        const top = ui.div(c).row().wFull().h(kit.header_h).itemsCenter().px(6);
        defer top.end();
        if (builtin.os.tag != .macos) ui.text(c, "nanomon", .{ .size = 13, .weight = .bold, .color = k.text });
    }
    const sy = a.sampler.system;
    var b: [32]u8 = undefined;
    item(c, a, k, .{ .page = .overview, .icon = "square.grid.2x2", .name = "Overview" }, k.gray, "");
    item(c, a, k, .{ .page = .processes, .icon = "list.bullet", .name = "Processes" }, k.gray, c.print("{s}", .{model.count(&b, a.sampler.procs.items.len)}));
    section(c, k, "Hardware");
    item(c, a, k, .{ .page = .cpu, .icon = "cpu", .name = "CPU" }, k.accent, c.print("{d:.0}%", .{sy.cpuBusy()}));
    const mem: f32 = if (sy.mem_total > 0) @floatCast(@as(f64, @floatFromInt(sy.memUsed())) / @as(f64, @floatFromInt(sy.mem_total)) * 100) else 0;
    item(c, a, k, .{ .page = .memory, .icon = "memorychip", .name = "Memory" }, k.green, c.print("{d:.0}%", .{mem}));
    item(c, a, k, .{ .page = .gpu, .icon = "cube", .name = "GPU" }, k.red, c.print("{d:.0}%", .{sy.gpu}));
    item(c, a, k, .{ .page = .disk, .icon = "internaldrive", .name = "Disk" }, k.orange, c.print("{s}", .{model.rate(&b, sy.read_sec + sy.written_sec)}));
    item(c, a, k, .{ .page = .network, .icon = "network", .name = "Network" }, k.teal, c.print("{s}", .{model.rate(&b, sy.net_in_sec + sy.net_out_sec)}));
    section(c, k, "System");
    item(c, a, k, .{ .page = .apps, .icon = "square.grid.3x3", .name = "Apps" }, k.purple, c.print("{d}", .{a.apps.items.len}));
    item(c, a, k, .{ .page = .about, .icon = "desktopcomputer", .name = "About This Mac" }, k.gray, "");
    ui.spacer(c);
    status(c, a, k);
}

fn section(c: *ui.Context, k: theme.Colors, name: []const u8) void {
    const d = ui.div(c).row().wFull().px(8).pt(14).pb(4);
    defer d.end();
    ui.text(c, name, .{ .size = 11, .weight = .semibold, .color = k.tertiary });
}

fn item(c: *ui.Context, a: *App, k: theme.Colors, it: Item, color: ui.Color, figure: []const u8) void {
    ui.key(c, it.name);
    const on = a.page == it.page;
    var d = ui.div(c).row().wFull().h(30).itemsCenter().gap(9).px(7).rounded(7).control();
    d = if (on) d.bg(k.picked) else d.hover(k.hover);
    defer d.end();
    if (d.clicked()) {
        a.page = it.page;
        a.menu = false;
    }
    kit.chip(c, it.icon, if (on) k.on_picked else color, 20, false);
    ui.text(c, it.name, .{ .size = 13, .weight = if (on) .semibold else .regular, .color = if (on) k.on_picked else k.text });
    ui.spacer(c);
    if (figure.len > 0) ui.text(c, figure, .{ .size = 11, .mono = true, .color = if (on) k.on_picked.alpha(0.8) else k.secondary });
}

/// "Live · every 2 s", or "Paused".
fn status(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = ui.div(c).row().wFull().gap(7).itemsCenter().px(8).pb(14);
    defer d.end();
    _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = if (a.paused) k.orange else k.green }, .none, null);
    ui.text(c, if (a.paused) "Paused" else "Live · every 2 s", .{ .size = 11, .color = k.secondary });
}

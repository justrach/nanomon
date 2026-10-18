//! About This Mac: the machine's name, model and chip, its cores of each
//! kind, its GPU, memory and system, and how long it has been up.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const view = @import("view.zig");
const App = @import("app.zig").App;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const info = s.info;
    const sy = s.system;
    {
        const h = kit.header(c, k, "About This Mac", info.os);
        defer h.end();
    }
    const body = view.body(c);
    defer body.end();
    const center = ui.div(c).column().wFull().itemsCenter().pt(24);
    defer center.end();
    const d = kit.card(c, k).w(460).itemsCenter().gap(16).p(28);
    defer d.end();
    kit.chip(c, "desktopcomputer", k.blue, 72, true);
    {
        const t = ui.div(c).column().itemsCenter().gap(3);
        defer t.end();
        ui.text(c, info.host, .{ .size = 20, .weight = .bold, .color = k.text });
        ui.text(c, c.print("{s} · {s}", .{ info.model, info.chip }), .{ .size = 12, .color = k.secondary });
    }
    const list = ui.div(c).column().wFull().gap(2).pt(6);
    defer list.end();
    var b: [32]u8 = undefined;
    kit.line(c, k, "Chip", info.chip, null);
    if (info.frugal > 0) {
        kit.line(c, k, "Cores", c.print("{d} ({d} {s}, {d} {s})", .{ info.fast + info.frugal, info.fast, info.fast_name, info.frugal, info.frugal_name }), null);
    } else kit.line(c, k, "Cores", c.print("{d}", .{sy.cores}), null);
    if (info.gpu.len > 0) kit.line(c, k, "Graphics", if (info.gpu_cores > 0) c.print("{s}, {d} cores", .{ info.gpu, info.gpu_cores }) else info.gpu, null);
    kit.line(c, k, "Memory", c.print("{s}", .{model.bytes(&b, sy.mem_total)}), null);
    kit.line(c, k, "System", info.os, null);
    kit.line(c, k, "Model", info.model, null);
    kit.line(c, k, "Up for", c.print("{s}", .{model.uptime(&b, sy.uptime_s)}), null);
}

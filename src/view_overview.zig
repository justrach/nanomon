//! The Overview page: a tile for each part of the machine (CPU, memory,
//! GPU, disk, network), its figure now over a small graph of the range,
//! each opening its page; the processes busiest now; and the machine in
//! a few lines.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const view = @import("view.zig");
const memory = @import("view_memory.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

const mini_h = 64;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    var b: [4][32]u8 = undefined;
    {
        const h = kit.header(c, k, "Overview", c.print("{s} · {s} · up {s}", .{ s.info.host, s.info.chip, model.uptime(&b[0], sy.uptime_s) }));
        defer h.end();
        kit.ranges(c, a, k);
    }
    const body = view.body(c);
    defer body.end();
    const mem: f32 = if (sy.mem_total > 0) @floatCast(@as(f64, @floatFromInt(sy.memUsed())) / @as(f64, @floatFromInt(sy.mem_total)) * 100) else 0;
    {
        const r = ui.div(c).row().wFull().gap(14);
        defer r.end();
        if (tile(c, k, "cpu", "CPU", k.accent, c.print("{d:.0}%", .{sy.cpuBusy()}), c.print("user {d:.0}% · system {d:.0}%", .{ sy.cpu_user, sy.cpu_system }))) a.page = .cpu;
        kit.dots(c, k, a, &.{ .{ .values = s.system_history.slice(), .color = k.system }, .{ .values = s.user_history.slice(), .color = k.user } }, 100, mini_h, false, null);
        c.end();
        if (tile(c, k, "memorychip", "Memory", k.green, c.print("{d:.0}%", .{mem}), c.print("{s} of {s} · pressure {s}", .{ model.bytes(&b[1], sy.memUsed()), model.bytes(&b[2], sy.mem_total), memory.pressureName(sy.pressure) }))) a.page = .memory;
        kit.dots(c, k, a, &.{ .{ .values = s.app_history.slice(), .color = k.green }, .{ .values = s.wired_history.slice(), .color = k.orange }, .{ .values = s.compressed_history.slice(), .color = k.purple } }, 100, mini_h, false, null);
        c.end();
    }
    {
        const r = ui.div(c).row().wFull().gap(14);
        defer r.end();
        if (tile(c, k, "cube", "GPU", k.red, c.print("{d:.0}%", .{sy.gpu}), c.print("{s} in use", .{model.bytes(&b[0], sy.gpu_memory)}))) a.page = .gpu;
        kit.dots(c, k, a, &.{.{ .values = s.gpu_history.slice(), .color = k.red }}, 100, mini_h, false, null);
        c.end();
        if (tile(c, k, "internaldrive", "Disk", k.orange, c.print("{s}", .{model.rate(&b[1], sy.read_sec + sy.written_sec)}), c.print("{s} read · {s} written", .{ model.rate(&b[2], sy.read_sec), model.rate(&b[3], sy.written_sec) }))) a.page = .disk;
        kit.dots(c, k, a, &.{ .{ .values = s.read_history.slice(), .color = k.blue }, .{ .values = s.write_history.slice(), .color = k.orange } }, null, mini_h, false, null);
        c.end();
        if (tile(c, k, "network", "Network", k.teal, c.print("{s}", .{model.rate(&b[0], sy.net_in_sec + sy.net_out_sec)}), c.print("{s} in · {s} out", .{ model.rate(&b[1], sy.net_in_sec), model.rate(&b[2], sy.net_out_sec) }))) a.page = .network;
        kit.dots(c, k, a, &.{ .{ .values = s.in_history.slice(), .color = k.teal }, .{ .values = s.out_history.slice(), .color = k.blue } }, null, mini_h, false, null);
        c.end();
    }
    const r = ui.div(c).row().wFull().gap(14).itemsStart();
    defer r.end();
    busiest(c, a, k);
    machine(c, a, k);
}

/// Opens a tile: its chip, name, figure and note; the caller adds its
/// graph, then ends it. Whether it was clicked.
fn tile(c: *ui.Context, k: theme.Colors, icon: []const u8, name: []const u8, color: ui.Color, figure: []const u8, note: []const u8) bool {
    ui.key(c, name);
    const d = kit.card(c, k).grow().w(0).gap(10).hover(k.well.alpha(0.6)).control();
    const clicked = d.clicked();
    {
        const t = kit.title(c, icon, name, color);
        defer t.end();
        ui.icon(c, "chevron.right", .{ .size = 9, .weight = .semibold, .color = k.tertiary });
    }
    {
        const v = ui.div(c).column().gap(1).clip();
        defer v.end();
        ui.text(c, figure, .{ .size = 24, .weight = .bold, .color = k.text });
        ui.text(c, note, .{ .size = 11, .color = k.secondary });
    }
    return clicked;
}

/// The processes busiest now, with their CPU as bars.
fn busiest(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = kit.card(c, k).grow().w(0).gap(6);
    defer d.end();
    {
        const t = kit.title(c, "flame", "Busiest Now", k.accent);
        defer t.end();
        ui.text(c, "% of one core", .{ .size = 11, .color = k.secondary });
    }
    var best: [7]model.Process = undefined;
    const n = memory.largest(a, &best, .cpu);
    const most = if (n > 0) @max(100, best[0].cpu) else 100;
    for (best[0..n]) |p| {
        ui.key(c, c.print("busy-{d}", .{p.pid}));
        const r = ui.div(c).row().wFull().gap(10).itemsCenter().h(22);
        defer r.end();
        memory.procName(c, a, k, p, 190);
        kit.bar(c, k, p.cpu / most, k.user);
        const v = ui.div(c).row().w(52).justifyEnd();
        ui.text(c, c.print("{d:.1}%", .{p.cpu}), .{ .size = 11.5, .weight = .semibold, .color = k.text });
        v.end();
    }
}

fn machine(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = kit.card(c, k).w(320).gap(4);
    defer d.end();
    {
        const t = kit.title(c, "desktopcomputer", "This Mac", k.gray);
        defer t.end();
    }
    const gap = ui.div(c).row().h(6);
    gap.end();
    var b: [32]u8 = undefined;
    kit.line(c, k, "Chip", s.info.chip, null);
    kit.line(c, k, "Cores", if (s.info.frugal > 0) c.print("{d} + {d}", .{ s.info.fast, s.info.frugal }) else c.print("{d}", .{sy.cores}), null);
    kit.line(c, k, "Load", c.print("{d:.2} · {d:.2} · {d:.2}", .{ sy.load[0], sy.load[1], sy.load[2] }), null);
    kit.line(c, k, "Processes", c.print("{s}", .{model.count(&b, s.procs.items.len)}), null);
    if (sy.threads > 0) kit.line(c, k, "Threads", c.print("{s}", .{model.count(&b, sy.threads)}), null);
    kit.line(c, k, "Thermal", @import("view_cpu.zig").thermalName(sy.thermal), null);
}

//! The Memory page: memory in use now and across the range, app memory,
//! wired and compressed stacked; how hard memory is pressed; where it
//! goes (the busiest processes). And the GPU page: its load across the
//! range, the renderer and tiler apart, and the memory it holds.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const view = @import("view.zig");
const App = @import("app.zig").App;

fn usedPercent(sy: model.System) f32 {
    if (sy.mem_total == 0) return 0;
    return @floatCast(@as(f64, @floatFromInt(sy.memUsed())) / @as(f64, @floatFromInt(sy.mem_total)) * 100);
}

pub fn pressureName(p: f32) []const u8 {
    if (p >= 80) return "Critical";
    if (p >= 50) return "Warning";
    return "Normal";
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    var b1: [32]u8 = undefined;
    {
        const h = kit.header(c, k, "Memory", c.print("{s} · {d:.0}% in use", .{ model.bytes(&b1, sy.mem_total), usedPercent(sy) }));
        defer h.end();
        kit.ranges(c, a, k);
    }
    const body = view.body(c);
    defer body.end();
    usage(c, a, k, 150);
    const r = ui.div(c).row().wFull().gap(14).itemsStart();
    defer r.end();
    pressure(c, a, k);
    top(c, a, k);
}

/// The Memory Usage card, its graph `h` high.
pub fn usage(c: *ui.Context, a: *App, k: theme.Colors, h: f32) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = kit.card(c, k);
    defer d.end();
    {
        const t = kit.title(c, "memorychip", "Memory Usage", k.green);
        defer t.end();
        if (!kit.readout(c, k, a, .memory, &.{ "App", "Wired", "Compressed" }, kit.percent))
            kit.legend(c, k, &.{ .{ "App", k.green }, .{ "Wired", k.orange }, .{ "Compressed", k.purple } });
    }
    var b: [4][32]u8 = undefined;
    {
        const r = ui.div(c).row().wFull().gap(16).itemsStart();
        defer r.end();
        kit.big(c, k, "In use", c.print("{d:.0}", .{usedPercent(sy)}), "%");
        kit.stat(c, k, "App Memory", c.print("{s}", .{model.bytes(&b[0], sy.mem_app)}), "");
        kit.stat(c, k, "Wired", c.print("{s}", .{model.bytes(&b[1], sy.mem_wired)}), "");
        kit.stat(c, k, "Compressed", c.print("{s}", .{model.bytes(&b[2], sy.mem_compressed)}), "");
        kit.stat(c, k, "Cached Files", c.print("{s}", .{model.bytes(&b[3], sy.mem_cached)}), c.print("swap {s}", .{model.bytes(&b[0], sy.swap_used)}));
    }
    const series = [_]kit.Series{
        .{ .values = s.app_history.slice(), .color = k.green },
        .{ .values = s.wired_history.slice(), .color = k.orange },
        .{ .values = s.compressed_history.slice(), .color = k.purple },
    };
    kit.dots(c, k, a, &series, 100, h, true, .memory);
}

/// How hard memory is pressed, and its range in green, yellow and red.
fn pressure(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = a.sampler.system.pressure;
    const d = kit.card(c, k).w(300);
    defer d.end();
    {
        const t = kit.title(c, "gauge.with.dots.needle.33percent", "Pressure", k.green);
        defer t.end();
    }
    const color = if (p >= 80) k.red else if (p >= 50) k.yellow else k.green;
    {
        const r = ui.div(c).row().itemsEnd().gap(8);
        defer r.end();
        ui.text(c, c.print("{d:.0}%", .{p}), .{ .size = 28, .weight = .bold, .color = k.text });
        const n = ui.div(c).column().pb(5);
        defer n.end();
        ui.text(c, pressureName(p), .{ .size = 12, .weight = .semibold, .color = color });
    }
    {
        // A bar grows along a row.
        const r = ui.div(c).row().wFull();
        defer r.end();
        kit.bar(c, k, p / 100, color);
    }
    ui.text(c, "How hard the system works to find free memory: compressing, swapping. Green is fine; red means apps are waiting on memory.", .{ .size = 11, .color = k.secondary, .wrap = true });
}

/// The processes holding the most memory, with bars against the first.
fn top(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = kit.card(c, k).grow().w(0).gap(6);
    defer d.end();
    {
        const t = kit.title(c, "list.bullet", "Largest Processes", k.green);
        defer t.end();
    }
    var best: [8]model.Process = undefined;
    const n = largest(a, &best, .memory);
    const most: f32 = if (n > 0) @floatFromInt(@max(1, best[0].memory)) else 1;
    var b: [32]u8 = undefined;
    for (best[0..n]) |p| {
        ui.key(c, c.print("top-{d}", .{p.pid}));
        const r = ui.div(c).row().wFull().gap(10).itemsCenter().h(22);
        defer r.end();
        procName(c, a, k, p, 170);
        kit.bar(c, k, @as(f32, @floatFromInt(p.memory)) / most, k.green);
        const v = ui.div(c).row().w(72).justifyEnd();
        ui.text(c, c.print("{s}", .{model.bytes(&b, p.memory)}), .{ .size = 11.5, .weight = .semibold, .color = k.text });
        v.end();
    }
}

/// A process's icon and name in `w` points.
pub fn procName(c: *ui.Context, a: *App, k: theme.Colors, p: model.Process, w: f32) void {
    const r = ui.div(c).row().w(w).gap(7).itemsCenter().clip();
    defer r.end();
    const icon = ui.div(c).row().w(16).h(16).center();
    if (a.icons.get(p.bundle)) |png| _ = ui.image(c, .{ .key = p.bundle, .bytes = png, .max_width = 16, .max_height = 16, .radius = 0 });
    icon.end();
    ui.text(c, p.name, .{ .size = 12, .color = k.text });
}

/// The `out.len` busiest processes by `by` (CPU, memory or bytes written).
pub fn largest(a: *App, out: []model.Process, by: enum { cpu, memory, written }) usize {
    var n: usize = 0;
    for (a.sampler.procs.items) |p| {
        if (!p.known) continue;
        const v = key(p, by);
        if (v <= 0) continue;
        // Insert in order, the smallest falling off the end.
        var at = n;
        while (at > 0 and key(out[at - 1], by) < v) : (at -= 1) {}
        if (at >= out.len) continue;
        var j = @min(n, out.len - 1);
        while (j > at) : (j -= 1) out[j] = out[j - 1];
        out[at] = p;
        n = @min(n + 1, out.len);
    }
    return n;
}

fn key(p: model.Process, by: anytype) f64 {
    return switch (by) {
        .cpu => p.cpu,
        .memory => @floatFromInt(p.memory),
        .written => if (p.detailed()) @floatFromInt(p.disk_written) else 0,
    };
}

pub fn gpuPage(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    const info = s.info;
    {
        const h = kit.header(c, k, "GPU", if (info.gpu_cores > 0) c.print("{s} · {d} cores", .{ info.gpu, info.gpu_cores }) else c.print("{s}", .{info.gpu}));
        defer h.end();
        kit.ranges(c, a, k);
    }
    const body = view.body(c);
    defer body.end();
    gpuLoad(c, a, k, 150);
    const d = kit.card(c, k).gap(10);
    defer d.end();
    {
        const t = kit.title(c, "cube", "Engines", k.red);
        defer t.end();
    }
    var b: [32]u8 = undefined;
    const lines = [_]struct { []const u8, f32 }{ .{ "Device", sy.gpu }, .{ "Renderer", sy.gpu_renderer }, .{ "Tiler", sy.gpu_tiler } };
    for (lines) |l| {
        ui.key(c, l[0]);
        const r = ui.div(c).row().wFull().gap(12).itemsCenter().h(22);
        defer r.end();
        const name = ui.div(c).row().w(80);
        ui.text(c, l[0], .{ .size = 12, .color = k.secondary });
        name.end();
        kit.bar(c, k, l[1] / 100, k.red);
        const v = ui.div(c).row().w(44).justifyEnd();
        ui.text(c, c.print("{d:.0}%", .{l[1]}), .{ .size = 12, .weight = .semibold, .color = k.text });
        v.end();
    }
    kit.line(c, k, "Memory in use", c.print("{s}", .{model.bytes(&b, sy.gpu_memory)}), null);
}

/// The GPU Load card, its graph `h` high.
pub fn gpuLoad(c: *ui.Context, a: *App, k: theme.Colors, h: f32) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = kit.card(c, k);
    defer d.end();
    {
        const t = kit.title(c, "cube", "GPU Load", k.red);
        defer t.end();
        _ = kit.readout(c, k, a, .gpu, &.{"Device"}, kit.percent);
    }
    var b: [32]u8 = undefined;
    {
        const r = ui.div(c).row().wFull().gap(16).itemsStart();
        defer r.end();
        kit.big(c, k, "Now", c.print("{d:.0}", .{sy.gpu}), "%");
        kit.stat(c, k, "Renderer", c.print("{d:.0}%", .{sy.gpu_renderer}), "");
        kit.stat(c, k, "Tiler", c.print("{d:.0}%", .{sy.gpu_tiler}), "");
        kit.stat(c, k, "Memory", c.print("{s}", .{model.bytes(&b, sy.gpu_memory)}), "in use");
        const n = a.range.samples();
        kit.stat(c, k, "Average", c.print("{d:.0}%", .{@import("view_cpu.zig").mean(s.gpu_history.slice(), n)}), c.print("over {s}", .{a.range.title()}));
    }
    kit.dots(c, k, a, &.{.{ .values = s.gpu_history.slice(), .color = k.red }}, 100, h, true, .gpu);
}

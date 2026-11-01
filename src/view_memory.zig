//! The Memory page, laid out as Pulse has it: memory in use over the range,
//! then where it goes by type (a ring and its legend), how hard it is
//! pressed (with the pages read in and out), and the swap; then the memory
//! each app holds, as a row of cards and as a list. And the GPU page: its
//! load across the range, the renderer and tiler apart, and its memory.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const view = @import("view.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

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
    {
        const r = ui.div(c).row().wFull().gap(14).itemsStart();
        defer r.end();
        byType(c, a, k);
        pressure(c, a, k);
        swap(c, a, k);
    }
    appsGrid(c, a, k);
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

/// Where the memory goes: a ring of what is in use, and each kind beside it.
fn byType(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    const d = kit.card(c, k).grow().w(0).gap(10);
    defer d.end();
    {
        const t = kit.title(c, "chart.pie", "Memory by Type", k.blue);
        defer t.end();
    }
    {
        const r = ui.div(c).row().wFull().gap(16).itemsCenter();
        defer r.end();
        {
            const col = ui.div(c).column().itemsCenter().gap(1);
            defer col.end();
            nanoui.kit.ring(c, usedPercent(sy) / 100, .{ .size = 96, .color = k.green });
            ui.text(c, "in use", .{ .size = 10.5, .color = k.secondary });
        }
        const list = ui.div(c).column().grow().w(0).gap(3);
        defer list.end();
        var b: [5][32]u8 = undefined;
        // What is available already counts the cache; the rest is free.
        const free = sy.mem_total -| sy.memUsed() -| sy.mem_cached;
        kit.line(c, k, "App", c.print("{s}", .{model.bytes(&b[0], sy.mem_app)}), k.green);
        kit.line(c, k, "Wired", c.print("{s}", .{model.bytes(&b[1], sy.mem_wired)}), k.orange);
        kit.line(c, k, "Compressed", c.print("{s}", .{model.bytes(&b[2], sy.mem_compressed)}), k.purple);
        kit.line(c, k, "Cached", c.print("{s}", .{model.bytes(&b[3], sy.mem_cached)}), k.gray);
        kit.line(c, k, "Free", c.print("{s}", .{model.bytes(&b[4], free)}), k.tertiary);
    }
}

/// How hard memory is pressed, the pages moving, and the state in a word.
fn pressure(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    const p = sy.pressure;
    const d = kit.card(c, k).w(268).gap(8);
    defer d.end();
    {
        const t = kit.title(c, "gauge.with.dots.needle.33percent", "Pressure", k.teal);
        defer t.end();
        ui.text(c, pressureName(p), .{ .size = 10.5, .weight = .semibold, .color = if (p >= 80) k.red else if (p >= 50) k.yellow else k.green });
    }
    {
        const col = ui.div(c).column().wFull().itemsCenter().gap(1);
        defer col.end();
        nanoui.kit.ring(c, p / 100, .{ .size = 96, .label = c.print("{d:.0}%", .{p}), .color = if (p >= 80) k.red else if (p >= 50) k.yellow else k.green });
        ui.text(c, "pressure", .{ .size = 10.5, .color = k.secondary });
    }
    // Only where the platform counts them.
    if (sy.page_ins_sec > 0 or sy.page_outs_sec > 0) {
        var b: [2][24]u8 = undefined;
        kit.line(c, k, "Page-ins", c.print("{s}", .{model.rate(&b[0], sy.page_ins_sec)}), null);
        kit.line(c, k, "Swap-outs", c.print("{s}", .{model.rate(&b[1], sy.page_outs_sec)}), null);
    }
}

/// The page file's size, and what it holds.
fn swap(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    const d = kit.card(c, k).w(268).gap(6);
    defer d.end();
    {
        const t = kit.title(c, "arrow.left.arrow.right", "Swap", k.orange);
        defer t.end();
    }
    var b: [4][32]u8 = undefined;
    if (sy.swap_total > 0 and sy.mem_total > 0) {
        kit.line(c, k, "Swap size", c.print("{s}", .{model.bytes(&b[0], sy.swap_total)}), null);
        kit.line(c, k, "In use", c.print("{s}", .{model.bytes(&b[1], sy.swap_used)}), null);
        {
            const r = ui.div(c).row().wFull().pt(2);
            defer r.end();
            kit.bar(c, k, @as(f32, @floatFromInt(sy.swap_used)) / @as(f32, @floatFromInt(@max(1, sy.swap_total))), k.orange);
        }
    } else kit.line(c, k, "In use", c.print("{s}", .{model.bytes(&b[0], sy.swap_used)}), null);
    kit.line(c, k, "Compressed", c.print("{s}", .{model.bytes(&b[2], sy.mem_compressed)}), null);
    ui.text(c, "Memory Windows compressed to hold more, in place of writing it out.", .{ .size = 10.5, .color = k.tertiary, .wrap = true });
}

/// An app's icon at `size` points, or a placeholder.
fn appIcon(c: *ui.Context, a: *App, bundle: []const u8, size: f32) void {
    const box = ui.div(c).row().w(size).h(size).center();
    defer box.end();
    if (a.icons.get(bundle)) |png| {
        _ = ui.image(c, .{ .key = bundle, .bytes = png, .max_width = size, .max_height = size, .radius = 0 });
    } else {
        ui.icon(c, "app.dashed", .{ .size = size * 0.7, .color = c.theme.muted });
    }
}

/// The memory each app holds, a card each.
fn appsGrid(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = kit.card(c, k).gap(10);
    defer d.end();
    {
        const t = kit.title(c, "square.grid.2x2", "Memory by App", k.purple);
        defer t.end();
        if (ui.button(c, "Show All", .{ .variant = .ghost, .size = 11 }).clicked) a.page = .apps;
    }
    var best: [7]app_mod.AppRow = undefined;
    const n = topApps(a, &best);
    if (n == 0) {
        ui.text(c, "No app's processes could be read.", .{ .size = 11.5, .color = k.secondary });
        return;
    }
    const r = ui.div(c).row().wFull().gap(10);
    defer r.end();
    var b: [32]u8 = undefined;
    for (best[0..n]) |app| {
        ui.key(c, c.print("mem-app-{d}", .{app.pid}));
        const cell = ui.div(c).column().grow().w(0).gap(6).p(10).rounded(8).bg(k.well).hover(k.hover).control();
        defer cell.end();
        if (cell.clicked()) a.page = .apps;
        appIcon(c, a, app.bundle, 22);
        ui.spacer(c);
        ui.text(c, app.name, .{ .size = 11.5, .weight = .medium, .color = k.text });
        ui.text(c, c.print("{s}", .{model.bytes(&b, app.memory)}), .{ .size = 10.5, .mono = true, .color = k.secondary });
    }
}

/// The apps holding the most memory, with how many processes each.
fn top(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = kit.card(c, k).gap(4);
    defer d.end();
    {
        const t = kit.title(c, "list.bullet", "Using the Most Memory", k.green);
        defer t.end();
        if (ui.button(c, "Show All", .{ .variant = .ghost, .size = 11 }).clicked) a.page = .apps;
    }
    var best: [8]app_mod.AppRow = undefined;
    const n = topApps(a, &best);
    if (n == 0) {
        ui.text(c, "No app's processes could be read.", .{ .size = 11.5, .color = k.secondary });
        return;
    }
    const most: f32 = @floatFromInt(@max(1, best[0].memory));
    var b: [32]u8 = undefined;
    for (best[0..n]) |app| {
        ui.key(c, c.print("top-app-{d}", .{app.pid}));
        const r = ui.div(c).row().wFull().gap(10).itemsCenter().h(24);
        defer r.end();
        appIcon(c, a, app.bundle, 16);
        ui.text(c, app.name, .{ .size = 12, .color = k.text });
        if (app.processes > 1) ui.text(c, c.print("{d}", .{app.processes}), .{ .size = 10, .color = k.tertiary });
        kit.bar(c, k, @as(f32, @floatFromInt(app.memory)) / most, k.green);
        const v = ui.div(c).row().w(72).justifyEnd();
        defer v.end();
        ui.text(c, c.print("{s}", .{model.bytes(&b, app.memory)}), .{ .size = 11.5, .weight = .semibold, .mono = true, .color = k.text });
    }
}

/// The `out.len` apps holding the most memory.
fn topApps(a: *App, out: []app_mod.AppRow) usize {
    var n: usize = 0;
    for (a.apps.items) |row| {
        if (row.memory == 0) continue;
        // Insert in order, the smallest falling off the end.
        var at = n;
        while (at > 0 and out[at - 1].memory < row.memory) : (at -= 1) {}
        if (at >= out.len) continue;
        var j = @min(n, out.len - 1);
        while (j > at) : (j -= 1) out[j] = out[j - 1];
        out[at] = row;
        n = @min(n + 1, out.len);
    }
    return n;
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

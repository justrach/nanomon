//! The CPU page: the processor's load now (user and system, how hot the
//! machine runs, the average over the range) over a dot-matrix graph of
//! the range, system red under user blue; every core's load, the fast ones
//! and the frugal ones apart; and the machine's activity: load averages
//! against its cores, tasks, threads, uptime.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const view = @import("view.zig");
const App = @import("app.zig").App;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const info = a.sampler.info;
    const sub = if (info.frugal > 0)
        c.print("{s} · {d} {s} + {d} {s} cores", .{ info.chip, info.fast, info.fast_name, info.frugal, info.frugal_name })
    else
        c.print("{s} · {d} cores", .{ info.chip, a.sampler.system.cores });
    {
        const h = kit.header(c, k, "CPU", sub);
        defer h.end();
        kit.ranges(c, a, k);
    }
    const b = view.body(c);
    defer b.end();
    load(c, a, k, 150);
    const r = ui.div(c).row().wFull().gap(14).itemsStart();
    defer r.end();
    cores(c, a, k);
    activity(c, a, k);
}

/// The mean of the last `n` values.
pub fn mean(values: []const f32, n: usize) f32 {
    const v = values[values.len -| n..];
    if (v.len == 0) return 0;
    var s: f32 = 0;
    for (v) |x| s += x;
    return s / @as(f32, @floatFromInt(v.len));
}

pub fn thermalName(t: u8) []const u8 {
    return switch (t) {
        0 => "Nominal",
        1 => "Fair",
        2 => "Serious",
        else => "Critical",
    };
}

/// The Processor Load card, its graph `h` high.
pub fn load(c: *ui.Context, a: *App, k: theme.Colors, h: f32) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = kit.card(c, k);
    defer d.end();
    const series = [_]kit.Series{ .{ .values = s.system_history.slice(), .color = k.system }, .{ .values = s.user_history.slice(), .color = k.user } };
    {
        const t = kit.title(c, "cpu", "Processor Load", k.accent);
        defer t.end();
        if (!kit.readout(c, k, a, .cpu, &.{ "System", "User" }, kit.percent))
            kit.legend(c, k, &.{ .{ "User", k.user }, .{ "System", k.system } });
    }
    {
        const r = ui.div(c).row().wFull().gap(16).itemsStart();
        defer r.end();
        kit.big(c, k, "Now", c.print("{d:.0}", .{sy.cpuBusy()}), "%");
        kit.stat(c, k, "User", c.print("{d:.0}%", .{sy.cpu_user}), "");
        kit.stat(c, k, "System", c.print("{d:.0}%", .{sy.cpu_system}), "");
        kit.stat(c, k, "Thermal", thermalName(sy.thermal), c.print("load {d:.2}", .{sy.load[0]}));
        const n = a.range.samples();
        kit.stat(c, k, "Average", c.print("{d:.0}%", .{mean(s.user_history.slice(), n) + mean(s.system_history.slice(), n)}), c.print("over {s}", .{a.range.title()}));
    }
    kit.dots(c, k, a, &series, 100, h, true, .cpu);
}

/// Every core's load: the fast ones, then the frugal ones, two a line.
fn cores(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const info = s.info;
    const d = kit.card(c, k).grow().w(0);
    defer d.end();
    {
        const t = kit.title(c, "cpu", "Cores", k.accent);
        defer t.end();
        ui.text(c, c.print("{d} logical processors", .{s.cores}), .{ .size = 11, .color = k.secondary });
    }
    const frugal = @min(info.frugal, s.cores);
    if (frugal > 0) {
        group(c, a, k, c.print("{s} Cores", .{info.fast_name}), frugal, s.cores, k.fast);
        group(c, a, k, c.print("{s} Cores", .{info.frugal_name}), 0, frugal, k.frugal);
    } else group(c, a, k, "Cores", 0, s.cores, k.fast);
}

fn group(c: *ui.Context, a: *App, k: theme.Colors, name: []const u8, from: u32, to: u32, color: ui.Color) void {
    ui.text(c, name, .{ .size = 11, .weight = .medium, .color = k.secondary });
    var i = from;
    while (i < to) : (i += 2) {
        const r = ui.div(c).row().wFull().gap(18);
        defer r.end();
        core(c, a, k, i, color);
        if (i + 1 < to) core(c, a, k, i + 1, color) else {
            const pad = ui.div(c).row().grow().w(0);
            pad.end();
        }
    }
}

fn core(c: *ui.Context, a: *App, k: theme.Colors, i: u32, color: ui.Color) void {
    ui.key(c, c.print("core-{d}", .{i}));
    const r = ui.div(c).row().grow().w(0).gap(10).itemsCenter().h(20);
    defer r.end();
    const label = ui.div(c).row().w(52);
    ui.text(c, c.print("Core {d}", .{i + 1}), .{ .size = 11.5, .color = k.secondary });
    label.end();
    const v = a.sampler.core_load[i];
    kit.bar(c, k, v / 100, color);
    const pct = ui.div(c).row().w(38).justifyEnd();
    ui.text(c, c.print("{d:.0}%", .{v}), .{ .size = 11.5, .weight = .semibold, .color = k.text });
    pct.end();
}

/// How loaded the machine is against its cores.
fn saturation(load_1: f32, cores_n: u32) []const u8 {
    const r = load_1 / @as(f32, @floatFromInt(@max(1, cores_n)));
    if (r < 0.5) return "Relaxed";
    if (r < 1) return "Busy";
    return "Saturated";
}

fn activity(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    const d = kit.card(c, k).w(330).gap(4);
    defer d.end();
    {
        const t = kit.title(c, "waveform.path.ecg", "Activity", k.text);
        defer t.end();
    }
    const gap = ui.div(c).row().h(6);
    gap.end();
    var b: [32]u8 = undefined;
    const sat = saturation(sy.load[0], sy.cores);
    kit.line(c, k, "Load, last minute", c.print("{d:.2} · {s}", .{ sy.load[0], sat }), if (std.mem.eql(u8, sat, "Saturated")) k.system else null);
    kit.line(c, k, "Load, 5 minutes", c.print("{d:.2}", .{sy.load[1]}), null);
    kit.line(c, k, "Load, 15 minutes", c.print("{d:.2}", .{sy.load[2]}), null);
    kit.line(c, k, "Processes", c.print("{s}", .{model.count(&b, if (sy.tasks > 0) sy.tasks else a.sampler.procs.items.len)}), null);
    if (sy.threads > 0) kit.line(c, k, "Threads", c.print("{s}", .{model.count(&b, sy.threads)}), null);
    kit.line(c, k, "Uptime", c.print("{s}", .{model.uptime(&b, sy.uptime_s)}), null);
}

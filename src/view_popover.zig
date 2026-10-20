//! The panel under the menu bar readout, as menu bar monitors lay theirs
//! out: the CPU now over a minute of it in dots; user, system and how hot;
//! every core as a ring of dots, the frugal ones and the fast ones apart;
//! the busiest processes; the GPU in four dial rings; the load averages
//! and uptime; and Open nanomon. The gear turns to what the menu bar shows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const menubar = @import("menubar.zig");
const App = @import("app.zig").App;

const pad = 16;
const inner = menubar.popover_w - 2 * pad;
/// A core's ring, and the room it takes.
const core_d: f32 = 24;
const core_pitch: f32 = 30;

/// The panel's height for what it shows.
pub fn height(a: *App) f64 {
    if (a.settings_open) return 286;
    const per_row: usize = @intFromFloat(@floor((inner + core_pitch - core_d) / core_pitch));
    const rows = (@max(a.sampler.cores, 1) + per_row - 1) / per_row;
    return 712 + @as(f64, @floatFromInt(rows - 1)) * core_pitch;
}

pub fn view(a: *App, c: *ui.Context) void {
    const dark = a.dark orelse nanoui.isDark();
    c.theme = theme.ui(dark);
    const k = theme.colors(dark);
    c.frameIn(a.tick(if (a.clock) |f| f() else c.time));
    a.icons.frame();
    const root = ui.div(c).column().sizeFull().bg(k.card).px(pad).pt(14).pb(12).gap(12);
    defer root.end();
    if (a.settings_open) settings(c, a, k) else panel(c, a, k);
    footer(c, a, k);
    if (a.icons.pending) c.frameIn(1.0 / 60.0);
}

fn section(c: *ui.Context, k: theme.Colors, name: []const u8, note: []const u8) void {
    const r = ui.div(c).row().wFull().itemsCenter();
    defer r.end();
    ui.text(c, name, .{ .size = 11.5, .weight = .semibold, .color = k.secondary });
    ui.spacer(c);
    if (note.len > 0) ui.text(c, note, .{ .size = 11.5, .color = k.tertiary });
}

fn panel(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    {
        const r = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer r.end();
        kit.chip(c, "cpu", k.accent, 26, false);
        ui.text(c, "CPU", .{ .size = 15, .weight = .semibold, .color = k.accent });
        ui.spacer(c);
        const n = ui.div(c).row().itemsEnd().gap(1);
        defer n.end();
        ui.text(c, c.print("{d:.0}", .{sy.cpuBusy()}), .{ .size = 28, .weight = .bold, .mono = true, .color = k.text });
        const u = ui.div(c).column().pb(4);
        defer u.end();
        ui.text(c, "%", .{ .size = 12, .weight = .medium, .mono = true, .color = k.secondary });
    }
    // The last minute, whatever the window's graphs span.
    const range = a.range;
    a.range = .m1;
    kit.dots(c, k, a, &.{ .{ .values = s.system_history.slice(), .color = k.system }, .{ .values = s.user_history.slice(), .color = k.user } }, 100, 62, false, null);
    a.range = range;
    {
        const r = ui.div(c).row().wFull().gap(12).itemsStart();
        defer r.end();
        kit.stat(c, k, "User", c.print("{d:.0}%", .{sy.cpu_user}), "");
        kit.stat(c, k, "System", c.print("{d:.0}%", .{sy.cpu_system}), "");
        if (sy.cpu_temp > 0)
            kit.stat(c, k, "Temperature", c.print("{d:.0} °C", .{sy.cpu_temp}), c.print("hottest {d:.0} °C", .{sy.cpu_temp_max}))
        else
            kit.stat(c, k, "Thermal", @import("view_cpu.zig").thermalName(sy.thermal), "");
    }
    cores(c, a, k);
    processes(c, a, k);
    gpu(c, a, k);
    {
        const l = ui.div(c).column().wFull().gap(0);
        defer l.end();
        kit.line(c, k, "Processor Load", c.print("{d:.2}  {d:.2}  {d:.2}", .{ sy.load[0], sy.load[1], sy.load[2] }), null);
        var b: [32]u8 = undefined;
        kit.line(c, k, "Uptime", c.print("{s}", .{model.uptime(&b, sy.uptime_s)}), null);
    }
}

/// Each core a ring, the frugal ones first (as the system lists them).
fn cores(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const info = s.info;
    const frugal = @min(info.frugal, s.cores);
    const all = ui.div(c).column().wFull().gap(8);
    defer all.end();
    section(c, k, "Cores", "");
    const per_row: usize = @intFromFloat(@floor((inner + core_pitch - core_d) / core_pitch));
    const col = ui.div(c).column().wFull().gap(core_pitch - core_d);
    {
        defer col.end();
        var i: usize = 0;
        while (i < s.cores) {
            const r = ui.div(c).row().wFull().gap(core_pitch - core_d);
            defer r.end();
            const end = @min(s.cores, i + per_row);
            while (i < end) : (i += 1) {
                ui.key(c, c.print("ring-{d}", .{i}));
                ring(c, k, core_d, 22, 2.6, s.core_load[i] / 100, if (i < frugal) k.yellow else k.blue);
            }
        }
    }
    const avg = struct {
        fn f(load: []const f32) f32 {
            if (load.len == 0) return 0;
            var t: f32 = 0;
            for (load) |v| t += v;
            return t / @as(f32, @floatFromInt(load.len));
        }
    }.f;
    if (frugal > 0) {
        legend(c, k, c.print("{s} Cores", .{info.frugal_name}), avg(s.core_load[0..frugal]), k.yellow);
        legend(c, k, c.print("{s} Cores", .{info.fast_name}), avg(s.core_load[frugal..s.cores]), k.blue);
    }
}

fn legend(c: *ui.Context, k: theme.Colors, name: []const u8, v: f32, color: ui.Color) void {
    const r = ui.div(c).row().wFull().gap(8).itemsCenter().h(17);
    defer r.end();
    _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = color }, .none, null);
    ui.text(c, name, .{ .size = 12.5, .color = k.text });
    ui.spacer(c);
    ui.text(c, c.print("{d:.0}%", .{v}), .{ .size = 12.5, .mono = true, .color = k.secondary });
}

/// A ring of `n` dots `d` across, filled clockwise from the top to `f`.
fn ring(c: *ui.Context, k: theme.Colors, d: f32, n: usize, dot: f32, f: f32, color: ui.Color) void {
    const box = ui.div(c).w(d).h(d);
    defer box.end();
    ringDots(c, k, d, n, dot, f, color);
}

fn ringDots(c: *ui.Context, k: theme.Colors, d: f32, n: usize, dot: f32, f: f32, color: ui.Color) void {
    const filled: usize = @intFromFloat(@round(std.math.clamp(f, 0, 1) * @as(f32, @floatFromInt(n))));
    const r = (d - dot) / 2;
    for (0..n) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * 2 * std.math.pi;
        const x = d / 2 + r * @sin(t) - dot / 2;
        const y = d / 2 - r * @cos(t) - dot / 2;
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = dot }, .height = .{ .px = dot }, .radius = dot / 2, .background = if (i < filled) color else k.empty }, .none, null);
    }
}

/// The busiest five, by CPU.
fn processes(c: *ui.Context, a: *App, k: theme.Colors) void {
    section(c, k, "Processes", "");
    const procs = a.sampler.procs.items;
    var top: [5]?usize = @splat(null);
    for (procs, 0..) |p, i| {
        var at: ?usize = null;
        for (top, 0..) |t, j| if (t == null or procs[t.?].cpu < p.cpu) {
            at = j;
            break;
        };
        const j = at orelse continue;
        var m: usize = top.len - 1;
        while (m > j) : (m -= 1) top[m] = top[m - 1];
        top[j] = i;
    }
    const l = ui.div(c).column().wFull().gap(2);
    defer l.end();
    for (top) |t| {
        const p = procs[t orelse break];
        ui.key(c, c.print("top-{d}", .{p.pid}));
        const r = ui.div(c).row().wFull().gap(9).itemsCenter().h(24);
        defer r.end();
        const icon = ui.div(c).row().w(18).h(18).center();
        if (a.icons.get(p.bundle)) |png| {
            _ = ui.image(c, .{ .key = p.bundle, .bytes = png, .max_width = 18, .max_height = 18, .radius = 0 });
        } else ui.icon(c, "terminal", .{ .size = 11, .color = k.secondary });
        icon.end();
        ui.text(c, p.name, .{ .size = 13, .color = k.text });
        ui.spacer(c);
        ui.text(c, c.print("{d:.1}%", .{p.cpu}), .{ .size = 12.5, .mono = true, .color = k.secondary });
    }
}

/// The GPU as four dials: its load, its memory, how hot, its renderer.
fn gpu(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    section(c, k, "GPU", a.sampler.info.gpu);
    const r = ui.div(c).row().wFull().justifyBetween().px(4);
    defer r.end();
    const mem: f32 = if (sy.mem_total > 0) @floatCast(@as(f64, @floatFromInt(sy.gpu_memory)) / @as(f64, @floatFromInt(sy.mem_total)) * 100) else 0;
    dial(c, k, "GPU", c.print("{d:.1}", .{sy.gpu}), "%", sy.gpu / 100, k.red);
    dial(c, k, "Mem", c.print("{d:.0}", .{mem}), "%", mem / 100, k.green);
    const hot = if (sy.gpu_temp > 0) sy.gpu_temp else sy.soc_temp;
    if (hot > 0)
        dial(c, k, if (sy.gpu_temp > 0) "Temp" else "SoC", c.print("{d:.0}", .{hot}), "°", hot / 110, k.yellow)
    else
        dial(c, k, "Tiler", c.print("{d:.0}", .{sy.gpu_tiler}), "%", sy.gpu_tiler / 100, k.yellow);
    dial(c, k, "Render", c.print("{d:.0}", .{sy.gpu_renderer}), "%", sy.gpu_renderer / 100, k.blue);
}

fn dial(c: *ui.Context, k: theme.Colors, label: []const u8, value: []const u8, unit: []const u8, f: f32, color: ui.Color) void {
    ui.key(c, label);
    const d: f32 = 66;
    const box = ui.div(c).column().w(d).h(d).center().gap(0);
    defer box.end();
    ringDots(c, k, d, 36, 3.6, f, color);
    {
        const n = ui.div(c).row().itemsEnd().gap(1);
        defer n.end();
        ui.text(c, value, .{ .size = 15, .weight = .bold, .mono = true, .color = k.text });
        const u = ui.div(c).column().pb(2);
        defer u.end();
        ui.text(c, unit, .{ .size = 9.5, .mono = true, .color = k.secondary });
    }
    ui.text(c, label, .{ .size = 10, .color = k.secondary });
}

fn footer(c: *ui.Context, a: *App, k: theme.Colors) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    const r = ui.div(c).row().wFull().itemsCenter().gap(8);
    defer r.end();
    {
        const b = ui.div(c).row().px(14).py(6).rounded(8).bg(k.control_on).border(k.border).hover(k.hover).control();
        defer b.end();
        if (b.clicked()) a.openWindow();
        ui.text(c, "Open nanomon", .{ .size = 13, .weight = .medium, .color = k.text });
    }
    ui.spacer(c);
    ui.key(c, "gear");
    const g = ui.div(c).row().w(28).h(28).center().rounded(14).hover(k.hover).control();
    defer g.end();
    if (g.clicked()) {
        a.settings_open = !a.settings_open;
        if (a.menubar) |m| m.fit();
    }
    ui.icon(c, if (a.settings_open) "xmark" else "gearshape", .{ .size = 14, .color = if (a.settings_open) k.accent else k.secondary });
}

/// What the menu bar shows, and Quit.
fn settings(c: *ui.Context, a: *App, k: theme.Colors) void {
    {
        const r = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer r.end();
        kit.chip(c, "menubar.rectangle", k.accent, 26, false);
        ui.text(c, "In the menu bar", .{ .size = 15, .weight = .semibold, .color = k.accent });
    }
    const l = ui.div(c).column().wFull().gap(4).grow();
    {
        defer l.end();
        const it = &a.bar_items;
        var changed = false;
        changed = ui.toggle(c, "CPU", &it.cpu) or changed;
        changed = ui.toggle(c, "Memory", &it.memory) or changed;
        changed = ui.toggle(c, "Network", &it.network) or changed;
        changed = ui.toggle(c, "Temperature", &it.temperature) or changed;
        if (changed) if (a.menubar) |m| m.update();
    }
    const q = ui.div(c).row().wFull().px(12).py(7).rounded(8).bg(k.control).hover(k.hover).control();
    defer q.end();
    if (q.clicked()) if (a.nanoapp) |app| app.quit();
    ui.icon(c, "power", .{ .size = 12, .color = k.system });
    const gap = ui.div(c).w(8);
    gap.end();
    ui.text(c, "Quit nanomon", .{ .size = 13, .color = k.text });
}

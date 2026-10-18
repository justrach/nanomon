//! The pieces nanomon's pages are made of: a page's header, cards with a
//! colored chip and a title, figures, bars, the range and pause controls,
//! and the cell graph: a column of small square cells for each slice of
//! the range, filled from the bottom by each series in turn, the rest left
//! faint; the column under the pointer reads out its values. Figures are
//! set in the monospaced face, as a terminal's.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

pub const header_h = 52;

/// The page's title and what it is about; add controls, then `end`.
pub fn header(c: *ui.Context, k: theme.Colors, name: []const u8, subtitle: []const u8) ui.Div {
    const h = ui.div(c).row().wFull().h(header_h).itemsCenter().gap(8).px(20);
    {
        const t = ui.div(c).column().gap(1).clip();
        defer t.end();
        ui.text(c, name, .{ .size = 15, .weight = .bold, .color = k.text });
        ui.text(c, subtitle, .{ .size = 11, .color = k.secondary });
    }
    ui.spacer(c);
    return h;
}

pub fn card(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().wFull().gap(12).p(16).rounded(10).bg(k.card).border(k.border);
}

/// A colored square with a symbol in it, as the sidebar's and cards'.
pub fn chip(c: *ui.Context, icon: []const u8, color: ui.Color, size: f32, solid: bool) void {
    const d = ui.div(c).row().w(size).h(size).center().rounded(size * 0.28).bg(if (solid) color else color.alpha(0.16));
    defer d.end();
    ui.icon(c, icon, .{ .size = size * 0.58, .weight = .semibold, .color = if (solid) .white else color });
}

/// A card's title row: its chip and name; add more, then `end`.
pub fn title(c: *ui.Context, icon: []const u8, name: []const u8, color: ui.Color) ui.Div {
    const r = ui.div(c).row().wFull().gap(8).itemsCenter();
    chip(c, icon, color, 22, false);
    ui.text(c, name, .{ .size = 13, .weight = .semibold, .color = color });
    ui.spacer(c);
    return r;
}

pub fn legend(c: *ui.Context, k: theme.Colors, items: []const struct { []const u8, ui.Color }) void {
    for (items) |it| {
        const d = ui.div(c).row().gap(5).itemsCenter().pl(10);
        defer d.end();
        _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = it[1] }, .none, null);
        ui.text(c, it[0], .{ .size = 11, .color = k.secondary });
    }
}

/// "Now" over a large number and its unit.
pub fn big(c: *ui.Context, k: theme.Colors, label: []const u8, number: []const u8, unit: []const u8) void {
    const col = ui.div(c).column().gap(2).w(150);
    defer col.end();
    ui.text(c, label, .{ .size = 11, .color = k.secondary });
    const r = ui.div(c).row().itemsEnd().gap(2);
    defer r.end();
    ui.text(c, number, .{ .size = 32, .weight = .bold, .mono = true, .color = k.text });
    const u = ui.div(c).column().pb(6);
    defer u.end();
    ui.text(c, unit, .{ .size = 13, .weight = .medium, .mono = true, .color = k.secondary });
}

/// A figure: its label over its value, and a note under it.
pub fn stat(c: *ui.Context, k: theme.Colors, label: []const u8, value: []const u8, note: []const u8) void {
    const col = ui.div(c).column().gap(2).grow().w(0).clip();
    defer col.end();
    ui.text(c, label, .{ .size = 11, .color = k.secondary });
    ui.text(c, value, .{ .size = 13, .weight = .semibold, .mono = true, .color = k.text });
    if (note.len > 0) ui.text(c, note, .{ .size = 10.5, .color = k.tertiary });
}

/// A line of a list: the label on the left, the value on the right.
pub fn line(c: *ui.Context, k: theme.Colors, label: []const u8, value: []const u8, color: ?ui.Color) void {
    const r = ui.div(c).row().wFull().itemsCenter().h(22);
    defer r.end();
    ui.text(c, label, .{ .size = 12, .color = k.secondary });
    ui.spacer(c);
    ui.text(c, value, .{ .size = 12, .weight = .medium, .mono = true, .color = color orelse k.text });
}

/// A thin bar `fraction` full, easing to it.
pub fn bar(c: *ui.Context, k: theme.Colors, fraction: f32, color: ui.Color) void {
    const id = c.peekId(null);
    const f = c.animate(id, 7, std.math.clamp(fraction, 0, 1), 8);
    const track = ui.div(c).row().grow().w(0).h(6).rounded(3).bg(k.well).clip();
    defer track.end();
    if (f > 0.004) _ = c.leaf(.{ .grow = f, .height = .{ .px = 6 }, .radius = 3, .background = color }, .none, null);
    if (f < 1) _ = c.leaf(.{ .grow = 1 - f }, .none, null);
}

/// A segmented control; the index clicked, if one was.
pub fn segmented(c: *ui.Context, k: theme.Colors, items: []const []const u8, on: usize) ?usize {
    const seg = ui.div(c).row().p(2).gap(2).rounded(8).bg(k.control);
    defer seg.end();
    var picked: ?usize = null;
    for (items, 0..) |name, i| {
        ui.key(c, name);
        var d = ui.div(c).row().px(10).py(3).rounded(6).control();
        d = if (i == on) d.bg(k.control_on).shadow(.{ .color = .{ .a = 0.14 }, .blur = 2, .y = 0.5 }) else d.hover(k.hover);
        defer d.end();
        if (d.clicked()) picked = i;
        ui.text(c, name, .{ .size = 11.5, .weight = if (i == on) .semibold else .regular, .color = if (i == on) k.text else k.secondary });
    }
    return picked;
}

/// The graphs' range (1m, 5m, 15m, 1h), and pause.
pub fn ranges(c: *ui.Context, a: *App, k: theme.Colors) void {
    const all = [_]app_mod.Range{ .m1, .m5, .m15, .h1 };
    var names: [all.len][]const u8 = undefined;
    for (all, 0..) |r, i| names[i] = r.title();
    if (segmented(c, k, &names, @intFromEnum(a.range))) |i| a.range = all[i];
    ui.key(c, "pause");
    const d = ui.div(c).row().w(30).h(26).center().rounded(8).bg(k.control).hover(k.hover).control();
    defer d.end();
    if (d.clicked()) a.paused = !a.paused;
    ui.icon(c, if (a.paused) "play.fill" else "pause.fill", .{ .size = 10, .color = if (a.paused) k.accent else k.secondary });
}

pub const Series = struct { values: []const f32, color: ui.Color };

pub const Hover = app_mod.Hover;

const dot: f32 = 5;
const pitch: f32 = 7.0;
const inset: f32 = 10;

/// The series stacked in columns of dots across `a.range`, scaled to
/// `scale` (null: to the busiest column); `h` points high, with the
/// range's marks under it when `axis`. The column under the pointer goes
/// to `graph`'s hover (read by the card's title, drawn before the graph:
/// a change draws another frame so the title catches up).
pub fn dots(c: *ui.Context, k: theme.Colors, a: *App, series: []const Series, scale: ?f32, h: f32, axis: bool, graph: ?app_mod.Graph) void {
    const col = ui.div(c).column().wFull().gap(6);
    defer col.end();
    const box = ui.div(c).wFull().h(h).rounded(8).bg(k.well).border(k.border).p(inset);
    const it = box.interaction();
    const rect = it.rect orelse ui.Rect{ .x = 0, .y = 0, .w = 600, .h = h };
    const inner_w = @max(0, rect.w - 2 * inset);
    const cols: usize = @intFromFloat(@max(1, @floor((inner_w + pitch - dot) / pitch)));
    const rows: usize = @intFromFloat(@max(1, @floor((h - 2 * inset + pitch - dot) / pitch)));
    const x0 = (inner_w - (@as(f32, @floatFromInt(cols)) * pitch - (pitch - dot))) / 2;
    const n = a.range.samples();
    const len = if (series.len > 0) series[0].values.len else 0;
    const start: i64 = @as(i64, @intCast(len)) - @as(i64, @intCast(n));
    // Each column's values: the mean of its slice of the range.
    var vals: [4][512]f32 = undefined;
    var has: [512]bool = undefined;
    const ncols = @min(cols, 512);
    var most: f32 = 0;
    for (0..ncols) |i| {
        var lo = start + @as(i64, @intCast(i * n / cols));
        var hi = start + @as(i64, @intCast((i + 1) * n / cols));
        if (hi <= lo) {
            lo = start + @as(i64, @intFromFloat(@floor((@as(f32, @floatFromInt(i)) + 0.5) * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(cols)))));
            hi = lo + 1;
        }
        lo = @max(lo, 0);
        hi = @min(hi, @as(i64, @intCast(len)));
        has[i] = hi > lo;
        var sum: f32 = 0;
        for (series[0..@min(series.len, 4)], 0..) |s, si| {
            var v: f32 = 0;
            if (has[i]) {
                for (s.values[@intCast(lo)..@intCast(hi)]) |x| v += x;
                v /= @floatFromInt(hi - lo);
            }
            vals[si][i] = v;
            sum += v;
        }
        most = @max(most, sum);
    }
    const top = scale orelse @max(most * 1.15, 1e-6);
    // The column under the pointer.
    var hover: ?Hover = null;
    var hot_col: ?usize = null;
    if (it.hovered) {
        c.wants_moves = true;
        const mx = c.input.mouse.x - rect.x - inset - x0;
        if (mx >= 0) {
            const ci: usize = @intFromFloat(@floor(mx / pitch));
            if (ci < ncols and has[ci]) {
                hot_col = ci;
                var hv: Hover = .{ .ago = a.range.seconds() * (1 - (@as(f32, @floatFromInt(ci)) + 0.5) / @as(f32, @floatFromInt(cols))) };
                for (0..@min(series.len, 4)) |si| hv.values[si] = vals[si][ci];
                hover = hv;
            }
        }
    }
    const rf: f32 = @floatFromInt(rows);
    for (0..ncols) |i| {
        // How many dots each series fills, stacked.
        var levels: [4]usize = @splat(0);
        var cum: f32 = 0;
        for (0..@min(series.len, 4)) |si| {
            cum += vals[si][i];
            levels[si] = @intFromFloat(@min(rf, @round(cum / top * rf)));
        }
        const last = @min(series.len, 4) -| 1;
        if (has[i] and cum > 0 and levels[last] == 0) levels[last] = 1;
        const dim = hot_col != null and hot_col.? != i;
        const x = x0 + @as(f32, @floatFromInt(i)) * pitch;
        for (0..rows) |r| {
            var color = k.empty;
            for (0..@min(series.len, 4)) |si| if (has[i] and r < levels[si]) {
                color = series[si].color;
                break;
            };
            if (dim and color.a > 0) color = color.alpha(0.55);
            const y = (rf - 1 - @as(f32, @floatFromInt(r))) * pitch + (h - 2 * inset - (rf * pitch - (pitch - dot))) / 2;
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = dot }, .height = .{ .px = dot }, .radius = 1.2, .background = color }, .none, null);
        }
    }
    box.end();
    if (axis) marks(c, k, a.range);
    if (graph) |g| {
        const was = a.hovers.get(g);
        const same = if (was) |w| (if (hover) |now| std.meta.eql(w, now) else false) else hover == null;
        if (!same) c.animationFrame();
        a.hovers.set(g, hover);
    }
}

/// The hover of `graph`, read out: "−42s  User 54% · System 46%".
pub fn readout(c: *ui.Context, k: theme.Colors, a: *App, graph: app_mod.Graph, names: []const []const u8, units: fn (*ui.Context, f32) []const u8) bool {
    const hv = a.hovers.get(graph) orelse return false;
    var text: std.ArrayList(u8) = .empty;
    const gpa = c.alloc();
    text.appendSlice(gpa, ago(c, hv.ago)) catch {};
    text.appendSlice(gpa, "   ") catch {};
    for (names, 0..) |n, i| {
        if (i > 0) text.appendSlice(gpa, " · ") catch {};
        text.appendSlice(gpa, n) catch {};
        text.append(gpa, ' ') catch {};
        text.appendSlice(gpa, units(c, hv.values[i])) catch {};
    }
    ui.text(c, text.items, .{ .size = 11, .weight = .medium, .mono = true, .color = k.text });
    return true;
}

pub fn percent(c: *ui.Context, v: f32) []const u8 {
    return c.print("{d:.0}%", .{v});
}

pub fn perSecond(c: *ui.Context, v: f32) []const u8 {
    var b: [32]u8 = undefined;
    return c.print("{s}", .{@import("model.zig").rate(&b, v)});
}

/// The range's marks under a graph: "−1m … now".
fn marks(c: *ui.Context, k: theme.Colors, r: app_mod.Range) void {
    const labels: []const []const u8 = switch (r) {
        .m1 => &.{ "−1m", "−45s", "−30s", "−15s", "now" },
        .m5 => &.{ "−5m", "−4m", "−3m", "−2m", "−1m", "now" },
        .m15 => &.{ "−15m", "−10m", "−5m", "now" },
        .h1 => &.{ "−1h", "−45m", "−30m", "−15m", "now" },
    };
    const row = ui.div(c).row().wFull().justifyBetween().px(inset);
    defer row.end();
    for (labels) |l| ui.text(c, l, .{ .size = 10, .mono = true, .color = k.tertiary });
}

/// "−42s", "−3m 10s".
pub fn ago(c: *ui.Context, s: f32) []const u8 {
    const t: u32 = @intFromFloat(@max(0, s));
    if (t < 60) return c.print("−{d}s", .{t});
    if (t % 60 == 0) return c.print("−{d}m", .{t / 60});
    return c.print("−{d}m {d}s", .{ t / 60, t % 60 });
}

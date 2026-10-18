//! The video's frames, as one nanoui view: a title, code beside the
//! counter it makes, nanomon itself in a window, the benchmarks, binary
//! sizes, and the end. Every picture in it is drawn by nanoui; the pointer is a dot the
//! script (video.zig) moves and clicks with.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const view = @import("view.zig");
const App = @import("app.zig").App;

pub const width = 1280;
pub const height = 720;

/// Where nanomon's window sits.
pub const win = struct {
    pub const x = 80;
    pub const y = 100;
    pub const w = 1120;
    pub const h = 600;
};

/// When each scene starts, in seconds; the last ends the video.
pub const at = struct {
    pub const code = 3.0;
    pub const mon = 8.4;
    pub const bench = 20.0;
    pub const size = 23.6;
    pub const end = 27.0;
    pub const done = 30.0;
};

pub const Director = struct {
    a: *App,
    /// The video's clock, set by the script.
    now: f32 = 0,
    count: i64 = 0,
    cursor: [2]f32 = .{ -100, -100 },
    cursor_alpha: f32 = 0,
    /// When the pointer last clicked.
    pulse: f32 = -10,
    /// Codegraff Dark around the windows, else Codegraff Light.
    dark: bool = false,

    pub fn view(d: *Director, c: *ui.Context) void {
        c.theme = theme.ui(false);
        // Around the windows: the page, and cards a step from it (in light,
        // a deeper cream, so the windows' own cream stands out).
        var k = theme.colors(d.dark);
        if (!d.dark) {
            k.card = k.page;
            k.page = k.well;
        }
        const root = ui.div(c).sizeFull().bg(k.page);
        defer root.end();
        const t = d.now;
        if (t < at.code) {
            scene(c, t, 0, at.code, title, d, k);
        } else if (t < at.mon) {
            scene(c, t, at.code, at.mon, code, d, k);
        } else if (t < at.bench) {
            scene(c, t, at.mon, at.bench, mon, d, k);
        } else if (t < at.size) {
            scene(c, t, at.bench, at.size, bench, d, k);
        } else if (t < at.end) {
            scene(c, t, at.size, at.end, sizes, d, k);
        } else scene(c, t, at.end, at.done + 1, end, d, k);
        pointer(c, d, k);
    }
};

const Scene = fn (*ui.Context, *Director, theme.Colors, f32) void;

/// A scene fading and rising in, and fading out at its end.
fn scene(c: *ui.Context, t: f32, start: f32, stop: f32, comptime draw: Scene, d: *Director, k: theme.Colors) void {
    const in = ease(clamp01((t - start) / 0.45));
    const out = ease(clamp01((stop - t) / 0.35));
    const s = ui.div(c).absolute().sizeFull().opacity(in * out).offset(0, (1 - in) * 14);
    defer s.end();
    draw(c, d, k, t - start);
}

pub fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

/// Ease out, cubic.
pub fn ease(v: f32) f32 {
    const u = 1 - v;
    return 1 - u * u * u;
}

/// How far in a part is that starts at `from` and takes `len`.
fn part(t: f32, from: f32, len: f32) f32 {
    return ease(clamp01((t - from) / len));
}

fn pointer(c: *ui.Context, d: *Director, k: theme.Colors) void {
    if (d.cursor_alpha <= 0.01) return;
    const x = d.cursor[0];
    const y = d.cursor[1];
    const since = d.now - d.pulse;
    if (since >= 0 and since < 0.5) {
        const p = since / 0.5;
        const r = 10 + 22 * ease(p);
        const ring = ui.div(c).absolute().offset(x - r, y - r).w(r * 2).h(r * 2).rounded(r).border(k.accent).borderW(2.5).opacity((1 - p) * d.cursor_alpha);
        ring.end();
    }
    const down = since >= 0 and since < 0.12;
    const r: f32 = if (down) 8 else 10;
    const dot = ui.div(c).absolute().offset(x - r, y - r).w(r * 2).h(r * 2).rounded(r).bg(.{ .r = 1, .g = 1, .b = 1, .a = 0.92 }).border(.{ .a = 0.55 }).borderW(1.5).shadow(.{ .color = .{ .a = 0.35 }, .blur = 10, .y = 3 }).opacity(d.cursor_alpha);
    dot.end();
}

fn title(c: *ui.Context, _: *Director, k: theme.Colors, t: f32) void {
    const col = ui.div(c).column().sizeFull().center().gap(18);
    defer col.end();
    {
        const r = ui.div(c).row().gap(10).itemsCenter().opacity(part(t, 0.1, 0.5));
        defer r.end();
        const dot = ui.div(c).w(10).h(10).rounded(5).bg(k.accent);
        dot.end();
        ui.text(c, "A new UI framework in Zig", .{ .size = 18, .weight = .medium, .color = k.secondary });
    }
    {
        const n = ui.div(c).opacity(part(t, 0.25, 0.6)).offset(0, (1 - part(t, 0.25, 0.8)) * 20);
        defer n.end();
        ui.text(c, "nanoui", .{ .size = 132, .weight = .bold, .color = k.text });
    }
    typed(c, "Desktop apps, drawn on the GPU.", t - 0.9, 34, .{ .size = 30, .color = k.secondary });
    const chips = [_][]const u8{ "Metal + CoreText", "Linux · Windows", "~0.7 MB apps", "0 dependencies" };
    const r = ui.div(c).row().gap(10).pt(16);
    defer r.end();
    for (chips, 0..) |s, i| {
        const f: f32 = @floatFromInt(i);
        const chip = ui.div(c).px(16).py(8).roundedFull().border(k.border).bg(k.card).opacity(part(t, 1.7 + f * 0.15, 0.4));
        defer chip.end();
        ui.text(c, s, .{ .size = 15, .weight = .medium, .color = k.text });
    }
}

/// Text appearing a letter at a time, at `rate` letters a second.
fn typed(c: *ui.Context, s: []const u8, t: f32, rate: f32, style: ui.TextStyle) void {
    const n: usize = @intFromFloat(std.math.clamp(t * rate, 0, @as(f32, @floatFromInt(s.len))));
    // Room for the whole line from the start, so nothing moves.
    const box = ui.div(c).row();
    defer box.end();
    ui.text(c, s[0..n], style);
    var hidden = style;
    hidden.color = .{ .a = 0 };
    ui.text(c, s[n..], hidden);
}

const source = [_][]const u8{
    "const Counter = struct {",
    "    n: i64 = 0,",
    "",
    "    fn view(s: *Counter, c: *ui.Context) void {",
    "        const col = ui.div(c).column().center().gap(16);",
    "        defer col.end();",
    "        ui.textf(c, .{ .size = 72 }, \"{d}\", .{s.n});",
    "        if (ui.button(c, \"Increment\", .{}).clicked)",
    "            s.n += 1;",
    "    }",
    "};",
};

fn code(c: *ui.Context, d: *Director, k: theme.Colors, t: f32) void {
    const col = ui.div(c).column().sizeFull().center().gap(30);
    defer col.end();
    {
        const h = ui.div(c).column().itemsCenter().gap(8);
        defer h.end();
        ui.text(c, "Write a view as a function of your state", .{ .size = 34, .weight = .bold, .color = k.text });
        ui.text(c, "Immediate mode, in plain Zig. No HTML, no JavaScript, no webview.", .{ .size = 17, .color = k.secondary });
    }
    const r = ui.div(c).row().gap(36).itemsCenter();
    defer r.end();
    {
        const card = ui.div(c).column().w(640).gap(6).p(24).rounded(14).bg(k.card).border(k.border);
        defer card.end();
        {
            const top = ui.div(c).row().gap(7).itemsCenter().pb(10);
            defer top.end();
            lights(c);
            ui.text(c, "counter.zig", .{ .size = 13, .mono = true, .color = k.tertiary });
        }
        var left: f32 = @max(0, t - 0.4) * 190;
        for (source) |line| {
            const len: f32 = @floatFromInt(line.len);
            const shown: usize = @intFromFloat(std.math.clamp(left, 0, len));
            left -= len + 4;
            zigLine(c, k, line, shown);
        }
    }
    {
        const w = ui.div(c).column().w(360).h(320).rounded(14).bg(theme.colors(false).page).border(k.border).shadowLg().clip().opacity(part(t, 1.2, 0.5));
        defer w.end();
        {
            const top = ui.div(c).row().wFull().h(38).px(14).gap(7).itemsCenter();
            defer top.end();
            lights(c);
            ui.spacer(c);
            ui.text(c, "Counter", .{ .size = 13, .weight = .semibold, .color = theme.colors(false).secondary });
            ui.spacer(c);
            const pad = ui.div(c).w(50);
            pad.end();
        }
        const body = ui.div(c).column().wFull().grow().center().gap(16);
        defer body.end();
        ui.textf(c, .{ .size = 72, .weight = .bold, .color = theme.colors(false).text }, "{d}", .{d.count});
        if (ui.button(c, "Increment", .{ .variant = .primary, .size = 15 }).clicked) d.count += 1;
    }
}

/// The window buttons, as macOS draws them.
pub fn lights(c: *ui.Context) void {
    const r = ui.div(c).row().gap(8);
    defer r.end();
    for ([_]u24{ 0xff5f57, 0xfebc2e, 0x28c840 }) |hex| {
        const l = ui.div(c).w(12).h(12).rounded(6).bg(.hex(hex));
        l.end();
    }
}

const keywords = [_][]const u8{ "const", "struct", "fn", "void", "defer", "if", "pub", "return" };

/// A line of Zig, its first `shown` bytes, colored as an editor would.
fn zigLine(c: *ui.Context, k: theme.Colors, line: []const u8, shown: usize) void {
    var spans: std.ArrayList(ui.Span) = .empty;
    const gpa = c.alloc();
    var i: usize = 0;
    while (i < shown) {
        const ch = line[i];
        if (ch == '"') {
            var j = i + 1;
            while (j < line.len and line[j] != '"') j += 1;
            spans.append(gpa, .{ .start = @intCast(i), .end = @intCast(@min(j + 1, shown)), .color = k.green }) catch {};
            i = j + 1;
        } else if (std.ascii.isDigit(ch)) {
            var j = i;
            while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
            spans.append(gpa, .{ .start = @intCast(i), .end = @intCast(@min(j, shown)), .color = k.purple }) catch {};
            i = j;
        } else if (std.ascii.isAlphabetic(ch) or ch == '_') {
            var j = i;
            while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '_')) j += 1;
            const word = line[i..j];
            const color: ?ui.Color = for (keywords) |kw| {
                if (std.mem.eql(u8, kw, word)) break k.accent;
            } else if (j < line.len and line[j] == '(') k.blue else if (std.ascii.isUpper(word[0]) or std.mem.eql(u8, word, "i64")) k.teal else null;
            if (color) |col| spans.append(gpa, .{ .start = @intCast(i), .end = @intCast(@min(j, shown)), .color = col }) catch {};
            i = j;
        } else i += 1;
    }
    const style: ui.TextStyle = .{ .size = 16, .mono = true, .color = k.text };
    // A blank line keeps its height.
    ui.richText(c, if (shown == 0) " " else line[0..shown], spans.items, style);
}

fn mon(c: *ui.Context, d: *Director, k: theme.Colors, t: f32) void {
    {
        const h = ui.div(c).absolute().wFull().column().itemsCenter().pt(22).gap(6);
        defer h.end();
        const r = ui.div(c).row().gap(10).itemsCenter();
        ui.text(c, "nanomon", .{ .size = 24, .weight = .bold, .color = k.text });
        ui.text(c, "an activity monitor on nanoui, a 600 KB download", .{ .size = 20, .color = k.secondary });
        r.end();
        const lines = [_]struct { f32, []const u8 }{
            .{ 0, "Live graphs of CPU, memory, GPU, disk and network" },
            .{ 2.4, "Mark several processes, quit them together" },
            .{ 5.2, "Or ask graff what to quit" },
        };
        var shown: usize = 0;
        for (lines, 0..) |l, i| if (t >= l[0]) {
            shown = i;
        };
        const since = t - lines[shown][0];
        const s = ui.div(c).opacity(part(since, 0, 0.4)).offset(0, (1 - part(since, 0, 0.4)) * 6);
        defer s.end();
        ui.text(c, lines[shown][1], .{ .size = 15, .color = k.accent });
    }
    const w = ui.div(c).absolute().offset(win.x, win.y).w(win.w).h(win.h).rounded(12).clip().border(.{ .a = if (d.dark) 0.5 else 0.12 }).shadow(.{ .color = .{ .a = if (d.dark) 0.5 else 0.18 }, .blur = 40, .y = 18 });
    defer w.end();
    view.view(d.a, c);
    const l = ui.div(c).absolute().offset(18, 20);
    defer l.end();
    lights(c);
}

/// CPU time per frame in ms, medians (hillclimb's scenes): nanoui, mygo,
/// and GPUI 0.2.2 drawing the same scenes with its own renderer and
/// CoreText, all headless on one Mac.
const runs = [_]struct { []const u8, []const u8, [3]f32 }{
    .{ "boxes", "600 shadowed boxes", .{ 0.060, 0.305, 1.997 } },
    .{ "text", "300 changing labels", .{ 0.124, 0.417, 8.449 } },
    .{ "scroll", "a 1000-row column", .{ 0.349, 2.314, 8.241 } },
    .{ "list", "100 000 virtual rows", .{ 0.067, 0.367, 0.753 } },
    .{ "dashboard", "12 cards", .{ 0.017, 0.081, 0.821 } },
};

fn bench(c: *ui.Context, _: *Director, k: theme.Colors, t: f32) void {
    const col = ui.div(c).column().sizeFull().px(130).py(48).gap(18).justifyCenter();
    defer col.end();
    {
        const h = ui.div(c).column().gap(8);
        defer h.end();
        ui.text(c, "Frames in a fraction of a millisecond", .{ .size = 38, .weight = .bold, .color = k.text });
        ui.text(c, "CPU time per frame, median, the same scenes headless on an Apple M3 Ultra. Lower is better.", .{ .size = 16, .color = k.secondary });
    }
    const colors = [3]ui.Color{ k.accent, k.tertiary.alpha(0.7), k.blue.alpha(0.55) };
    {
        const lg = ui.div(c).row().gap(18);
        defer lg.end();
        for ([_][]const u8{ "nanoui", "mygo", "GPUI" }, colors) |name, color| swatch(c, k, color, name);
    }
    const full: f32 = 600;
    for (runs, 0..) |run, i| {
        const f: f32 = @floatFromInt(i);
        const grow = part(t, 0.3 + f * 0.1, 0.8);
        const r = ui.div(c).row().gap(20).itemsCenter();
        defer r.end();
        {
            const name = ui.div(c).column().w(200).gap(1);
            defer name.end();
            ui.text(c, run[0], .{ .size = 16, .weight = .semibold, .color = k.text });
            ui.text(c, run[1], .{ .size = 12, .color = k.tertiary });
        }
        // Each row to its own scale: the slowest fills it.
        const max = @max(run[2][0], @max(run[2][1], run[2][2]));
        const bars = ui.div(c).column().gap(3);
        defer bars.end();
        for (run[2], colors, 0..) |ms, color, j| bar(c, k, color, ms, @max(3, full * ms / max * grow), grow, j == 0);
    }
    const stats = [_][]const u8{ "Each row to its own scale", "GPUI 0.2.2, with its own Metal renderer", "No CPU at all when idle" };
    const s = ui.div(c).row().gap(12).pt(8);
    defer s.end();
    for (stats, 0..) |st, i| {
        const f: f32 = @floatFromInt(i);
        const chip = ui.div(c).px(14).py(8).roundedFull().bg(k.card).border(k.border).opacity(part(t, 1.6 + f * 0.15, 0.4));
        defer chip.end();
        ui.text(c, st, .{ .size = 14, .weight = .medium, .color = k.text });
    }
}

fn swatch(c: *ui.Context, k: theme.Colors, color: ui.Color, name: []const u8) void {
    const r = ui.div(c).row().gap(8).itemsCenter();
    defer r.end();
    const sw = ui.div(c).w(12).h(12).rounded(3).bg(color);
    sw.end();
    ui.text(c, name, .{ .size = 14, .weight = .medium, .color = k.secondary });
}

fn bar(c: *ui.Context, k: theme.Colors, color: ui.Color, ms: f32, w: f32, shown: f32, bold: bool) void {
    const r = ui.div(c).row().gap(10).itemsCenter();
    defer r.end();
    const b = ui.div(c).w(w).h(11).rounded(3).bg(color);
    b.end();
    const label = ui.div(c).opacity(shown);
    defer label.end();
    ui.text(c, c.print("{d:.3} ms", .{ms * shown}), .{ .size = 11, .mono = true, .weight = if (bold) .bold else .regular, .color = if (bold) k.text else k.tertiary });
}

/// Binary sizes in MB: the same app on nanoui and on mygo (hillclimb's
/// windowed app), nanoui's two apps whole, then Electron's runtime alone
/// (the smallest Electron Framework among the apps on the Mac it was
/// measured on), which rescales the rest to slivers.
const binaries = [_]struct { []const u8, []const u8, f32, bool }{
    .{ "nanoui", "the benchmark app", 0.707, true },
    .{ "mygo", "the same app", 11.77, false },
    .{ "nanomon", "this activity monitor, whole", 1.09, true },
    .{ "nanoterm", "a terminal with agents, whole", 1.82, true },
    .{ "Electron", "its runtime alone, before any app", 224, false },
};

fn sizes(c: *ui.Context, _: *Director, k: theme.Colors, t: f32) void {
    const col = ui.div(c).column().sizeFull().px(130).py(64).gap(22).justifyCenter();
    defer col.end();
    // Electron comes in at 1.5 s, and the scale grows to hold it.
    const big = part(t, 1.5, 0.8);
    {
        const h = ui.div(c).column().gap(8);
        defer h.end();
        ui.text(c, "Apps in a megabyte or two", .{ .size = 38, .weight = .bold, .color = k.text });
        ui.text(c, "Release binaries for macOS, Apple silicon.", .{ .size = 16, .color = k.secondary });
    }
    const max = 12.5 + (224 - 12.5) * big;
    const full: f32 = 640;
    for (binaries, 0..) |b, i| {
        const f: f32 = @floatFromInt(i);
        const last = i == binaries.len - 1;
        const shown = if (last) big else part(t, 0.3 + f * 0.12, 0.6);
        const r = ui.div(c).row().gap(20).itemsCenter().opacity(if (last) big else 1);
        defer r.end();
        {
            const name = ui.div(c).column().w(250).gap(2);
            defer name.end();
            ui.text(c, b[0], .{ .size = 18, .weight = .semibold, .color = if (b[3]) k.text else k.secondary });
            ui.text(c, b[1], .{ .size = 13, .color = k.tertiary });
        }
        const w = @max(3, full * b[2] / max * shown);
        const row = ui.div(c).row().gap(10).itemsCenter();
        defer row.end();
        const bar_ = ui.div(c).w(w).h(18).rounded(4).bg(if (b[3]) k.accent else k.tertiary.alpha(0.6));
        bar_.end();
        const label = if (b[2] < 10) c.print("{d:.2} MB", .{b[2]}) else if (b[2] < 100) c.print("{d:.1} MB", .{b[2]}) else c.print("{d:.0} MB", .{b[2]});
        ui.text(c, label, .{ .size = 14, .mono = true, .weight = if (b[3]) .bold else .regular, .color = if (b[3]) k.text else k.tertiary });
    }
    const note = ui.div(c).pt(6).opacity(part(t, 2.0, 0.5));
    defer note.end();
    ui.text(c, "No runtime to ship and no bundled browser: your code, nanoui, and the system's own frameworks.", .{ .size = 15, .color = k.accent });
}

fn end(c: *ui.Context, _: *Director, k: theme.Colors, t: f32) void {
    const col = ui.div(c).column().sizeFull().center().gap(18);
    defer col.end();
    ui.text(c, "nanoui", .{ .size = 104, .weight = .bold, .color = k.text });
    {
        const s = ui.div(c).opacity(part(t, 0.3, 0.5));
        defer s.end();
        ui.text(c, "Desktop apps in Zig, with native UI drawn on the GPU.", .{ .size = 24, .color = k.secondary });
    }
    {
        const link = ui.div(c).row().gap(10).itemsCenter().px(22).py(12).roundedFull().bg(k.accent).opacity(part(t, 0.7, 0.5));
        defer link.end();
        ui.text(c, "github.com/justrach/nanoui", .{ .size = 20, .mono = true, .weight = .semibold, .color = k.on_picked });
    }
    {
        const s = ui.div(c).column().itemsCenter().gap(6).pt(26).opacity(part(t, 1.2, 0.5));
        defer s.end();
        ui.text(c, "nanoterm and nanomon are built on it. MIT licensed.", .{ .size = 16, .color = k.secondary });
        ui.text(c, "Every frame of this video was drawn by nanoui.", .{ .size = 14, .color = k.tertiary });
    }
}

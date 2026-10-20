//! nanomon in the menu bar (macOS): the machine at a glance beside the
//! clock (CPU, memory, the network's rates, how hot the chip runs), drawn
//! by nanoui offscreen as a template image so it takes the menu bar's
//! color, and a click opens the panel under it (view_popover.zig). It
//! samples on its own while the window is closed: nanomon lives on in the
//! menu bar until it's quit.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const App = @import("app.zig").App;

pub const supported = builtin.os.tag == .macos;

extern "c" fn CACurrentMediaTime() f64;

/// The seconds clock every view and the menu bar sample by.
pub fn clock() f64 {
    return if (comptime supported) CACurrentMediaTime() else 0;
}

/// What the menu bar shows.
pub const Items = struct { cpu: bool = true, memory: bool = true, network: bool = true, temperature: bool = true };

/// The readout's size in points: drawn this wide, then cut to what's drawn.
pub const readout_w = 300;
pub const readout_h = 22;

pub const MenuBar = struct {
    a: *App,
    app: *nanoui.App,
    tray: ?*nanoui.Tray = null,
    popover: ?*nanoui.Window = null,
    /// Draws the readout offscreen.
    tester: ?*ui.Tester = null,
    /// What the readout said last (it's drawn again only when that changes).
    said: u64 = 0,

    pub fn deinit(m: *MenuBar) void {
        if (m.tester) |t| {
            t.deinit();
            m.a.sampler.gpa.destroy(t);
        }
    }

    /// Puts nanomon in the menu bar and keeps it sampling.
    pub fn start(m: *MenuBar) void {
        if (comptime !supported) return;
        m.tray = m.app.newTray(.{ .tooltip = "nanomon", .on_click = .{ .ctx = m, .func = clicked } }) catch return;
        m.a.menubar = m;
        m.update();
        tick(m);
    }

    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const m: *MenuBar = @ptrCast(@alignCast(ctx));
        const next = m.a.tick(clock());
        m.update();
        if (m.popover) |p| if (p.isVisible()) p.redraw();
        if (m.a.window) |w| w.redraw();
        nanoui.App.after(@intFromFloat(@max(250, @ceil(next * 1000))), m, tick);
    }

    /// Draws the readout again if what it says changed.
    pub fn update(m: *MenuBar) void {
        const tray = m.tray orelse return;
        const gpa = m.a.sampler.gpa;
        var buf: [160]u8 = undefined;
        const said = std.hash.Wyhash.hash(0, describe(m.a, &buf));
        if (said == m.said) return;
        m.said = said;
        if (m.tester == null) {
            const t = gpa.create(ui.Tester) catch return;
            var th = theme.ui(true);
            th.background = .{};
            t.init(gpa, .init(m.a, readout), .{ .width = readout_w, .height = readout_h, .scale = 2, .theme = th }) catch {
                gpa.destroy(t);
                return;
            };
            m.tester = t;
        }
        const t = m.tester.?;
        t.frame();
        const px = t.render(gpa) catch return;
        defer px.deinit(gpa);
        const w = template(px.bytes, px.width, px.height);
        if (w == 0) return tray.setTitle("nanomon");
        tray.setTitle("");
        // Rows of the cut width, in place.
        var row: usize = 1;
        while (row < px.height) : (row += 1) std.mem.copyForwards(u8, px.bytes[row * w * 4 ..][0 .. w * 4], px.bytes[row * px.width * 4 ..][0 .. w * 4]);
        tray.setImage(px.bytes[0 .. w * px.height * 4], w, px.height, 2, true);
    }

    fn clicked(ctx: *anyopaque, _: *nanoui.Tray) void {
        const m: *MenuBar = @ptrCast(@alignCast(ctx));
        m.toggle();
    }

    /// Opens the panel under the readout, or closes it.
    pub fn toggle(m: *MenuBar) void {
        if (m.popover) |p| {
            if (p.isVisible()) return p.hide();
            if (p.justHidden()) return;
        } else {
            m.popover = m.app.newWindow(.{
                .title = "nanomon",
                .width = popover_w,
                .height = m.a.popoverHeight(),
                .resizable = false,
                .title_bar = .popover,
                .visible = false,
                .theme = theme.ui(nanoui.isDark()),
                .content = .{ .view = .init(m.a, @import("view_popover.zig").view) },
            }) catch return;
        }
        m.a.settings_open = false;
        m.fit();
        m.popover.?.show();
        m.popover.?.redraw();
    }

    /// Sizes the panel to what it shows, its top right under the readout.
    pub fn fit(m: *MenuBar) void {
        const p = m.popover orelse return;
        const tray = m.tray orelse return;
        const at = tray.anchor();
        p.setSize(popover_w, m.a.popoverHeight());
        p.setPosition(@max(8, at.x + at.width - popover_w), at.y + at.height + 5);
    }

    pub fn hidePopover(m: *MenuBar) void {
        if (m.popover) |p| p.hide();
    }
};

pub const popover_w = 340;

/// What the readout says, as text: it's drawn again when this changes.
fn describe(a: *App, buf: []u8) []const u8 {
    const sy = a.sampler.system;
    const it = a.bar_items;
    var r1: [24]u8 = undefined;
    var r2: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "{}{}{}{} {d:.0} {d:.0} {s} {s} {d:.0}", .{
        it.cpu,                    it.memory,                 it.network,                  it.temperature,
        sy.cpuBusy(),              memPercent(sy),            model.rate(&r1, sy.net_out_sec), model.rate(&r2, sy.net_in_sec),
        sy.cpu_temp,
    }) catch "";
}

pub fn memPercent(sy: model.System) f32 {
    if (sy.mem_total == 0) return 0;
    return @floatCast(@as(f64, @floatFromInt(sy.memUsed())) / @as(f64, @floatFromInt(sy.mem_total)) * 100);
}

/// Turns white-on-black pixels into a template image's (black, its
/// coverage as alpha), in place; returns the width drawn, plus a margin.
pub fn template(bytes: []u8, width: usize, height: usize) usize {
    var right: usize = 0;
    for (0..height) |y| for (0..width) |x| {
        const p = bytes[(y * width + x) * 4 ..][0..4];
        const cov = @max(p[0], @max(p[1], p[2]));
        p[0] = 0;
        p[1] = 0;
        p[2] = 0;
        p[3] = cov;
        if (cov > 8) right = @max(right, x + 1);
    };
    return if (right == 0) 0 else @min(width, right + 4);
}

const white: ui.Color = .{ .r = 1, .g = 1, .b = 1 };
const faint: ui.Color = .{ .r = 0.32, .g = 0.32, .b = 0.32 };

/// The readout: white on black (coverage), as `template` wants it.
pub fn readout(a: *App, c: *ui.Context) void {
    const sy = a.sampler.system;
    const it = a.bar_items;
    const r = ui.div(c).row().h(readout_h).gap(11).itemsCenter().pl(2);
    defer r.end();
    var b: [24]u8 = undefined;
    if (it.cpu) {
        const g = ui.div(c).row().gap(4).itemsCenter();
        defer g.end();
        meter(c, sy.cpuBusy() / 100);
        pair(c, "CPU", c.print("{d:.0}%", .{sy.cpuBusy()}));
    }
    if (it.memory) {
        const g = ui.div(c).row().gap(4).itemsCenter();
        defer g.end();
        cells(c, memPercent(sy) / 100);
        pair(c, "MEM", c.print("{d:.0}%", .{memPercent(sy)}));
    }
    if (it.network) {
        const g = ui.div(c).column().gap(0);
        defer g.end();
        ui.text(c, c.print("↑ {s}", .{model.rate(&b, sy.net_out_sec)}), .{ .size = 9, .weight = .semibold, .mono = true, .color = white });
        ui.text(c, c.print("↓ {s}", .{model.rate(&b, sy.net_in_sec)}), .{ .size = 9, .weight = .semibold, .mono = true, .color = white });
    }
    if (it.temperature and sy.cpu_temp > 0) pair(c, "TEMP", c.print("{d:.0}°", .{sy.cpu_temp}));
}

/// A small label over a figure.
fn pair(c: *ui.Context, label: []const u8, value: []const u8) void {
    const g = ui.div(c).column().gap(0);
    defer g.end();
    ui.text(c, label, .{ .size = 7.5, .weight = .bold, .color = white });
    ui.text(c, value, .{ .size = 11, .weight = .bold, .mono = true, .color = white });
}

/// A bar filling from the bottom.
fn meter(c: *ui.Context, f: f32) void {
    const h: f32 = 16;
    const box = ui.div(c).column().w(4).h(h).rounded(1.5).bg(faint).justifyEnd().clip();
    defer box.end();
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = @max(1.5, h * std.math.clamp(f, 0, 1)) }, .background = white }, .none, null);
}

/// A grid of cells filling column by column, as nanomon's graphs.
fn cells(c: *ui.Context, f: f32) void {
    const cols = 7;
    const rows = 4;
    const filled: usize = @intFromFloat(@round(std.math.clamp(f, 0, 1) * cols * rows));
    const box = ui.div(c).w(cols * 3.5).h(rows * 3.5);
    defer box.end();
    for (0..cols) |x| for (0..rows) |y| {
        const i = x * rows + (rows - 1 - y);
        const off: ui.Point = .{ .x = @as(f32, @floatFromInt(x)) * 3.5, .y = @as(f32, @floatFromInt(y)) * 3.5 };
        _ = c.leaf(.{ .absolute = true, .offset = off, .width = .{ .px = 2.5 }, .height = .{ .px = 2.5 }, .radius = 0.6, .background = if (i < filled) white else faint }, .none, null);
    };
}

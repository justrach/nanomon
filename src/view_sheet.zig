//! What opens over the window, as in Activity Monitor: the View menu
//! (which processes show), the inspector (a double click, ⓘ or ⌘I), and
//! the sheet asking before a process is quit (ⓧ or ⌥⌘Q).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

/// A click outside closes what is open.
fn scrim(c: *ui.Context, shade: f32) ui.Div {
    const s = ui.div(c).absolute().sizeFull().column().itemsCenter().bg(.{ .a = shade });
    return s;
}

pub fn menu(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!a.menu) return;
    const s = scrim(c, 0);
    defer s.end();
    if (s.clicked()) a.menu = false;
    // Under its button.
    const m = ui.div(c).absolute().offset(a.menu_at[0], a.menu_at[1]).column().w(200).p(5).rounded(8).bg(k.control_on).border(k.separator).shadowLg();
    defer m.end();
    _ = m.interaction();
    for ([_]app_mod.Filter{ .all, .mine, .system }) |f| {
        ui.key(c, f.title());
        const item = ui.div(c).row().wFull().h(24).itemsCenter().gap(6).px(6).rounded(5).control();
        const it = item.interaction();
        if (it.hovered) c.node(item.index).style.background = k.selection;
        defer item.end();
        if (it.clicked) a.setFilter(f);
        const color = if (it.hovered) k.on_selection else k.text;
        const mark = ui.div(c).row().w(12).center();
        if (a.filter == f) ui.icon(c, "checkmark", .{ .size = 10, .weight = .bold, .color = color });
        mark.end();
        ui.text(c, f.title(), .{ .size = 13, .color = color });
    }
}

/// The app's icon, large, if it has one.
fn bigIcon(c: *ui.Context, a: *App, p: model.Process, size: f32) void {
    const box = ui.div(c).row().w(size).h(size).center();
    defer box.end();
    if (a.icons.get(p.bundle)) |png| {
        _ = ui.image(c, .{ .key = p.bundle, .bytes = png, .max_width = size, .max_height = size, .radius = 0 });
    } else ui.icon(c, "terminal", .{ .size = size * 0.6, .color = c.theme.muted });
}

pub fn inspector(c: *ui.Context, a: *App, k: theme.Colors) void {
    const pid = a.inspect orelse return;
    const p = a.find(pid) orelse {
        a.inspect = null;
        return;
    };
    const s = scrim(c, 0.12);
    defer s.end();
    if (s.clicked()) a.inspect = null;
    const gap = ui.div(c).row().h(kit.header_h + 30);
    gap.end();
    const box = ui.div(c).column().w(440).gap(14).p(18).rounded(10).bg(k.page).border(k.separator).shadowLg();
    defer box.end();
    _ = box.interaction();
    {
        const h = ui.div(c).row().wFull().gap(12).itemsCenter();
        defer h.end();
        bigIcon(c, a, p, 32);
        ui.text(c, c.print("{s} ({d})", .{ p.name, p.pid }), .{ .size = 15, .weight = .semibold, .color = k.text });
    }
    var b: [32]u8 = undefined;
    const parent = if (a.find(p.ppid)) |pp| c.print("{s} ({d})", .{ pp.name, pp.pid }) else c.print("{d}", .{p.ppid});
    const known = p.known;
    const detail = p.detailed();
    const lines = [_]struct { []const u8, []const u8 }{
        .{ "Parent Process:", parent },
        .{ "User:", c.print("{s} ({d})", .{ p.user, p.uid }) },
        .{ "% CPU:", if (known) c.print("{d:.1}", .{p.cpu}) else "–" },
        .{ "CPU Time:", if (known) c.print("{s}", .{model.duration(&b, p.cpu_time_ns)}) else "–" },
        .{ "Threads:", if (detail and p.threads > 0) c.print("{d}", .{p.threads}) else "–" },
        .{ "Idle Wake Ups:", if (detail) c.print("{d}", .{p.wakeups}) else "–" },
        .{ "Memory:", if (known) c.print("{s}", .{model.bytes(&b, p.memory)}) else "–" },
        .{ "Bytes Read:", if (detail) c.print("{s}", .{model.bytes(&b, p.disk_read)}) else "–" },
        .{ "Bytes Written:", if (detail) c.print("{s}", .{model.bytes(&b, p.disk_written)}) else "–" },
    };
    {
        const grid = ui.div(c).column().wFull().gap(4).p(12).rounded(6).bg(k.card).border(k.separator);
        defer grid.end();
        for (lines) |l| {
            const r = ui.div(c).row().wFull().gap(10);
            defer r.end();
            const label = ui.div(c).row().w(130).justifyEnd();
            ui.text(c, l[0], .{ .size = 12, .color = k.secondary });
            label.end();
            ui.text(c, l[1], .{ .size = 12, .color = k.text });
        }
    }
    if (p.from_ps) ui.text(c, "Only part of this process can be read without administrator rights.", .{ .size = 11, .color = k.secondary, .wrap = true });
    const r = ui.div(c).row().wFull().gap(8);
    defer r.end();
    ui.spacer(c);
    if (ui.button(c, "Quit…", .{ .variant = .secondary, .size = 12.5 }).clicked) a.confirm = p.pid;
    if (ui.button(c, "Done", .{ .variant = .primary, .size = 12.5 }).clicked) a.inspect = null;
}

/// "Quit 3 processes?": their names, a word on the system's, and Force
/// Quit, Cancel, Quit.
pub fn confirmMarked(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!a.confirm_marked) return;
    const sum = a.markedSummary();
    if (sum.count == 0) {
        a.confirm_marked = false;
        return;
    }
    const s = scrim(c, 0.18);
    defer s.end();
    if (s.clicked()) a.confirm_marked = false;
    const gap = ui.div(c).row().h(kit.header_h + 30);
    gap.end();
    const box = ui.div(c).column().w(440).gap(12).p(20).rounded(12).bg(k.page).border(k.border).shadowLg();
    defer box.end();
    _ = box.interaction();
    {
        const t = ui.div(c).row().gap(10).itemsCenter();
        defer t.end();
        kit.chip(c, "xmark.octagon", k.red, 28, false);
        ui.text(c, c.print("Quit {d} process{s}?", .{ sum.count, if (sum.count == 1) "" else "es" }), .{ .size = 15, .weight = .bold, .color = k.text });
    }
    {
        const list = ui.div(c).column().wFull().gap(2).p(10).rounded(8).bg(k.card).border(k.border);
        defer list.end();
        var shown: usize = 0;
        var b: [32]u8 = undefined;
        for (a.marked.keys()) |pid| if (a.find(pid)) |p| {
            if (shown == 7) break;
            shown += 1;
            ui.key(c, c.print("q-{d}", .{pid}));
            const r = ui.div(c).row().wFull().gap(8).itemsCenter().h(22);
            defer r.end();
            @import("view_memory.zig").procName(c, a, k, p, 220);
            ui.spacer(c);
            ui.text(c, c.print("{s}", .{model.bytes(&b, p.memory)}), .{ .size = 11, .mono = true, .color = k.secondary });
            if (p.uid != a.uid) ui.text(c, p.user, .{ .size = 11, .color = k.red });
        };
        if (sum.count > shown) ui.text(c, c.print("and {d} more", .{sum.count - shown}), .{ .size = 11.5, .color = k.secondary });
    }
    if (sum.system > 0) ui.text(c, c.print("{d} of them belong to another user or the system, and won't quit without administrator rights; they stay marked.", .{sum.system}), .{ .size = 11.5, .color = k.secondary, .wrap = true });
    ui.text(c, "Quit asks each to close; Force Quit ends them at once, and what they had not saved is lost.", .{ .size = 11.5, .color = k.secondary, .wrap = true });
    const r = ui.div(c).row().wFull().gap(8).pt(4);
    defer r.end();
    if (ui.button(c, "Force Quit", .{ .variant = .secondary, .size = 12.5 }).clicked) a.quitMarked(true);
    ui.spacer(c);
    if (ui.button(c, "Cancel", .{ .variant = .secondary, .size = 12.5 }).clicked) a.confirm_marked = false;
    if (ui.button(c, c.print("Quit {d}", .{sum.count}), .{ .variant = .primary, .size = 12.5 }).clicked) a.quitMarked(false);
}

/// "Are you sure you want to quit this process?": Force Quit, Cancel, Quit.
pub fn confirm(c: *ui.Context, a: *App, k: theme.Colors) void {
    const pid = a.confirm orelse return;
    const p = a.find(pid) orelse {
        a.confirm = null;
        return;
    };
    const s = scrim(c, 0.12);
    defer s.end();
    if (s.clicked()) a.confirm = null;
    const gap = ui.div(c).row().h(kit.header_h);
    gap.end();
    const box = ui.div(c).row().w(460).gap(16).p(20).rounded(10).bg(k.page).border(k.separator).shadowLg();
    defer box.end();
    _ = box.interaction();
    bigIcon(c, a, p, 48);
    // A width of its own: wrapping text is measured at it.
    const col = ui.div(c).column().w(460 - 2 * 20 - 48 - 16).gap(8);
    defer col.end();
    ui.text(c, "Are you sure you want to quit this process?", .{ .size = 13, .weight = .bold, .color = k.text, .wrap = true });
    ui.text(c, c.print("Do you really want to quit “{s}”? Force Quit ends it at once; what it had not saved is lost.", .{p.name}), .{ .size = 11.5, .color = k.text, .wrap = true });
    const r = ui.div(c).row().wFull().gap(8).pt(6);
    defer r.end();
    if (ui.button(c, "Force Quit", .{ .variant = .secondary, .size = 12.5 }).clicked) a.quit(pid, true);
    ui.spacer(c);
    if (ui.button(c, "Cancel", .{ .variant = .secondary, .size = 12.5 }).clicked) a.confirm = null;
    if (ui.button(c, "Quit", .{ .variant = .primary, .size = 12.5 }).clicked) a.quit(pid, false);
}

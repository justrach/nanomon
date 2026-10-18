//! The process table, as Activity Monitor's: the tab's columns under a
//! header that sorts when clicked (dividers between, a chevron on the
//! sorted one), striped rows built only as they come into view
//! (`ui.list`), each with its app's icon, the selection in the accent
//! color. A double click inspects. A box at each row's start marks it to
//! quit with others (as do ⌘-click and ⇧-click for a run of rows; the
//! header's box marks them all). Rows are keyed by pid, so a process's
//! % CPU glides to each sample's value as it moves through the table.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const App = @import("app.zig").App;

pub const row_h = 22;
const header_h = 24;
const pad = 8;

const Column = struct { title: []const u8, key: model.Sort, width: ?f32 = null, right: bool = true };

const name_col: Column = .{ .title = "Process Name", .key = .name, .right = false };
const pid_col: Column = .{ .title = "PID", .key = .pid, .width = 64 };
const user_col: Column = .{ .title = "User", .key = .user, .width = 120, .right = false };

pub fn columns(tab: model.Tab) []const Column {
    return switch (tab) {
        .cpu => &.{ name_col, .{ .title = "% CPU", .key = .cpu, .width = 72 }, .{ .title = "CPU Time", .key = .time, .width = 92 }, .{ .title = "Threads", .key = .threads, .width = 68 }, .{ .title = "Idle Wake Ups", .key = .wakeups, .width = 104 }, pid_col, user_col },
        .memory => &.{ name_col, .{ .title = "Memory", .key = .memory, .width = 96 }, .{ .title = "Threads", .key = .threads, .width = 68 }, pid_col, user_col },
        .disk => &.{ name_col, .{ .title = "Bytes Written", .key = .written, .width = 112 }, .{ .title = "Bytes Read", .key = .read, .width = 112 }, pid_col, user_col },
    };
}

fn cell(c: *ui.Context, col: Column, h: f32) ui.Div {
    var d = ui.div(c).row().h(h).itemsCenter().px(pad).clip();
    d = if (col.width) |w| d.w(w) else d.grow().w(0);
    if (col.right) d = d.justifyEnd();
    return d;
}

/// The 1-point divider between columns: drawn in the header, room in rows.
fn divider(c: *ui.Context, color: ?ui.Color) void {
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 14 }, .background = color }, .none, null);
}

pub fn table(c: *ui.Context, a: *App, k: theme.Colors) void {
    const box = ui.div(c).column().wFull().grow().bg(k.page).clip();
    defer box.end();
    const cols = columns(a.tab);
    {
        const h = ui.div(c).row().wFull().h(header_h).itemsCenter();
        defer h.end();
        if (check(c, k, "mark-all", markState(a), false)) a.markAll();
        for (cols, 0..) |col, i| {
            if (i > 0) divider(c, k.separator);
            ui.key(c, col.title);
            var d = cell(c, col, header_h).gap(4).control();
            d = d.hover(k.hover);
            defer d.end();
            if (d.clicked()) a.sortBy(col.key);
            const on = a.sort == col.key;
            ui.text(c, col.title, .{ .size = 11.5, .weight = if (on) .semibold else .regular, .color = if (on) k.text else k.secondary });
            if (on) ui.icon(c, if (a.ascending) "chevron.up" else "chevron.down", .{ .size = 8, .weight = .bold, .color = k.secondary });
        }
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    const procs = a.sampler.procs.items;
    var rows = ui.list(c, .{ .count = a.rows.items.len, .row_height = row_h, .scroll_to = reveal(c, a) });
    while (rows.next()) |i| row(c, a, k, procs[a.rows.items[i]], i, cols);
    rows.end();
}

/// Where the list scrolls so the selection the keyboard moved shows.
fn reveal(c: *ui.Context, a: *App) ?f32 {
    if (!a.reveal) return null;
    a.reveal = false;
    const at = a.selectedRow() orelse return null;
    const id = c.peekId(null);
    const view_h = if (c.rects.get(id)) |r| r.h else return null;
    const scroll = c.scroll.get(id) orelse 0;
    const y = @as(f32, @floatFromInt(at)) * row_h;
    if (y < scroll) return y;
    if (y + row_h > scroll + view_h) return y + row_h - view_h;
    return null;
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, p: model.Process, i: usize, cols: []const Column) void {
    // Keyed by pid: the selection and the eased % CPU follow the process.
    ui.key(c, c.print("pid-{d}", .{p.pid}));
    const sel = a.selected == p.pid;
    const marked = a.marked.contains(p.pid);
    const bg = if (sel) k.selection else if (marked) k.marked else if (i % 2 == 1) k.stripe else k.page;
    const r = ui.div(c).row().wFull().h(row_h).itemsCenter().bg(bg);
    defer r.end();
    const it = r.interaction();
    if (it.clicked) {
        if (c.input.adding()) a.mark(p.pid) else if (c.input.shift) a.markTo(p.pid) else a.selected = p.pid;
        c.changed = true;
    }
    if (check(c, k, "mark", if (marked) .all else .none, sel)) a.mark(p.pid);
    if (it.double_clicked) a.inspect = p.pid;
    const text = if (sel) k.on_selection else k.text;
    const muted = if (sel) k.on_selection.alpha(0.85) else k.secondary;
    var buf: [32]u8 = undefined;
    for (cols, 0..) |col, n| {
        if (n > 0) divider(c, null);
        const d = cell(c, col, row_h);
        defer d.end();
        const value: []const u8 = switch (col.key) {
            .name => {
                nameCell(c, a, p, text);
                continue;
            },
            .cpu => if (p.known) c.print("{d:.1}", .{c.animate(c.peekId(null), 1, p.cpu, 6)}) else "",
            .time => if (p.known) c.print("{s}", .{model.duration(&buf, p.cpu_time_ns)}) else "",
            .threads => if (p.detailed() and p.threads > 0) c.print("{d}", .{p.threads}) else "",
            .wakeups => if (p.detailed()) c.print("{d}", .{p.wakeups}) else "",
            .memory => if (p.known) c.print("{s}", .{model.bytes(&buf, p.memory)}) else "",
            .written => if (p.detailed()) c.print("{s}", .{model.bytes(&buf, p.disk_written)}) else "",
            .read => if (p.detailed()) c.print("{s}", .{model.bytes(&buf, p.disk_read)}) else "",
            .pid => c.print("{d}", .{p.pid}),
            .user => p.user,
        };
        // Not ours to read: a dash, where Activity Monitor would have it.
        if (value.len == 0) {
            ui.text(c, "–", .{ .size = 12.5, .color = if (sel) muted else k.tertiary });
        } else ui.text(c, value, .{ .size = 12.5, .color = if (col.key == .user or col.key == .pid) muted else text });
    }
}

pub const Mark = enum { none, some, all };

fn markState(a: *App) Mark {
    const procs = a.sampler.procs.items;
    var n: usize = 0;
    for (a.rows.items) |r| {
        if (a.marked.contains(procs[r].pid)) n += 1;
    }
    if (n == 0) return .none;
    return if (n == a.rows.items.len) .all else .some;
}

/// A check box at a row's start; whether it was clicked.
pub fn check(c: *ui.Context, k: theme.Colors, key: []const u8, state: Mark, on_selection: bool) bool {
    ui.key(c, key);
    const cell_box = ui.div(c).row().w(30).h(row_h).center().control();
    defer cell_box.end();
    const clicked = cell_box.clicked();
    const filled = state != .none;
    const box = ui.div(c).row().w(14).h(14).center().rounded(4).bg(if (filled) k.accent else k.page.alpha(0)).border(if (filled) k.accent else if (on_selection) k.text.alpha(0.4) else k.tertiary);
    defer box.end();
    switch (state) {
        .all => ui.icon(c, "checkmark", .{ .size = 8.5, .weight = .bold, .color = k.on_picked }),
        .some => _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 2 }, .radius = 1, .background = k.on_picked }, .none, null),
        .none => {},
    }
    return clicked;
}

fn nameCell(c: *ui.Context, a: *App, p: model.Process, color: ui.Color) void {
    const icon = ui.div(c).row().w(16).h(16).center();
    if (a.icons.get(p.bundle)) |png| _ = ui.image(c, .{ .key = p.bundle, .bytes = png, .max_width = 16, .max_height = 16, .radius = 0 });
    icon.end();
    const gap = ui.div(c).row().w(6);
    gap.end();
    ui.text(c, p.name, .{ .size = 12.5, .color = color });
}

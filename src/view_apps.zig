//! The Apps page: processes together by the app they belong to (Chrome
//! and every helper it runs), each with its icon, how many processes, its
//! CPU, memory and threads summed; sorted by any of them. A double click
//! inspects the app's first process.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const procs = @import("view_procs.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

const row_h = 26;

const Column = struct { title: []const u8, by: app_mod.AppSort, width: ?f32 = null };

const columns = [_]Column{
    .{ .title = "Name", .by = .name },
    .{ .title = "Processes", .by = .processes, .width = 90 },
    .{ .title = "% CPU", .by = .cpu, .width = 80 },
    .{ .title = "Memory", .by = .memory, .width = 100 },
    .{ .title = "Threads", .by = .threads, .width = 80 },
};

fn cell(c: *ui.Context, col: Column, h: f32) ui.Div {
    var d = ui.div(c).row().h(h).itemsCenter().px(10).clip();
    d = if (col.width) |w| d.w(w).justifyEnd() else d.grow().w(0);
    return d;
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    var processes: u32 = 0;
    for (a.apps.items) |r| processes += r.processes;
    {
        const h = kit.header(c, k, "Apps", c.print("{d} apps · {d} processes", .{ a.apps.items.len, processes }));
        defer h.end();
        procs.search(c, a, k, 200);
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    {
        const h = ui.div(c).row().wFull().h(28).itemsCenter().px(10);
        defer h.end();
        for (columns, 0..) |col, i| {
            if (i > 0) _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 14 }, .background = k.separator }, .none, null);
            ui.key(c, col.title);
            const d = cell(c, col, 28).gap(4).hover(k.hover).control();
            defer d.end();
            if (d.clicked()) a.sortApps(col.by);
            const on = a.app_sort == col.by;
            ui.text(c, col.title, .{ .size = 11.5, .weight = if (on) .semibold else .regular, .color = if (on) k.text else k.secondary });
            if (on) ui.icon(c, if (a.app_ascending) "chevron.up" else "chevron.down", .{ .size = 8, .weight = .bold, .color = k.secondary });
        }
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    var rows = ui.list(c, .{ .count = a.apps.items.len, .row_height = row_h, .padding = .{ .left = 10, .right = 10 } });
    while (rows.next()) |i| row(c, a, k, a.apps.items[i], i);
    rows.end();
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, r: app_mod.AppRow, i: usize) void {
    ui.key(c, r.bundle);
    const sel = a.selected == r.pid;
    const bg = if (sel) k.selection else if (i % 2 == 1) k.stripe else k.page;
    const d = ui.div(c).row().wFull().h(row_h).itemsCenter().rounded(6).bg(bg);
    defer d.end();
    const it = d.interaction();
    if (it.clicked) {
        a.selected = r.pid;
        c.changed = true;
    }
    if (it.double_clicked) a.inspect = r.pid;
    const text = if (sel) k.on_selection else k.text;
    var b: [32]u8 = undefined;
    for (columns, 0..) |col, n| {
        if (n > 0) _ = c.leaf(.{ .width = .{ .px = 1 } }, .none, null);
        const cl = cell(c, col, row_h);
        defer cl.end();
        switch (col.by) {
            .name => {
                const icon = ui.div(c).row().w(18).h(18).center();
                if (a.icons.get(r.bundle)) |png| _ = ui.image(c, .{ .key = r.bundle, .bytes = png, .max_width = 18, .max_height = 18, .radius = 0 });
                icon.end();
                const gap = ui.div(c).row().w(8);
                gap.end();
                ui.text(c, r.name, .{ .size = 12.5, .weight = .medium, .color = text });
            },
            .processes => ui.text(c, c.print("{d}", .{r.processes}), .{ .size = 12.5, .color = text }),
            .cpu => ui.text(c, c.print("{d:.1}", .{c.animate(c.peekId(null), 1, r.cpu, 6)}), .{ .size = 12.5, .color = text }),
            .memory => ui.text(c, c.print("{s}", .{model.bytes(&b, r.memory)}), .{ .size = 12.5, .color = text }),
            .threads => ui.text(c, if (r.threads > 0) c.print("{d}", .{r.threads}) else "–", .{ .size = 12.5, .color = if (sel) text else k.secondary }),
        }
    }
}

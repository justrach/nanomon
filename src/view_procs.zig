//! The Processes page: which processes show (a menu: all, the user's,
//! the system's), the table's columns (CPU, Memory, Disk), the search,
//! Inspect and Quit; under them, the table (view_table.zig), and when
//! processes are marked, a bar to quit them together or ask graff.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const table = @import("view_table.zig");
const App = @import("app.zig").App;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    var b: [2][32]u8 = undefined;
    const sy = a.sampler.system;
    {
        const sub = if (sy.threads > 0)
            c.print("{s} shown · {s} threads", .{ model.count(&b[0], a.rows.items.len), model.count(&b[1], sy.threads) })
        else
            c.print("{s} shown", .{model.count(&b[0], a.rows.items.len)});
        const h = kit.header(c, k, "Processes", sub);
        defer h.end();
        filter(c, a, k);
        const tabs = [_]model.Tab{ .cpu, .memory, .disk };
        if (kit.segmented(c, k, &.{ "CPU", "Memory", "Disk" }, @intFromEnum(a.tab))) |i| a.show(tabs[i]);
        search(c, a, k, 170);
        const chosen = if (a.selected) |pid| a.find(pid) != null else false;
        if (tool(c, k, "info.circle", chosen)) a.inspect = a.selected;
        if (tool(c, k, "xmark.octagon", chosen)) a.confirm = a.selected;
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    table.table(c, a, k);
    actions(c, a, k);
}

/// What is marked, what it holds, and what to do with it; or what the
/// last quitting did.
fn actions(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sum = a.markedSummary();
    const notice = a.noticeText();
    if (sum.count == 0 and notice == null) return;
    if (notice != null) c.frameIn(@floatCast(@max(0.05, a.notice_until - a.now)));
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    const bar = ui.div(c).row().wFull().h(50).itemsCenter().gap(10).px(16).bg(k.card);
    defer bar.end();
    if (sum.count == 0) {
        ui.icon(c, "checkmark.circle.fill", .{ .size = 13, .color = k.green });
        ui.text(c, notice.?, .{ .size = 12, .color = k.text });
        return;
    }
    var b: [32]u8 = undefined;
    _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 2, .background = k.accent }, .none, null);
    ui.text(c, c.print("{d} marked", .{sum.count}), .{ .size = 12.5, .weight = .semibold, .color = k.text });
    ui.text(c, c.print("{s} · {d:.1}% CPU", .{ model.bytes(&b, sum.memory), sum.cpu }), .{ .size = 11.5, .mono = true, .color = k.secondary });
    if (sum.system > 0) ui.text(c, c.print("· {d} not yours", .{sum.system}), .{ .size = 11.5, .color = k.red });
    ui.spacer(c);
    if (notice) |n| ui.text(c, n, .{ .size = 11.5, .color = k.secondary });
    if (ui.button(c, "Clear", .{ .variant = .ghost, .size = 12 }).clicked) a.marked.clearRetainingCapacity();
    if (ui.button(c, "Ask graff", .{ .variant = .secondary, .size = 12, .icon = "sparkles" }).clicked) @import("view_graff.zig").askAboutMarked(c, a);
    if (ui.button(c, c.print("Quit {d}…", .{sum.count}), .{ .variant = .primary, .size = 12 }).clicked) a.confirm_marked = true;
}

/// "All Processes ⌄": opens the menu under itself.
fn filter(c: *ui.Context, a: *App, k: theme.Colors) void {
    ui.key(c, "filter");
    const d = ui.div(c).row().h(26).gap(5).itemsCenter().px(10).rounded(8).bg(k.control).hover(k.hover).control();
    defer d.end();
    const it = d.interaction();
    if (it.clicked) {
        a.menu = !a.menu;
        c.changed = true;
    }
    if (it.rect) |r| a.menu_at = .{ r.x, r.y + r.h + 4 };
    ui.text(c, a.filter.title(), .{ .size = 11.5, .color = k.text });
    ui.icon(c, "chevron.down", .{ .size = 8, .weight = .bold, .color = k.secondary });
}

pub fn search(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const f = ui.div(c).row().w(w).h(26).itemsCenter().gap(5).px(8).rounded(8).bg(k.control);
    defer f.end();
    ui.icon(c, "magnifyingglass", .{ .size = 11, .color = k.secondary });
    if (a.find_search) {
        a.find_search = false;
        c.focus = c.peekId(null);
    }
    const res = ui.textField(c, &a.query, .{ .placeholder = "Search", .width = .fill, .size = 12, .bare = true });
    if (res.changed) a.dirty = true;
}

/// A toolbar button: an icon, dimmed when there is nothing to act on.
fn tool(c: *ui.Context, k: theme.Colors, icon: []const u8, enabled: bool) bool {
    ui.key(c, icon);
    var d = ui.div(c).row().w(30).h(26).center().rounded(8).control();
    if (enabled) d = d.hover(k.hover) else d = d.opacity(0.35);
    defer d.end();
    const clicked = d.clicked() and enabled;
    ui.icon(c, icon, .{ .size = 15, .color = k.secondary });
    return clicked;
}

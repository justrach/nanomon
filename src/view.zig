//! nanomon's window: a sidebar of pages, each with a figure beside its
//! name (view_side.zig), and the page: an overview, the processes, CPU,
//! memory, GPU, disk, network, apps, and this Mac. Samples every two
//! seconds while it shows (unless paused); between samples it draws only
//! what moves.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const side = @import("view_side.zig");
const sheet = @import("view_sheet.zig");
const kit = @import("view_kit.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

const pages = struct {
    const overview = @import("view_overview.zig");
    const procs = @import("view_procs.zig");
    const cpu = @import("view_cpu.zig");
    const memory = @import("view_memory.zig");
    const io = @import("view_io.zig");
    const apps = @import("view_apps.zig");
    const about = @import("view_about.zig");
};

pub fn view(a: *App, c: *ui.Context) void {
    const dark = a.dark orelse nanoui.isDark();
    c.theme = theme.ui(dark);
    const k = theme.colors(dark);
    // The next sample, and only then, unless something animates.
    c.frameIn(a.tick(c.time));
    a.icons.frame();
    // The headers' empty space moves the window, as a title bar's does.
    c.title_bar_height = kit.header_h;
    keys(c, a);
    const root = ui.div(c).row().sizeFull().bg(k.page);
    defer root.end();
    side.sidebar(c, a, k);
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.separator }, .none, null);
    {
        const main = ui.div(c).column().grow().w(0).hFull().clip();
        defer main.end();
        switch (a.page) {
            .overview => pages.overview.page(c, a, k),
            .processes => pages.procs.page(c, a, k),
            .cpu => pages.cpu.page(c, a, k),
            .memory => pages.memory.page(c, a, k),
            .gpu => pages.memory.gpuPage(c, a, k),
            .disk => pages.io.disk(c, a, k),
            .network => pages.io.network(c, a, k),
            .apps => pages.apps.page(c, a, k),
            .about => pages.about.page(c, a, k),
        }
    }
    sheet.menu(c, a, k);
    sheet.inspector(c, a, k);
    sheet.confirm(c, a, k);
    sheet.confirmMarked(c, a, k);
    @import("view_graff.zig").bubble(c, a, k);
    // Icons left for later frames, a few a frame.
    if (a.icons.pending) c.frameIn(1.0 / 60.0);
}

/// The page under the header, scrolling: cards with room between.
pub fn body(c: *ui.Context) ui.Div {
    return ui.div(c).column().wFull().grow().scrollY().px(20).pb(20).gap(14);
}

/// ⌘1–⌘9 pick a page; ↑ and ↓ move the selection, ⌘I inspects it, ⌥⌘Q
/// quits it, ⌘F finds, Space pauses, Escape closes what is open.
fn keys(c: *ui.Context, a: *App) void {
    const S = ui.Shortcut;
    const all = std.enums.values(app_mod.Page);
    for (all, 0..) |p, i| if (c.shortcut(.{ .key = @as(u21, '1') + @as(u21, @intCast(i)), .cmd = true })) {
        a.page = p;
    };
    if (c.shortcut(.{ .key = S.down })) {
        a.step(1);
        a.reveal = true;
    }
    if (c.shortcut(.{ .key = S.up })) {
        a.step(-1);
        a.reveal = true;
    }
    if (c.shortcut(.{ .key = 'i', .cmd = true })) a.inspect = a.selected;
    if (c.shortcut(.{ .key = 'q', .cmd = true, .alt = true })) a.confirm = a.selected;
    if (c.shortcut(.{ .key = 'f', .cmd = true })) {
        if (a.page != .apps) a.page = .processes;
        a.find_search = true;
    }
    if (c.shortcut(.{ .key = 'p', .cmd = true, .shift = true })) a.paused = !a.paused;
    if (c.shortcut(.{ .key = S.escape })) {
        if (a.confirm_marked) a.confirm_marked = false else if (a.graff.open) a.graff.open = false else if (a.confirm != null) a.confirm = null else if (a.inspect != null) a.inspect = null else if (a.menu) a.menu = false else a.selected = null;
    }
}

//! Compact storage rows and demand-only review/confirm sheets. No new page.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const storage = @import("storage.zig");
const App = @import("app.zig").App;

pub fn capacity(c: *ui.Context, a: *App, k: theme.Colors) void {
    var b: [80]u8 = undefined;
    const v = a.sampler.system.storage orelse {
        kit.line(c, k, "Storage", "Unavailable", null);
        return;
    };
    kit.line(c, k, "Storage", c.print("{s}", .{@import("storage.zig").summary(&b, v)}), null);
}
pub fn row(c: *ui.Context, a: *App, k: theme.Colors) void {
    const result = a.worktrees.latest orelse return;
    var n: usize = 0;
    var bytes: u64 = 0;
    var unknown = false;
    for (result.snapshot.entries) |e| if (!e.is_primary and e.stale()) {
        n += 1;
        if (e.size_bytes) |s| {
            bytes +|= s;
        } else unknown = true;
    };
    if (n == 0) return;
    var b: [32]u8 = undefined;
    const r = ui.div(c).row().wFull().h(24).itemsCenter().rounded(4).hover(k.hover).control();
    defer r.end();
    if (r.clicked()) a.worktrees.open = true;
    ui.text(c, "Worktrees", .{ .size = 12, .color = k.secondary });
    ui.spacer(c);
    ui.text(c, c.print("{d} to review{s}{s}", .{ n, if (unknown) "" else " · ~", if (unknown) "" else storage.brief(&b, bytes) }), .{ .size = 12, .weight = .medium, .color = k.accent });
    ui.icon(c, "chevron.right", .{ .size = 9, .frame = 14, .color = k.accent });
}
pub fn button(c: *ui.Context, a: *App) void {
    if (ui.button(c, "Review worktrees…", .{ .variant = .secondary, .size = 11.5 }).clicked)
        a.worktrees.open = true;
}
fn choose(a: *App) void {
    const m = &a.worktrees;
    const gpa = a.sampler.gpa;
    const paths = nanoui.dialog.open(gpa, .{ .title = "Review a Git repository", .directories = true, .files = false, .multiple = false }) catch {
        m.message = "Could not open the repository picker.";
        return;
    } orelse return;
    defer nanoui.dialog.freePaths(gpa, paths);
    if (paths.len == 0) return;
    if (m.selected_repo) |old| gpa.free(old);
    m.gpa = gpa;
    m.selected_repo = gpa.dupe(u8, paths[0]) catch null;
    m.start(a, null);
}
pub fn sheet(c: *ui.Context, a: *App, k: theme.Colors) void {
    const m = &a.worktrees;
    if (!m.open) return;
    m.take();
    const scrim = ui.div(c).absolute().sizeFull().column().itemsCenter().justifyCenter().bg(.{ .a = 0.15 });
    defer scrim.end();
    if (scrim.clicked() and !m.busy) {
        m.open = false;
        m.confirm = null;
    }
    const width = @min(680, c.size.w - 32);
    const box = ui.div(c).column().w(width).maxH(c.size.h - 24).gap(12).p(18).rounded(12).bg(k.page).border(k.border).shadowLg();
    defer box.end();
    _ = box.interaction();
    {
        const h = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer h.end();
        kit.chip(c, "internaldrive", k.orange, 28, false);
        ui.text(c, if (m.confirm != null) "Clear this worktree?" else "Storage & worktrees", .{ .size = 16, .weight = .bold, .color = k.text });
        ui.spacer(c);
        if (ui.button(c, "Done", .{ .variant = .secondary, .disabled = m.busy, .size = 12 }).clicked) {
            m.open = false;
            m.confirm = null;
        }
    }
    capacity(c, a, k);
    if (m.confirm) |i| {
        const latest = m.latest orelse return;
        if (i >= latest.snapshot.entries.len) {
            m.confirm = null;
            return;
        }
        const e = latest.snapshot.entries[i];
        ui.text(c, e.path, .{ .size = 12, .mono = true, .wrap = true, .color = k.text });
        ui.text(c, if (e.missing == true)
            "The checkout is already missing. This clears only its Git registration (0 directory bytes reclaimed), after verifying its saved index matches HEAD. Its branch and committed history stay."
        else
            "This removes the checkout directory, not its branch or committed history. Only confirm if you no longer need it. Activity checks are best-effort: clean does not mean unused.", .{ .size = 12, .wrap = true, .color = k.secondary });
        ui.text(c, "Git status, locks, HEAD and registration will be rechecked. Changed, untracked, ignored, locked, detached, primary or observed-active worktrees are kept. No force removal.", .{ .size = 12, .wrap = true, .color = k.secondary });
        const actions = ui.div(c).row().wFull().gap(8);
        defer actions.end();
        ui.spacer(c);
        if (ui.button(c, "Cancel", .{ .variant = .secondary }).clicked) m.confirm = null;
        if (ui.button(c, "Clear worktree", .{ .variant = .primary }).clicked) m.start(a, i);
        return;
    }
    ui.text(c, "Scan only repositories used by sampled processes, or choose one. No home-directory crawl. Age/merged status is a review hint, never permission to delete.", .{ .size = 11.5, .wrap = true, .color = k.secondary });
    {
        const actions = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer actions.end();
        if (ui.button(c, "Scan active repositories", .{ .variant = .secondary, .disabled = m.busy, .size = 12 }).clicked) {
            if (m.selected_repo) |p| a.sampler.gpa.free(p);
            m.selected_repo = null;
            m.start(a, null);
        }
        if (ui.button(c, "Choose repository…", .{ .variant = .secondary, .disabled = m.busy, .size = 12 }).clicked) choose(a);
        if (ui.button(c, "Refresh", .{ .variant = .ghost, .disabled = m.busy, .size = 12 }).clicked) m.start(a, null);
    }
    ui.text(c, m.message, .{ .size = 11.5, .wrap = true, .color = k.secondary });
    const latest = m.latest orelse return;
    if (latest.activity_incomplete or latest.snapshot.truncated or latest.snapshot.errors > 0)
        ui.text(c, "Partial coverage: permissions, limits or unreadable metadata may hide repositories/activity. Nothing is automatically cleared.", .{ .size = 11, .wrap = true, .color = k.orange });
    if (latest.snapshot.entries.len == 0) {
        ui.text(c, "No supported Git worktrees found. Try choosing a repository.", .{ .size = 12, .color = k.secondary });
        return;
    }
    const list = ui.div(c).column().wFull().maxH(@max(100, c.size.h - 330)).scrollY().gap(8);
    defer list.end();
    for (latest.snapshot.entries, 0..) |e, i| {
        ui.key(c, e.git_dir);
        const card = ui.div(c).column().wFull().p(10).gap(4).rounded(8).bg(k.card).border(k.border);
        defer card.end();
        const top = ui.div(c).row().wFull().gap(8).itemsCenter();
        kit.chip(c, if (e.locked) "lock" else "folder", if (e.prunable) k.orange else k.gray, 22, false);
        const branch = ui.div(c).column().grow().w(0).clip();
        ui.text(c, if (e.branch.len > 0) e.branch else "Detached / unresolved", .{ .size = 12, .weight = .semibold, .color = k.text });
        branch.end();
        var b: [32]u8 = undefined;
        ui.text(c, if (e.size_bytes) |s| c.print("~{s}", .{storage.brief(&b, s)}) else "Size unknown", .{ .size = 11, .color = k.secondary });
        if (e.prunable and ui.button(c, "Review clearing…", .{ .variant = .secondary, .disabled = m.busy, .size = 11 }).clicked) m.confirm = i;
        top.end();
        ui.text(c, e.path, .{ .size = 10.5, .mono = true, .wrap = true, .color = k.secondary });
        ui.text(c, e.note, .{ .size = 11, .wrap = true, .color = if (e.prunable) k.orange else k.secondary });
        if (e.reasons.untouched) ui.text(c, "Directory mtime older than 14 days (not proof of inactivity)", .{ .size = 10, .color = k.tertiary });
        if (e.reasons.merged) ui.text(c, "HEAD is merged into local main", .{ .size = 10, .color = k.tertiary });
    }
}

//! Offscreen behavior/layout tests. Never invoke the real picker or cleanup.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const tests = @import("tests.zig");
const theme = @import("theme.zig");
const view = @import("view.zig").view;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

test "storage fits existing views and worktree review requires a separate confirmation" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try tests.fake(&a);
    try @import("storage_fixture.zig").attach(&a);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view), .{ .width = 1100, .height = 820, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(0.5);
    try expect(t.hasText("Storage"));
    try expect(t.hasText("142 GiB free / 512 GiB"));
    const label = t.findText("Storage").?;
    const value = t.findText("142 GiB free / 512 GiB").?;
    try expect(value.x >= label.x + label.w + 8);
    try expect(value.x + value.w < 1100 - 20);
    try expect(t.hasText("4 to review"));
    try t.clickText("4 to review");
    t.settle(0.2);
    try expect(a.worktrees.open);
    try expect(t.hasText("Storage & worktrees"));
    try expect(t.hasText("Locked — kept"));
    try expect(t.hasText("Changed, untracked or ignored files — kept"));
    try expect(!a.worktrees.busy and a.worktrees.thread == null);
    try t.clickText("Review clearing…");
    t.settle(0.2);
    try expect(a.worktrees.confirm != null);
    try expect(t.hasText("Clear this worktree?"));
    try expect(!a.worktrees.busy and a.worktrees.thread == null);
    try t.clickText("Cancel");
    t.settle(0.2);
    try expect(a.worktrees.confirm == null and a.worktrees.open);
    try t.clickText("Done");
    t.settle(0.2);
    a.page = .disk;
    t.settle(0.2);
    try expect(t.hasText("Review worktrees…") and t.hasText("Storage"));
    // Sidebar Disk remains a rate, never capacity.
    try expect(t.hasText("5.00 MB/s"));
}

test "no stale worktrees means no extra overview row and no automatic worker" {
    var a: App = .init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    try tests.fake(&a);
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&a, view), .{ .width = 1100, .height = 820 });
    defer t.deinit();
    t.settle(0.5);
    try expect(!t.hasText("Worktrees"));
    try expect(a.worktrees.thread == null and a.worktrees.latest == null);
}

fn chips(_: *u8, c: *ui.Context) void {
    const row = ui.div(c).row().gap(8).itemsCenter();
    defer row.end();
    for ([_][]const u8{ "cpu", "memorychip", "network", "internaldrive", "folder", "lock", "desktopcomputer" }) |name| {
        ui.key(c, name);
        @import("view_kit.zig").chip(c, name, .white, 22, false);
    }
}
test "all chip symbols have equal square frames centered in fixed-size chips" {
    var state: u8 = 0;
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, chips), .{ .width = 400, .height = 100 });
    defer t.deinit();
    t.settle(0.2);
    var count: usize = 0;
    for (t.ctx.nodes.items) |node| {
        if (node.content != .icon) continue;
        const r = node.rect;
        const parent = t.ctx.nodes.items[node.parent];
        try equal(@as(f32, 22), r.w);
        try equal(@as(f32, 22), r.h);
        try std.testing.expectApproxEqAbs(parent.rect.x + parent.rect.w / 2, r.x + r.w / 2, 0.01);
        try std.testing.expectApproxEqAbs(parent.rect.y + parent.rect.h / 2, r.y + r.h / 2, 0.01);
        count += 1;
    }
    try equal(@as(usize, 7), count);
}

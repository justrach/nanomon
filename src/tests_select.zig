//! Marking processes and quitting them together, and the graff bubble,
//! through the Tester. No signal is sent: the app's `send` records them;
//! graff is a script that answers and notes how it was started.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const view = @import("view.zig");
const theme = @import("theme.zig");
const side = @import("view_side.zig");
const t_mod = @import("tests.zig");

var sent: [16][2]c_int = undefined;
var sent_len: usize = 0;

/// The user's processes quit; root's refuse, as kill(2) would.
fn record(pid: c_int, sig: c_int) callconv(.c) c_int {
    sent[sent_len] = .{ pid, sig };
    sent_len += 1;
    return if (pid == 990001 or pid == 990004) -1 else 0;
}

/// The middle of a row's check box.
fn box(t: *ui.Tester, name: []const u8) [2]f32 {
    const r = t.findText(name).?;
    return .{ side.width + 1 + 15, r.y + r.h / 2 };
}

test "processes are marked by their boxes, ⌘-click and ⇧-click, and quit together" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try t_mod.fake(&a);
    a.page = .processes;
    a.send = record;
    sent_len = 0;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(2);
    // A box marks one.
    const safari = box(&t, "Safari");
    t.click(safari[0], safari[1]);
    t.settle(1);
    try std.testing.expect(a.marked.contains(990002) and a.selected == null);
    try std.testing.expect(t.hasText("1 marked"));
    // ⌘-click (Control elsewhere) marks another.
    const mail = t.findText("Mail").?;
    t.ctx.input.cmd = true;
    t.ctx.input.ctrl = true;
    t.click(mail.x + 4, mail.y + mail.h / 2);
    t.ctx.input.cmd = false;
    t.ctx.input.ctrl = false;
    t.settle(1);
    try std.testing.expect(a.marked.contains(990003));
    // ⇧-click marks the run from the selected row.
    const web = t.findText("Safari Web Content").?;
    t.click(web.x + 4, web.y + web.h / 2);
    t.settle(1);
    const kern = t.findText("kernel_task").?;
    t.ctx.input.shift = true;
    t.click(kern.x + 4, kern.y + kern.h / 2);
    t.ctx.input.shift = false;
    t.settle(1);
    try std.testing.expect(a.marked.contains(990005) and a.marked.contains(990001));
    try std.testing.expect(t.hasText("4 marked") and t.hasText("· 1 not yours"));
    try t.screenshot("/tmp/nanomon-marked.png");
    // Quit asks first, naming them.
    try t_mod.open(&t, "Quit 4…");
    try std.testing.expect(t.hasText("Quit 4 processes?"));
    try t.screenshot("/tmp/nanomon-quit-marked.png");
    try t_mod.open(&t, "Quit 4");
    try std.testing.expectEqual(@as(usize, 4), sent_len);
    for (sent[0..sent_len]) |s| try std.testing.expectEqual(@as(c_int, 15), s[1]);
    // The one not ours stays marked; the notice says so.
    try std.testing.expectEqual(@as(usize, 1), a.marked.count());
    try std.testing.expect(t.containsText("not yours to quit"));
    // The header's box marks every row shown, then none.
    const all = t.findText("Process Name").?;
    t.click(side.width + 1 + 15, all.y + all.h / 2);
    t.settle(1);
    try std.testing.expectEqual(a.rows.items.len, a.marked.count());
    t.click(side.width + 1 + 15, all.y + all.h / 2);
    t.settle(1);
    try std.testing.expectEqual(@as(usize, 0), a.marked.count());
}

test "nanomon itself, launchd and the kernel are never signaled" {
    try std.testing.expect(App.untouchable(0) and App.untouchable(1));
    if (builtin.os.tag != .windows) try std.testing.expect(App.untouchable(std.c.getpid()));
}

test "the graff bubble asks graff, shows its answer, and marks only what may be quit" {
    if (!@import("graff.zig").supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A graff that notes its arguments and directory, then answers.
    const script =
        \\#!/bin/sh
        \\echo "$@" > "$NOTE"
        \\pwd >> "$NOTE"
        \\echo "Safari Web Content and Mail are idle but large."
        \\echo "Quitting Mail frees 200 MB; launchd must stay."
        \\echo ""
        \\echo "KILL: 990003, 990001, 1"
        \\
    ;
    var dir_buf: [512]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    var path_buf: [600]u8 = undefined;
    const fake_path = try std.fmt.bufPrint(&path_buf, "{s}/graff", .{dir});
    var note_buf: [600]u8 = undefined;
    const note = try std.fmt.bufPrint(&note_buf, "{s}/note", .{dir});
    // The script reads where to note from its name's directory.
    const body = try std.mem.replaceOwned(u8, gpa, script, "$NOTE", note);
    defer gpa.free(body);
    try tmp.dir.writeFile(io, .{ .sub_path = "graff", .data = body, .flags = .{ .permissions = .fromMode(0o755) } });

    var a: App = .init(gpa, io);
    defer a.deinit();
    try t_mod.fake(&a);
    a.graff.program = fake_path;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(true) });
    defer t.deinit();
    a.dark = true;
    t.settle(1);
    // The bubble at the corner opens the panel.
    t.click(1100 - 18 - 23, 760 - 18 - 23);
    t.settle(1);
    try std.testing.expect(a.graff.open and t.hasText("What can I safely quit?"));
    try t.screenshot("/tmp/nanomon-graff-open.png");
    try t_mod.open(&t, "What can I safely quit?");
    var waited: f64 = 0;
    while (a.graff.state == .running and waited < 10) : (waited += 0.05) {
        nanoui.runFor(0.05);
        t.frame();
    }
    try std.testing.expectEqual(@import("graff.zig").State.done, a.graff.state);
    t.settle(1);
    try std.testing.expect(t.containsText("Quitting Mail frees 200 MB"));
    try std.testing.expect(!t.containsText("KILL:"));
    // Only Mail: launchd (1) and root's process are left out.
    try std.testing.expect(t.hasText("Mark 1 to quit"));
    try t.screenshot("/tmp/nanomon-graff-answer.png");
    // It was asked one-shot, its tools off, from a directory of its own,
    // which is gone now.
    var nb: [4096]u8 = undefined;
    const noted = try tmp.dir.readFile(io, "note", &nb);
    try std.testing.expect(std.mem.indexOf(u8, noted, "-p --no-local-tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, noted, "nanomon-graff-") != null);
    try std.testing.expect(std.mem.indexOf(u8, noted, "What can I safely quit?") != null);
    try t_mod.open(&t, "Mark 1 to quit");
    try std.testing.expect(a.marked.contains(990003) and a.marked.count() == 1);
    try std.testing.expectEqual(app_mod.Page.processes, a.page);
}

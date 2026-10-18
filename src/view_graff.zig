//! The graff bubble: a round amber button at the window's corner that
//! opens a small panel to ask graff about the machine ("What's slowing
//! my Mac down?", "Should I quit the 3 marked?"). graff is told the
//! system's figures and the busiest and largest processes, answers in a
//! few lines, and may name processes to quit; those can be marked with a
//! click, and quitting them is still the user's to do (graff.zig).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const memory = @import("view_memory.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

const panel_w = 380;
const button = 46;

const starters = [_][]const u8{ "What's slowing my Mac down?", "What can I safely quit?", "Why is memory use so high?" };

extern "c" fn getpid() c_int;

pub fn bubble(c: *ui.Context, a: *App, k: theme.Colors) void {
    const g = &a.graff;
    // Over the page, not in its way: only the panel and button take the
    // pointer. Above the Processes page's bar when it shows.
    const bar = a.page == .processes and (a.markedSummary().count > 0 or a.noticeText() != null);
    const layer = ui.div(c).absolute().sizeFull().column().itemsEnd().justifyEnd().gap(12).px(18).pb(if (bar) 18 + 51 else 18);
    defer layer.end();
    if (g.open) panel(c, a, k);
    ui.key(c, "graff-bubble");
    const d = ui.div(c).row().w(button).h(button).center().rounded(button / 2).bg(k.accent).shadow(.{ .color = .{ .a = 0.35 }, .blur = 14, .y = 4 }).control();
    defer d.end();
    const it = d.interaction();
    if (it.hovered) c.node(d.index).style.background = k.accent.mix(.{ .r = 1, .g = 1, .b = 1 }, 0.12);
    if (it.clicked) {
        g.open = !g.open;
        c.changed = true;
    }
    ui.icon(c, if (g.open) "xmark" else "sparkles", .{ .size = 18, .weight = .semibold, .color = k.on_picked });
    if (g.state == .running) c.frameIn(0.25);
}

fn panel(c: *ui.Context, a: *App, k: theme.Colors) void {
    const g = &a.graff;
    const p = ui.div(c).column().w(panel_w).gap(12).p(16).rounded(14).bg(k.page).border(k.border).shadowLg();
    defer p.end();
    _ = p.interaction();
    {
        const h = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer h.end();
        kit.chip(c, "sparkles", k.accent, 28, false);
        const t = ui.div(c).column().gap(1);
        ui.text(c, "graff", .{ .size = 14, .weight = .bold, .color = k.text });
        ui.text(c, "Ask about this Mac", .{ .size = 11, .color = k.secondary });
        t.end();
    }
    if (g.asked.items.len > 0 and g.state != .idle) said(c, k, g.asked.items);
    switch (g.state) {
        .idle => {
            ui.text(c, "graff sees the system's figures and the busiest processes, and can suggest what to quit. It can't run anything here: you decide.", .{ .size = 11.5, .color = k.secondary, .wrap = true });
            const marked = a.markedSummary().count;
            if (marked > 0) starter(c, a, k, c.print("Should I quit the {d} marked?", .{marked}));
            for (starters) |s| starter(c, a, k, s);
        },
        .running => {
            const dots = [_][]const u8{ "", ".", "..", "..." };
            const n: usize = @intFromFloat(@mod(c.time * 3, 4));
            ui.text(c, c.print("graff is looking{s}", .{dots[n]}), .{ .size = 12, .mono = true, .color = k.accent });
            if (ui.button(c, "Cancel", .{ .variant = .ghost, .size = 12 }).clicked) a.graff.cancel();
        },
        .done => answer(c, a, k),
        .failed => ui.text(c, g.failure, .{ .size = 12, .color = k.red, .wrap = true }),
    }
    if (g.state != .running) field(c, a, k);
}

/// The question asked, on the right, as a message.
fn said(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const r = ui.div(c).row().wFull().justifyEnd();
    defer r.end();
    const b = ui.div(c).column().maxW(panel_w - 80).px(12).py(7).rounded(12).bg(k.accent.alpha(0.16));
    defer b.end();
    ui.text(c, text, .{ .size = 12, .color = k.text, .wrap = true });
}

fn starter(c: *ui.Context, a: *App, k: theme.Colors, q: []const u8) void {
    ui.key(c, q);
    const d = ui.div(c).row().wFull().gap(8).itemsCenter().px(10).py(7).rounded(8).bg(k.card).border(k.border).hover(k.control).control();
    defer d.end();
    if (d.clicked()) ask(c, a, q);
    ui.icon(c, "arrow.right", .{ .size = 10, .color = k.accent });
    ui.text(c, q, .{ .size = 12, .color = k.text });
}

/// The answer, and the processes it suggests (only the user's, never
/// nanomon or the system's), with a button to mark them.
fn answer(c: *ui.Context, a: *App, k: theme.Colors) void {
    const g = &a.graff;
    {
        const s = ui.div(c).column().wFull().maxH(260).scrollY();
        defer s.end();
        ui.text(c, g.answer, .{ .size = 12.5, .color = k.text, .wrap = true });
    }
    var picks: [32]model.Process = undefined;
    var n: usize = 0;
    for (g.suggested.items) |pid| {
        const p = a.find(pid) orelse continue;
        if (p.uid != a.uid or App.untouchable(pid) or n == picks.len) continue;
        picks[n] = p;
        n += 1;
    }
    if (n == 0) return;
    const list = ui.div(c).column().wFull().gap(2).p(8).rounded(8).bg(k.card).border(k.border);
    defer list.end();
    for (picks[0..n]) |p| {
        ui.key(c, c.print("pick-{d}", .{p.pid}));
        const r = ui.div(c).row().wFull().gap(8).itemsCenter().h(22);
        defer r.end();
        memory.procName(c, a, k, p, 200);
        ui.spacer(c);
        var b: [32]u8 = undefined;
        ui.text(c, c.print("{s}", .{model.bytes(&b, p.memory)}), .{ .size = 11, .mono = true, .color = k.secondary });
    }
    if (ui.button(c, c.print("Mark {d} to quit", .{n}), .{ .variant = .primary, .size = 12, .icon = "checkmark", .width = .fill }).clicked) {
        for (picks[0..n]) |p| a.marked.put(a.sampler.gpa, p.pid, {}) catch {};
        a.page = .processes;
        a.graff.open = false;
    }
}

/// Ask anything: Return sends.
fn field(c: *ui.Context, a: *App, k: theme.Colors) void {
    const g = &a.graff;
    const r = ui.div(c).row().wFull().h(34).gap(6).itemsCenter().pl(12).pr(4).rounded(17).bg(k.card).border(k.border);
    defer r.end();
    const res = ui.textField(c, &g.question, .{ .placeholder = "Ask graff…", .width = .fill, .size = 12.5, .bare = true });
    const q = std.mem.trim(u8, g.question.text(), " ");
    ui.key(c, "graff-send");
    const send = ui.div(c).row().w(26).h(26).center().rounded(13).bg(if (q.len > 0) k.accent else k.control).control();
    defer send.end();
    const clicked = send.clicked();
    ui.icon(c, "arrow.up", .{ .size = 11, .weight = .bold, .color = if (q.len > 0) k.on_picked else k.tertiary });
    if ((res.submitted or clicked) and q.len > 0) {
        const asked = c.print("{s}", .{q});
        g.question.set("");
        ask(c, a, asked);
    }
}

/// "Should I quit these?", from the Processes page's bar.
pub fn askAboutMarked(c: *ui.Context, a: *App) void {
    a.graff.open = true;
    ask(c, a, c.print("Should I quit the {d} marked?", .{a.markedSummary().count}));
}

fn ask(c: *ui.Context, a: *App, question: []const u8) void {
    a.graff.ask(a.sampler.gpa, a.sampler.io, prompt(c, a, question), question, c.time);
    c.changed = true;
}

/// The question with the machine around it, and how to answer.
pub fn prompt(c: *ui.Context, a: *App, question: []const u8) []const u8 {
    const s = &a.sampler;
    const sy = s.system;
    const info = s.info;
    var out: std.ArrayList(u8) = .empty;
    const w = c.alloc();
    var b: [4][32]u8 = undefined;
    const me: i32 = if (comptime builtin.os.tag != .windows) getpid() else 0;
    const user = s.user(a.uid);
    out.print(w,
        \\You are graff, answering inside nanomon, an activity monitor, for the person at this computer ({s}).
        \\Be brief: at most 6 short lines of plain text, no tables, no headings.
        \\Machine: {s}, {d} cores, {s} memory, {s}.
        \\Now: CPU {d:.0}% (user {d:.0}%, system {d:.0}%), load {d:.2} {d:.2} {d:.2}; memory {s} used, pressure {d:.0}%; swap {s}; disk {s}; network {s}.
        \\
    , .{ user, info.chip, sy.cores, model.bytes(&b[0], sy.mem_total), info.os, sy.cpuBusy(), sy.cpu_user, sy.cpu_system, sy.load[0], sy.load[1], sy.load[2], model.bytes(&b[1], sy.memUsed()), sy.pressure, model.bytes(&b[2], sy.swap_used), model.rate(&b[3], sy.read_sec + sy.written_sec), model.rate(&b[0], sy.net_in_sec + sy.net_out_sec) }) catch {};
    var best: [12]model.Process = undefined;
    out.appendSlice(w, "Busiest processes (pid, name, user, % of one core, memory):\n") catch {};
    for (best[0..memory.largest(a, &best, .cpu)]) |p| line(&out, w, p);
    out.appendSlice(w, "Largest by memory:\n") catch {};
    for (best[0..memory.largest(a, &best, .memory)]) |p| line(&out, w, p);
    if (a.marked.count() > 0) {
        out.appendSlice(w, "Marked by the person to quit:\n") catch {};
        for (a.marked.keys()) |pid| if (a.find(pid)) |p| line(&out, w, p);
    }
    out.print(w,
        \\The person asks: {s}
        \\After your answer, end with one line exactly like `KILL: 123, 456` naming processes owned by {s} that are safe to quit for this, or `KILL: none`. Never name system processes, other users' processes, WindowServer, launchd, kernel_task, or nanomon itself (pid {d}).
    , .{ question, user, me }) catch {};
    return out.items;
}

fn line(out: *std.ArrayList(u8), w: std.mem.Allocator, p: model.Process) void {
    var b: [32]u8 = undefined;
    out.print(w, "{d} {s} {s} {d:.1}% {s}\n", .{ p.pid, p.name, p.user, p.cpu, model.bytes(&b, p.memory) }) catch {};
}

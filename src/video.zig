//! A 30-second video of nanoui, drawn by nanoui: the scenes
//! (video_scenes.zig) run in a Tester, offscreen, 30 frames a second, and
//! each frame's pixels go to standard output for ffmpeg. A script moves
//! the pointer and clicks, as a person would, through the Tester alone:
//! no window shows, and nothing reaches the screen, the mouse or graff
//! (its answer is written in).
//!
//!     zig build video && zig-out/bin/nanomon-video | ffmpeg -f rawvideo \
//!       -pix_fmt bgra -s 1920x1080 -r 30 -i - -pix_fmt yuv420p out.mp4
//!     zig-out/bin/nanomon-video --still=16.5:/tmp/frame.png   # one frame
//!     zig-out/bin/nanomon-video --cues    # when clicks and cuts come
//!     zig-out/bin/nanomon-video --dark    # Codegraff Dark around the windows
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const side = @import("view_side.zig");
const data = @import("video_data.zig");
const scenes = @import("video_scenes.zig");
const win = scenes.win;
const Director = scenes.Director;

const fps = 30;
const scale = 1.5;

const Target = union(enum) {
    point: [2]f32,
    /// The middle of a text drawn.
    text: []const u8,
    /// The check box on the row of a process.
    check: []const u8,
    /// graff's round button.
    bubble,
};

const Act = enum { none, click, ask };

const Move = struct { at: f32, dur: f32, to: Target, act: Act = .none };

const question = "Should I quit the 3 marked?";

// Times from each scene's start: the counter's, nanomon's.
const code = scenes.at.code;
const mon = scenes.at.mon;

const moves = [_]Move{
    .{ .at = code + 1.7, .dur = 0.8, .to = .{ .text = "Increment" }, .act = .click },
    .{ .at = code + 2.85, .dur = 0.15, .to = .{ .text = "Increment" }, .act = .click },
    .{ .at = code + 3.35, .dur = 0.15, .to = .{ .text = "Increment" }, .act = .click },
    .{ .at = code + 3.85, .dur = 0.15, .to = .{ .text = "Increment" }, .act = .click },
    .{ .at = code + 4.4, .dur = 0.6, .to = .{ .point = .{ 1180, 620 } } },
    .{ .at = mon + 1.4, .dur = 0.8, .to = .{ .text = "Processes" }, .act = .click },
    .{ .at = mon + 3.0, .dur = 0.6, .to = .{ .check = "Music" }, .act = .click },
    .{ .at = mon + 3.9, .dur = 0.35, .to = .{ .check = "Preview" }, .act = .click },
    .{ .at = mon + 4.5, .dur = 0.3, .to = .{ .check = "Notes" }, .act = .click },
    .{ .at = mon + 5.2, .dur = 0.7, .to = .bubble, .act = .click },
    .{ .at = mon + 6.4, .dur = 0.5, .to = .{ .text = question }, .act = .ask },
    .{ .at = mon + 9.3, .dur = 0.7, .to = .{ .text = "Mark 4 to quit" }, .act = .click },
    .{ .at = mon + 10.4, .dur = 0.8, .to = .{ .point = .{ 1240, 700 } } },
};

/// When graff's answer comes.
const answer_at = mon + 8.4;
const answer =
    \\All three are idle: Music, Preview and Notes hold 2.1 GB between them, and quitting them loses nothing open.
    \\The bigger saving is one Safari tab's Web Content at 3.4 GB. Quit it too if you don't need that page.
;

/// When the pointer shows.
const shown = [_][2]f32{ .{ code + 1.3, code + 5.1 }, .{ mon + 1.1, mon + 11.3 } };

/// The times sounds go with, for the soundtrack (`--cues`): each click,
/// graff's answer, and each cut from one scene to the next.
fn cues(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const o = &w.interface;
    for (moves) |m| if (m.act != .none) try o.print("click {d:.3}\n", .{m.at + m.dur});
    try o.print("answer {d:.3}\n", .{answer_at});
    const at = scenes.at;
    for ([_]f32{ at.code, at.mon, at.bench, at.size, at.end }) |cut| try o.print("cut {d:.3}\n", .{cut});
    try o.flush();
}

const Script = struct {
    next: usize = 0,
    /// The move under way: from where, to where.
    started: ?usize = null,
    start: [2]f32 = .{ 0, 0 },
    to: [2]f32 = .{ 0, 0 },
    up: bool = false,
    answered: bool = false,
    pushed: f32 = 0,
    rnd: std.Random.DefaultPrng = .init(11),

    /// Moves time on to `now`: samples, the pointer, clicks, graff.
    fn step(s: *Script, t: *ui.Tester, d: *Director, now: f32) void {
        d.now = now;
        const a = d.a;
        if (s.up) {
            t.ctx.pointerUp();
            s.up = false;
        }
        while (now - s.pushed >= 0.5) {
            s.pushed += 0.5;
            data.push(a, s.rnd.random());
        }
        d.cursor_alpha = 0;
        for (shown) |w| {
            const v = @min(scenes.clamp01((now - w[0]) / 0.3), scenes.clamp01((w[1] - now) / 0.3));
            d.cursor_alpha = @max(d.cursor_alpha, v);
            if (now >= w[0] and now < w[0] + 0.5 / @as(f32, fps)) d.cursor = .{ 1120, 660 };
        }
        // The current move, started when its time comes.
        while (s.next < moves.len) {
            const m = moves[s.next];
            if (now < m.at) break;
            if (s.started != s.next) {
                s.started = s.next;
                s.start = d.cursor;
                s.to = resolve(t, d, m.to) orelse d.cursor;
            }
            const p = scenes.clamp01((now - m.at) / m.dur);
            const e = smooth(p);
            d.cursor = .{ s.start[0] + (s.to[0] - s.start[0]) * e, s.start[1] + (s.to[1] - s.start[1]) * e };
            if (p < 1) break;
            switch (m.act) {
                .none => {},
                .click => s.click(t, d, now),
                .ask => {
                    d.pulse = now;
                    ask(a);
                },
            }
            s.next += 1;
        }
        if (!s.answered and now >= answer_at) {
            s.answered = true;
            a.graff.state = .done;
            a.graff.answer = answer;
            a.graff.suggested.appendSlice(a.sampler.gpa, &.{ data.music, data.preview, data.notes, data.web }) catch {};
        }
        t.ctx.input.mouse = if (d.cursor_alpha > 0) .{ .x = d.cursor[0], .y = d.cursor[1] } else .{ .x = -100, .y = -100 };
        t.ctx.updateHot();
    }

    fn click(s: *Script, t: *ui.Tester, d: *Director, now: f32) void {
        t.ctx.input.mouse = .{ .x = d.cursor[0], .y = d.cursor[1] };
        t.ctx.updateHot();
        t.ctx.input.click_count = 1;
        t.ctx.pointerDown();
        s.up = true;
        d.pulse = now;
    }
};

/// The question asked, as if graff had been: nothing is run.
fn ask(a: *App) void {
    const g = &a.graff;
    g.open = true;
    g.state = .running;
    g.asked.clearRetainingCapacity();
    g.asked.appendSlice(a.sampler.gpa, question) catch {};
}

fn smooth(p: f32) f32 {
    return p * p * (3 - 2 * p);
}

fn resolve(t: *ui.Tester, d: *Director, to: Target) ?[2]f32 {
    switch (to) {
        .point => |p| return p,
        .text => |s| {
            const r = t.findText(s) orelse return missing(s);
            return .{ r.x + r.w / 2, r.y + r.h / 2 };
        },
        .check => |s| {
            const r = t.findText(s) orelse return missing(s);
            return .{ win.x + side.width + 1 + 15, r.y + r.h / 2 };
        },
        .bubble => {
            const a = d.a;
            const bar: f32 = if (a.page == .processes and a.marked.count() > 0) 51 else 0;
            return .{ win.x + win.w - 18 - 23, win.y + win.h - 18 - bar - 23 };
        },
    }
}

fn missing(s: []const u8) ?[2]f32 {
    std.debug.print("video: no \"{s}\" on screen\n", .{s});
    return null;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var stills: std.ArrayList(struct { frame: usize, path: []const u8 }) = .empty;
    defer stills.deinit(gpa);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var dark = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--cues")) return cues(io);
        if (std.mem.eql(u8, arg, "--dark")) {
            dark = true;
            continue;
        }
        const prefix = "--still=";
        if (!std.mem.startsWith(u8, arg, prefix)) return error.UnknownArgument;
        const v = arg[prefix.len..];
        const colon = std.mem.indexOfScalar(u8, v, ':') orelse return error.BadStill;
        const secs = try std.fmt.parseFloat(f32, v[0..colon]);
        try stills.append(gpa, .{ .frame = @intFromFloat(@round(secs * fps)), .path = v[colon + 1 ..] });
    }

    var a: App = .init(gpa, io);
    defer a.deinit();
    try data.fill(&a);
    var d: Director = .{ .a = &a, .dark = dark };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&d, Director.view), .{ .width = scenes.width, .height = scenes.height, .scale = scale, .theme = theme.ui(false) });
    defer t.deinit();
    t.dt = 1.0 / @as(f32, fps);
    t.time = 0;

    var last: usize = @intFromFloat(scenes.at.done * fps);
    if (stills.items.len > 0) {
        last = 0;
        for (stills.items) |s| last = @max(last, s.frame + 1);
    }
    var script: Script = .{};
    const out = std.Io.File.stdout();
    for (0..last) |i| {
        script.step(&t, &d, @as(f32, @floatFromInt(i)) / fps);
        t.frame();
        if (stills.items.len > 0) {
            for (stills.items) |s| if (s.frame == i) try t.screenshot(s.path);
            continue;
        }
        const pixels = try t.render(gpa);
        defer pixels.deinit(gpa);
        try out.writeStreamingAll(io, pixels.bytes);
    }
}

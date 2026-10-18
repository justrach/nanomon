//! The Disk and Network pages: bytes a second across the range, read and
//! written (in and out) stacked, scaled to the busiest moment; the totals
//! since boot; and for the disk, the processes that wrote the most.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const view = @import("view.zig");
const memory = @import("view_memory.zig");
const App = @import("app.zig").App;

pub fn disk(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    var b: [32]u8 = undefined;
    {
        const h = kit.header(c, k, "Disk", c.print("{s} now", .{model.rate(&b, sy.read_sec + sy.written_sec)}));
        defer h.end();
        kit.ranges(c, a, k);
    }
    const body = view.body(c);
    defer body.end();
    diskLoad(c, a, k, 150);
    const r = ui.div(c).row().wFull().gap(14).itemsStart();
    defer r.end();
    {
        const d = kit.card(c, k).w(300).gap(4);
        defer d.end();
        {
            const t = kit.title(c, "internaldrive", "Since Boot", k.orange);
            defer t.end();
        }
        const gap = ui.div(c).row().h(6);
        gap.end();
        var b2: [32]u8 = undefined;
        kit.line(c, k, "Data read", c.print("{s}", .{model.bytes(&b2, sy.read_bytes)}), k.blue);
        kit.line(c, k, "Data written", c.print("{s}", .{model.bytes(&b2, sy.written_bytes)}), k.orange);
        kit.line(c, k, "Reads in", c.print("{s}", .{model.count(&b2, sy.reads)}), null);
        kit.line(c, k, "Writes out", c.print("{s}", .{model.count(&b2, sy.writes)}), null);
        kit.line(c, k, "Reads in/sec", c.print("{d:.0}", .{sy.reads_sec}), null);
        kit.line(c, k, "Writes out/sec", c.print("{d:.0}", .{sy.writes_sec}), null);
    }
    writers(c, a, k);
}

/// The Disk Activity card, its graph `h` high.
pub fn diskLoad(c: *ui.Context, a: *App, k: theme.Colors, h: f32) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = kit.card(c, k);
    defer d.end();
    {
        const t = kit.title(c, "internaldrive", "Disk Activity", k.orange);
        defer t.end();
        if (!kit.readout(c, k, a, .disk, &.{ "Read", "Written" }, kit.perSecond))
            kit.legend(c, k, &.{ .{ "Read", k.blue }, .{ "Written", k.orange } });
    }
    var b: [3][32]u8 = undefined;
    {
        const r = ui.div(c).row().wFull().gap(16).itemsStart();
        defer r.end();
        rateBig(c, k, "Now", sy.read_sec + sy.written_sec);
        kit.stat(c, k, "Read", c.print("{s}", .{model.rate(&b[0], sy.read_sec)}), "");
        kit.stat(c, k, "Written", c.print("{s}", .{model.rate(&b[1], sy.written_sec)}), "");
        kit.stat(c, k, "Operations", c.print("{d:.0}/s", .{sy.reads_sec + sy.writes_sec}), "");
        const n = a.range.samples();
        const cpu = @import("view_cpu.zig");
        kit.stat(c, k, "Average", c.print("{s}", .{model.rate(&b[2], cpu.mean(s.read_history.slice(), n) + cpu.mean(s.write_history.slice(), n))}), c.print("over {s}", .{a.range.title()}));
    }
    kit.dots(c, k, a, &.{ .{ .values = s.read_history.slice(), .color = k.blue }, .{ .values = s.write_history.slice(), .color = k.orange } }, null, h, true, .disk);
}

/// A rate, large: "7.28" over "MB/s".
fn rateBig(c: *ui.Context, k: theme.Colors, label: []const u8, per_s: f32) void {
    var b: [32]u8 = undefined;
    const r = model.rate(&b, per_s);
    const space = std.mem.lastIndexOfScalar(u8, r, ' ') orelse r.len;
    kit.big(c, k, label, c.print("{s}", .{r[0..space]}), c.print("{s}", .{std.mem.trim(u8, r[space..], " ")}));
}

/// The processes that have written the most (that nanomon may read).
fn writers(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = kit.card(c, k).grow().w(0).gap(6);
    defer d.end();
    {
        const t = kit.title(c, "square.and.pencil", "Most Written", k.orange);
        defer t.end();
    }
    var best: [8]model.Process = undefined;
    const n = memory.largest(a, &best, .written);
    const most: f32 = if (n > 0) @floatFromInt(@max(1, best[0].disk_written)) else 1;
    var b: [32]u8 = undefined;
    for (best[0..n]) |p| {
        ui.key(c, c.print("w-{d}", .{p.pid}));
        const r = ui.div(c).row().wFull().gap(10).itemsCenter().h(22);
        defer r.end();
        memory.procName(c, a, k, p, 170);
        kit.bar(c, k, @as(f32, @floatFromInt(p.disk_written)) / most, k.orange);
        const v = ui.div(c).row().w(72).justifyEnd();
        ui.text(c, c.print("{s}", .{model.bytes(&b, p.disk_written)}), .{ .size = 11.5, .weight = .semibold, .color = k.text });
        v.end();
    }
}

pub fn network(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    var b: [32]u8 = undefined;
    {
        const h = kit.header(c, k, "Network", c.print("{s} now", .{model.rate(&b, sy.net_in_sec + sy.net_out_sec)}));
        defer h.end();
        kit.ranges(c, a, k);
    }
    const body = view.body(c);
    defer body.end();
    netLoad(c, a, k, 150);
    const d = kit.card(c, k).gap(4);
    defer d.end();
    {
        const t = kit.title(c, "network", "Since Boot", k.teal);
        defer t.end();
    }
    const gap = ui.div(c).row().h(6);
    gap.end();
    kit.line(c, k, "Data received", c.print("{s}", .{model.bytes(&b, sy.net_in)}), k.teal);
    kit.line(c, k, "Data sent", c.print("{s}", .{model.bytes(&b, sy.net_out)}), k.blue);
    const s = &a.sampler;
    var most: [2]f32 = .{ 0, 0 };
    for (s.in_history.slice()) |v| most[0] = @max(most[0], v);
    for (s.out_history.slice()) |v| most[1] = @max(most[1], v);
    kit.line(c, k, "Fastest in, this hour", c.print("{s}", .{model.rate(&b, most[0])}), null);
    kit.line(c, k, "Fastest out, this hour", c.print("{s}", .{model.rate(&b, most[1])}), null);
}

/// The Network Activity card, its graph `h` high.
pub fn netLoad(c: *ui.Context, a: *App, k: theme.Colors, h: f32) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = kit.card(c, k);
    defer d.end();
    {
        const t = kit.title(c, "network", "Network Activity", k.teal);
        defer t.end();
        if (!kit.readout(c, k, a, .network, &.{ "In", "Out" }, kit.perSecond))
            kit.legend(c, k, &.{ .{ "In", k.teal }, .{ "Out", k.blue } });
    }
    var b: [3][32]u8 = undefined;
    {
        const r = ui.div(c).row().wFull().gap(16).itemsStart();
        defer r.end();
        rateBig(c, k, "Now", sy.net_in_sec + sy.net_out_sec);
        kit.stat(c, k, "In", c.print("{s}", .{model.rate(&b[0], sy.net_in_sec)}), "");
        kit.stat(c, k, "Out", c.print("{s}", .{model.rate(&b[1], sy.net_out_sec)}), "");
        const n = a.range.samples();
        const cpu = @import("view_cpu.zig");
        kit.stat(c, k, "Average", c.print("{s}", .{model.rate(&b[2], cpu.mean(s.in_history.slice(), n) + cpu.mean(s.out_history.slice(), n))}), c.print("over {s}", .{a.range.title()}));
    }
    kit.dots(c, k, a, &.{ .{ .values = s.in_history.slice(), .color = k.teal }, .{ .values = s.out_history.slice(), .color = k.blue } }, null, h, true, .network);
}

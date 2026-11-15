//! Bounded, opt-in tail diagnostics. Capture in memory; print AFTER measurement.
//! Process CPU/resource counters include all process threads, not only the UI.
const std = @import("std");
const builtin = @import("builtin");
pub const budget_ms = 1000.0 / 120.0;

pub const Usage = struct {
    cpu_ms: f64 = 0,
    minor_faults: isize = 0,
    major_faults: isize = 0,
    voluntary_switches: isize = 0,
    involuntary_switches: isize = 0,

    pub fn read() Usage {
        if (comptime builtin.os.tag != .macos) return .{};
        const r = std.posix.getrusage(0);
        return .{
            .cpu_ms = seconds(r.utime) * 1000 + seconds(r.stime) * 1000,
            .minor_faults = r.minflt,
            .major_faults = r.majflt,
            .voluntary_switches = r.nvcsw,
            .involuntary_switches = r.nivcsw,
        };
    }

    fn seconds(tv: anytype) f64 {
        return @as(f64, @floatFromInt(tv.sec)) + @as(f64, @floatFromInt(tv.usec)) / 1e6;
    }

    pub fn delta(after: Usage, before: Usage) Usage {
        var result: Usage = undefined;
        inline for (@typeInfo(Usage).@"struct".field_names) |name|
            @field(result, name) = @field(after, name) - @field(before, name);
        return result;
    }
};

pub const Row = struct {
    frame: usize = 0,
    sample_boundary: bool = false,
    paced: bool = false,
    start_late_ms: f64 = 0,
    finish_late_ms: f64 = 0,
    deadline_missed: bool = false,
    skipped_slots: usize = 0,
    frame_ms: f64 = 0,
    render_ms: f64 = 0,
    wall_ms: f64 = 0,
    encode_ms: f64 = 0,
    gpu_ms: f64 = 0,
    build_ms: f64 = 0,
    layout_ms: f64 = 0,
    paint_ms: f64 = 0,
    frame_usage: Usage = .{},
    render_usage: Usage = .{},

    pub fn residual(r: Row) f64 {
        // A residual, NOT a direct measurement of GPU queue time: includes
        // completion wait, host wakeup, pool teardown and timing overhead.
        return @max(0, r.render_ms - r.encode_ms - r.gpu_ms);
    }

    pub fn gap(r: Row) f64 {
        return @max(0, r.wall_ms - r.frame_ms - r.render_ms);
    }

    pub fn stage(r: Row) []const u8 {
        const rest = r.residual();
        if (r.gap() > @max(r.frame_ms, @max(rest, @max(r.encode_ms, r.gpu_ms)))) return "instrumentation_gap";
        if (r.frame_ms >= @max(rest, @max(r.encode_ms, r.gpu_ms))) return "frame";
        if (r.encode_ms >= @max(rest, r.gpu_ms)) return "encode";
        if (r.gpu_ms >= rest) return "gpu";
        return "render_residual";
    }
};

pub const Collector = struct {
    pub const capacity = 32;
    rows: [capacity]Row = undefined,
    len: usize = 0,
    missed: usize = 0,
    worst: ?Row = null,
    worst_deadline: ?Row = null,

    pub fn observe(c: *Collector, row: Row) void {
        if (c.worst == null or row.wall_ms > c.worst.?.wall_ms) c.worst = row;
        if (row.deadline_missed and (c.worst_deadline == null or row.finish_late_ms > c.worst_deadline.?.finish_late_ms)) c.worst_deadline = row;
        if (row.wall_ms <= budget_ms and !row.deadline_missed) return;
        c.missed += 1;
        if (c.len < capacity) {
            c.rows[c.len] = row;
            c.len += 1;
        }
    }

    pub fn report(c: *const Collector, page: []const u8, run: usize, cached: bool) void {
        const worst = c.worst orelse return;
        var found = false;
        for (c.rows[0..c.len]) |row| {
            const peak = row.frame == worst.frame;
            found = found or peak;
            emit(row, page, run, cached, peak);
        }
        // Preserve the maximum even if it wasn't among the first 32 misses.
        if (!found) emit(worst, page, run, cached, true);
        if (c.worst_deadline) |late| {
            var seen = late.frame == worst.frame;
            for (c.rows[0..c.len]) |row| seen = seen or row.frame == late.frame;
            if (!seen) emit(late, page, run, cached, false);
        }
    }

    fn emit(r: Row, page: []const u8, run: usize, cached: bool, worst: bool) void {
        const usage = r.render_usage;
        std.debug.print("{{\"kind\":\"frame_trace\",\"page\":\"{s}\",\"run\":{d},\"cached\":{},\"frame\":{d},\"sample_boundary\":{},\"worst\":{},\"paced\":{},\"start_late_ms\":{d:.4},\"finish_late_ms\":{d:.4},\"deadline_missed\":{},\"work_over_budget\":{},\"skipped_slots\":{d},\"stage\":\"{s}\",\"wall_ms\":{d:.4},\"frame_ms\":{d:.4},\"render_ms\":{d:.4},\"encode_ms\":{d:.4},\"gpu_ms\":{d:.4},\"render_residual_ms\":{d:.4},\"instrumentation_gap_ms\":{d:.4},\"build_ms\":{d:.4},\"layout_ms\":{d:.4},\"paint_ms\":{d:.4},\"frame_process_cpu_ms\":{d:.4},\"render_process_cpu_ms\":{d:.4},\"minor_faults\":{d},\"major_faults\":{d},\"voluntary_switches\":{d},\"involuntary_switches\":{d}}}\n", .{
            page,         run,                                             cached,                                          r.frame,                                                     r.sample_boundary,                                               worst,
            r.paced,      r.start_late_ms,                                 r.finish_late_ms,                                r.deadline_missed,                                           r.wall_ms > budget_ms,                                           r.skipped_slots,
            r.stage(),    r.wall_ms,                                       r.frame_ms,                                      r.render_ms,                                                 r.encode_ms,                                                     r.gpu_ms,
            r.residual(), r.gap(),                                         r.build_ms,                                      r.layout_ms,                                                 r.paint_ms,                                                      r.frame_usage.cpu_ms,
            usage.cpu_ms, r.frame_usage.minor_faults + usage.minor_faults, r.frame_usage.major_faults + usage.major_faults, r.frame_usage.voluntary_switches + usage.voluntary_switches, r.frame_usage.involuntary_switches + usage.involuntary_switches,
        });
    }
};

test "tail capture is bounded, counts all misses, and retains the true maximum" {
    var c: Collector = .{};
    c.observe(.{ .frame = 0, .wall_ms = budget_ms });
    try std.testing.expectEqual(0, c.missed);
    for (1..101) |i| c.observe(.{ .frame = i, .wall_ms = 9 + @as(f64, @floatFromInt(i)) });
    try std.testing.expectEqual(100, c.missed);
    try std.testing.expectEqual(Collector.capacity, c.len);
    try std.testing.expectEqual(100, c.worst.?.frame);
}

test "cheap deadline misses are captured and their true latest finish survives the cap" {
    var c: Collector = .{};
    c.observe(.{ .frame = 0, .wall_ms = 2 });
    for (1..100) |i| c.observe(.{
        .frame = i,
        .wall_ms = 1,
        .deadline_missed = true,
        .finish_late_ms = @floatFromInt(i),
    });
    try std.testing.expectEqual(99, c.missed);
    try std.testing.expectEqual(Collector.capacity, c.len);
    try std.testing.expectEqual(0, c.worst.?.frame);
    try std.testing.expectEqual(99, c.worst_deadline.?.frame);
}

test "trace preserves wall versus process CPU distinction and labels only observed stages" {
    const delta = Usage.delta(.{ .cpu_ms = 21, .minor_faults = 9 }, .{ .cpu_ms = 20, .minor_faults = 7 });
    try std.testing.expectEqual(1, delta.cpu_ms);
    try std.testing.expectEqual(2, delta.minor_faults);
    const wait: Row = .{ .wall_ms = 20, .frame_ms = 0.2, .render_ms = 19.8, .encode_ms = 0.02, .gpu_ms = 0.3 };
    try std.testing.expectEqualStrings("render_residual", wait.stage());
    try std.testing.expectEqualStrings("gpu", (Row{ .render_ms = 10, .gpu_ms = 9 }).stage());
    try std.testing.expectEqualStrings("encode", (Row{ .render_ms = 10, .encode_ms = 9 }).stage());
    try std.testing.expectEqualStrings("frame", (Row{ .frame_ms = 9, .render_ms = 1 }).stage());
    try std.testing.expectEqual(0, (Row{ .render_ms = 0.1, .gpu_ms = 0.2 }).residual());
    try std.testing.expectEqualStrings("instrumentation_gap", (Row{ .wall_ms = 20, .frame_ms = 1, .render_ms = 1 }).stage());
}

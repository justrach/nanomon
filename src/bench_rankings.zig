//! Isolate ranking work from GPU completion and OS scheduling latency.
const std = @import("std");
const ui = @import("nanoui").ui;
const model = @import("model.zig");
const top = @import("top_processes.zig");

pub fn run(gpa: std.mem.Allocator) !void {
    const procs = try gpa.alloc(model.Process, 3000);
    defer gpa.free(procs);
    for (procs, 0..) |*p, i| p.* = .{
        .pid = @intCast(990000 + i),
        .ppid = 1,
        .uid = 501,
        .name = "Benchmark",
        .user = "benchmark",
        .known = i % 17 != 0,
        .cpu = @floatFromInt((i * 37) % 101),
        .memory = ((i * 73) % 3000) * (1 << 20),
        .disk_written = ((i * 41) % 3000) * 1024,
    };
    for (std.enums.values(top.By)) |by| {
        var before: [7]f64 = undefined;
        var after: [7]f64 = undefined;
        // Alternate ordering across repetitions to avoid always warming one side.
        for (0..7) |rep| {
            if (rep % 2 == 0) {
                before[rep] = measure(procs, by, false);
                after[rep] = measure(procs, by, true);
            } else {
                after[rep] = measure(procs, by, true);
                before[rep] = measure(procs, by, false);
            }
        }
        std.mem.sort(f64, &before, {}, std.sort.asc(f64));
        std.mem.sort(f64, &after, {}, std.sort.asc(f64));
        std.debug.print("{{\"ranking\":\"{s}\",\"uncached_us\":{d:.4},\"cached_us\":{d:.4},\"speedup\":{d:.2}}}\n", .{
            @tagName(by), before[3], after[3], before[3] / after[3],
        });
    }
}

fn measure(procs: []const model.Process, by: top.By, cached: bool) f64 {
    var cache: top.Cache = .{};
    var out: [8]model.Process = undefined;
    const count = 24000;
    const begin = ui.clock.now();
    for (0..count) |i| {
        // Same 120 Hz / 2-second sample lifetime as the UI. Include cold misses.
        if (i % 240 == 0) cache.invalidate();
        const n = if (cached) cache.largest(procs, &out, by) else top.select(procs, &out, by);
        std.mem.doNotOptimizeAway(out[0..n]);
    }
    return (ui.clock.now() - begin) * 1e6 / count;
}

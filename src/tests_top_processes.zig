//! Differential and lifecycle tests for top-K memoization. No native sampling.
const std = @import("std");
const model = @import("model.zig");
const top = @import("top_processes.zig");
const App = @import("app.zig").App;
const expect = std.testing.expect;

fn same(a: []const model.Process, b: []const model.Process) !void {
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        inline for (@typeInfo(model.Process).@"struct".field_names) |field| {
            if (comptime std.mem.eql(u8, field, "cpu")) {
                try std.testing.expectEqual(@as(u32, @bitCast(x.cpu)), @as(u32, @bitCast(y.cpu)));
            } else try std.testing.expectEqualDeep(@field(x, field), @field(y, field));
        }
    }
}

// Kept independent from the production selector to catch accidental changes
// to the original insertion/comparison/tie rules, not just cache plumbing.
fn reference(source: []const model.Process, out: []model.Process, by: top.By) usize {
    var n: usize = 0;
    for (source) |p| {
        if (!p.known) continue;
        const v = metric(p, by);
        if (v <= 0) continue;
        var at = n;
        while (at > 0 and metric(out[at - 1], by) < v) : (at -= 1) {}
        if (at >= out.len) continue;
        var j = @min(n, out.len - 1);
        while (j > at) : (j -= 1) out[j] = out[j - 1];
        out[at] = p;
        n = @min(n + 1, out.len);
    }
    return n;
}

fn metric(p: model.Process, by: top.By) f64 {
    return switch (by) {
        .cpu => p.cpu,
        .memory => @floatFromInt(p.memory),
        .written => if (p.known and !p.from_ps) @floatFromInt(p.disk_written) else 0,
    };
}

test "top-K cache matches original for all keys, capacities, ties and IEEE values" {
    var rng: std.Random.DefaultPrng = .init(0x120f005);
    const random = rng.random();
    var procs: [193]model.Process = undefined;
    var cache: top.Cache = .{};
    for (0..40) |round| {
        for (&procs, 0..) |*p, i| p.* = .{
            .pid = @intCast(990000 + i),
            .ppid = 1,
            .uid = @intCast(i % 3),
            .name = "fake",
            .user = "test",
            .bundle = "/fake/App.app",
            .cpu = switch (i % 13) {
                0 => std.math.nan(f32),
                1 => std.math.inf(f32),
                2 => -std.math.inf(f32),
                3 => -0.0,
                4 => 0,
                5 => -1,
                else => @floatFromInt(random.int(u8) % 17),
            },
            .known = i % 11 != 0,
            .from_ps = i % 7 == 0,
            .memory = if (i % 2 == 0) std.math.maxInt(u64) - i else random.int(u64),
            .disk_written = random.int(u64),
            .cpu_time_ns = i,
            .threads = @intCast(i),
        };
        cache.invalidate();
        const source = procs[0..@min(procs.len, round * 7)];
        for (std.enums.values(top.By)) |by| {
            for ([_]usize{ 0, 1, 7, 8, 12, 13, 3, 8, 0 }) |capacity| {
                var wanted: [13]model.Process = undefined;
                var actual: [13]model.Process = undefined;
                const n = reference(source, wanted[0..capacity], by);
                for (0..3) |_| {
                    const got = cache.largest(source, actual[0..capacity], by);
                    try same(wanted[0..n], actual[0..got]);
                }
            }
        }
    }
}

test "App invalidates top-K for mutation, reorder, paused dirty and late refill" {
    var a: App = .init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    try @import("tests.zig").fake(&a);
    _ = a.tick(0);
    var out: [8]model.Process = undefined;
    var wanted: [8]model.Process = undefined;
    const largest = @import("view_memory.zig").largest;
    for (0..5) |step| {
        // Change a value without reallocating the source: pointer/length caches
        // would be stale. Names are copied too; no stale borrowed strings.
        for (a.sampler.procs.items) |*p| {
            p.cpu = @floatFromInt(100 + step * 10);
            p.name = if (step % 2 == 0) "new name" else "changed again";
            p.memory += 1 << 20;
            p.disk_written += 1024;
        }
        a.sortBy(if (step % 2 == 0) .name else .pid);
        a.paused = step % 2 == 0;
        a.fresh = step == 3;
        _ = a.tick(@floatFromInt(step));
        for (std.enums.values(top.By)) |by| {
            const n = reference(a.sampler.procs.items, &wanted, by);
            for (0..3) |_| {
                const got = largest(&a, &out, by);
                try same(wanted[0..n], out[0..got]);
            }
        }
    }
    a.sampler.procs.clearRetainingCapacity();
    a.dirty = true;
    _ = a.tick(10);
    try expect(largest(&a, &out, .cpu) == 0);
}

test "cached rankings preserve rendered pages, resize and graph hover exactly" {
    const nanoui = @import("nanoui");
    const ui = nanoui.ui;
    const theme = @import("theme.zig");
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try @import("tests.zig").fake(&a);
    for (a.sampler.procs.items) |*p| p.bundle = "";
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, @import("view.zig").view), .{
        .width = 1100,
        .height = 760,
        .scale = 2,
        .theme = theme.ui(false),
    });
    defer t.deinit();
    t.dt = 1.0 / 120.0;
    for ([_]@import("app.zig").Page{ .overview, .memory, .disk }) |page| {
        for ([_]f32{ 1100, 937 }) |width| {
            a.page = page;
            a.top_processes.enabled = false;
            t.resize(width, 760);
            t.moveTo(600, 300);
            t.settle(3);
            const before_hover = a.hovers;
            const before = try t.render(gpa);
            defer before.deinit(gpa);
            a.top_processes.enabled = true;
            t.frame();
            const after = try t.render(gpa);
            defer after.deinit(gpa);
            try expect(std.mem.eql(u8, before.bytes, after.bytes));
            try std.testing.expectEqualDeep(before_hover, a.hovers);
        }
    }
}

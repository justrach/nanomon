//! Offscreen real-page fixtures; separate read-only native sampler diagnostics.
//! No windows, updater, process actions, or real app icon lookups.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app = @import("app.zig");
const theme = @import("theme.zig");
const warmup = 30;
const trace = @import("bench_trace.zig");
const pace = @import("bench_pace.zig");
extern "c" fn qos_class_self() c_uint;

pub fn main(init: std.process.Init) !void {
    if (comptime builtin.os.tag != .macos) return error.MetalBenchmarkRequiresMacOS;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "rankings")) return @import("bench_rankings.zig").run(init.gpa);
    if (args.len == 2 and std.mem.eql(u8, args[1], "sampling")) return @import("bench_sampling.zig").run(init, false);
    if (args.len == 2 and std.mem.eql(u8, args[1], "sampling-async")) return @import("bench_sampling.zig").run(init, true);
    const frames = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 300;
    const repeats = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 3;
    if (frames < 1 or frames > 10000 or repeats < 1 or repeats > 20) return error.InvalidCount;
    if (args.len > 6) return error.TooManyArguments;
    const tracing = args.len > 4;
    const paced = tracing and std.mem.eql(u8, args[4], "paced");
    if (tracing and !paced and !std.mem.eql(u8, args[4], "trace")) return error.InvalidTraceMode;
    const only = if (args.len > 5) std.meta.stringToEnum(app.Page, args[5]) orelse return error.UnknownPage else null;
    const mode = if (args.len > 3) args[3] else "compare";
    if (!std.mem.eql(u8, mode, "compare") and !std.mem.eql(u8, mode, "reference") and !std.mem.eql(u8, mode, "cached")) return error.InvalidMode;
    if (tracing) std.debug.print("{{\"kind\":\"profile_environment\",\"qos_class\":{d},\"paced\":{}}}\n", .{ qos_class_self(), paced });
    for (std.enums.values(app.Page)) |page| {
        if (only != null and page != only.?) continue;
        for (0..repeats) |rep| {
            if (std.mem.eql(u8, mode, "compare")) {
                try run(init, page, frames, rep, rep % 2 == 0, tracing, paced);
                try run(init, page, frames, rep, rep % 2 != 0, tracing, paced);
            } else try run(init, page, frames, rep, std.mem.eql(u8, mode, "cached"), tracing, paced);
        }
    }
}

fn run(init: std.process.Init, page: app.Page, frames: usize, rep: usize, cached: bool, tracing: bool, paced: bool) !void {
    const gpa = init.gpa;
    var a: app.App = .init(gpa, init.io);
    defer a.deinit();
    try @import("tests.zig").fake(&a);
    a.top_processes.enabled = cached;
    a.sampler.procs.clearRetainingCapacity();
    // 3,000 processes in 100 synthetic bundles. Cache empty icons explicitly:
    // no real app paths, NSWorkspace icon lookups, commands or process actions.
    for (0..100) |i| {
        const bundle = try std.fmt.allocPrint(gpa, "/nanomon-bench/App{d}.app", .{i});
        try a.icons.made.put(gpa, bundle, &.{});
        for (0..30) |j| {
            const n = i * 30 + j;
            try a.sampler.procs.append(gpa, .{
                .pid = @intCast(990000 + n),
                .ppid = 1,
                .uid = 501,
                .name = "Benchmark process",
                .user = "benchmark",
                .bundle = bundle,
                .cpu = @floatFromInt(n % 101),
                .memory = (n + 1) * (1 << 20),
                .known = true,
                .threads = 12,
                .wakeups = 10,
                .disk_read = n * 1024,
                .disk_written = n * 2048,
            });
        }
    }
    // Full one-hour histories, not an empty graph or a retained idle frame.
    inline for (.{ "user", "system", "app", "wired", "compressed", "pressure", "gpu", "read", "write", "in", "out" }) |name| {
        const h = &@field(a.sampler, name ++ "_history");
        while (h.len < h.values.len) h.push(h.values[h.len % 300]);
    }
    a.page = page;
    a.range = .h1;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, @import("view.zig").view), .{
        .width = 1100,
        .height = 760,
        .scale = 2,
        .theme = theme.ui(false),
    });
    defer t.deinit();
    t.dt = 1.0 / 120.0;
    const target = t.renderer.newTarget(t.size, t.scale);
    defer nanoui.objc.release(target);
    var samples: [9][]f64 = undefined;
    for (&samples) |*s| s.* = try gpa.alloc(f64, frames);
    defer for (samples) |s| gpa.free(s);
    var tails: trace.Collector = .{};
    var pacer: pace.Pacer = .{ .next_start_ns = std.Io.Clock.awake.now(init.io).nanoseconds };
    var deadline_misses: usize = 0;
    var skipped_slots: usize = 0;
    var first_start: i128 = 0;
    var last_start: i128 = 0;
    for (0..warmup + frames) |i| {
        const scheduled_start = pacer.next_start_ns;
        const actual_start = if (paced) try pacer.wait(init.io) else 0;
        // Prepare a deterministic new sample every two simulated seconds.
        // Preparation is not timed native sampling; sorting/grouping, changed
        // graph geometry and the ensuing bar animations ARE measured.
        if (i % 240 == 0) {
            for (a.sampler.procs.items) |*p| p.cpu = 101 - p.cpu;
            a.sampler.system.cpu_user = 100 - a.sampler.system.cpu_user;
            a.sampler.user_history.push(a.sampler.system.cpu_user);
            a.dirty = true;
        }
        const usage_begin = if (tracing) trace.Usage.read() else trace.Usage{};
        const begin = ui.clock.now();
        // Move across the page each frame. Always build, even without input.
        t.ctx.input.mouse = .{ .x = 400 + @as(f32, @floatFromInt(i % 500)), .y = 300 };
        t.frame();
        const built = ui.clock.now();
        const usage_built = if (tracing) trace.Usage.read() else trace.Usage{};
        const render_begin = ui.clock.now();
        const timing = t.renderer.drawTimed(target, t.instances.items, t.text.texture(), t.size, t.theme.background);
        const end = ui.clock.now();
        const finish_ns = if (paced) std.Io.Clock.awake.now(init.io).nanoseconds else 0;
        const usage_end = if (tracing) trace.Usage.read() else trace.Usage{};
        const cadence = if (paced) pacer.finish(finish_ns) else pace.Result{};
        if (i < warmup) continue;
        if (i == warmup) first_start = actual_start;
        last_start = actual_start;
        if (cadence.deadline_missed) deadline_misses += 1;
        skipped_slots += cadence.skipped_slots;
        const n = i - warmup;
        samples[0][n] = (built - begin) * 1000;
        samples[1][n] = timing.encode_ms;
        samples[2][n] = timing.gpu_ms;
        samples[3][n] = (end - begin) * 1000;
        samples[4][n] = t.ctx.stats.build_ms;
        samples[5][n] = t.ctx.stats.layout_ms;
        samples[6][n] = t.ctx.stats.paint_ms;
        samples[7][n] = if (paced) pace.milliseconds(@max(0, actual_start - scheduled_start)) else 0;
        samples[8][n] = cadence.finish_late_ms;
        if (tracing) tails.observe(.{
            .paced = paced,
            .start_late_ms = samples[7][n],
            .finish_late_ms = samples[8][n],
            .deadline_missed = cadence.deadline_missed,
            .skipped_slots = cadence.skipped_slots,
            .frame = n,
            .sample_boundary = i % 240 == 0,
            .frame_ms = samples[0][n],
            .render_ms = (end - render_begin) * 1000,
            .wall_ms = samples[3][n],
            .encode_ms = timing.encode_ms,
            .gpu_ms = timing.gpu_ms,
            .build_ms = samples[4][n],
            .layout_ms = samples[5][n],
            .paint_ms = samples[6][n],
            .frame_usage = trace.Usage.delta(usage_built, usage_begin),
            .render_usage = trace.Usage.delta(usage_end, usage_built),
        });
    }
    if (tracing) tails.report(@tagName(page), rep + 1, cached);
    var missed: usize = 0;
    for (samples[3]) |ms| if (ms > 1000.0 / 120.0) {
        missed += 1;
    };
    const effective_fps = if (paced and frames > 1 and last_start > first_start)
        @as(f64, @floatFromInt(frames - 1)) * 1e9 / @as(f64, @floatFromInt(last_start - first_start))
    else
        0;
    for (samples) |s| std.mem.sort(f64, s, {}, std.sort.asc(f64));
    std.debug.print("{{\"page\":\"{s}\",\"cached\":{},\"tracing\":{},\"paced\":{},\"run\":{d},\"frames\":{d},\"cpu_ms\":{d:.4},\"cpu_p95\":{d:.4},\"encode_ms\":{d:.4},\"gpu_ms\":{d:.4},\"wall_ms\":{d:.4},\"wall_p95\":{d:.4},\"wall_p99\":{d:.4},\"over_budget\":{d},\"build_ms\":{d:.4},\"layout_ms\":{d:.4},\"paint_ms\":{d:.4},\"nodes\":{d},\"instances\":{d},\"deadline_misses\":{d},\"skipped_slots\":{d},\"effective_fps\":{d:.4},\"start_late_p99\":{d:.4},\"finish_late_max\":{d:.4}}}\n", .{
        @tagName(page),                cached,                        tracing,                paced,                  rep + 1,                       frames,                        samples[0][frames / 2],
        samples[0][frames * 95 / 100], samples[1][frames / 2],        samples[2][frames / 2], samples[3][frames / 2], samples[3][frames * 95 / 100], samples[3][frames * 99 / 100], missed,
        samples[4][frames / 2],        samples[5][frames / 2],        samples[6][frames / 2], t.ctx.nodes.items.len,  t.instances.items.len,         deadline_misses,               skipped_slots,
        effective_fps,                 samples[7][frames * 99 / 100], samples[8][frames - 1],
    });
}

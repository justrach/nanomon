//! Deterministic native-worker lifecycle tests. Injected data; no HID reads.
const std = @import("std");
const nanoui = @import("nanoui");
const async_temp = @import("sample_temp_async.zig");
const Worker = async_temp.Worker;
const Fake = struct {
    io: std.Io = std.testing.io,
    started: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    reads: std.atomic.Value(u32) = .init(0),
    notifications: usize = 0,
    notified_thread: ?std.Thread.Id = null,

    fn read(ctx: ?*anyopaque) async_temp.Snapshot {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        _ = f.reads.fetchAdd(1, .monotonic);
        f.started.set(f.io);
        f.release.waitUncancelable(f.io);
        return .{ .temps = .{ .cpu = 48, .cpu_max = 54, .soc = 40 } };
    }
    fn notify(ctx: *anyopaque) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.notifications += 1;
        f.notified_thread = std.Thread.getCurrentId();
    }
    fn waitStarted(f: *Fake) !void {
        const deadline: std.Io.Timeout = .{ .deadline = .fromNow(f.io, .{
            .raw = .fromSeconds(3),
            .clock = .awake,
        }) };
        while (!f.started.isSet()) {
            f.started.waitTimeout(f.io, deadline) catch |err| {
                if (err != error.Timeout) return err;
                if (deadline.deadline.raw.nanoseconds <= std.Io.Clock.awake.now(f.io).nanoseconds) return error.WorkerDidNotStart;
            };
        }
    }
};

fn deliver(worker: *Worker) !void {
    const until = std.Io.Clock.awake.now(std.testing.io).nanoseconds + std.time.ns_per_s * 3;
    while (worker.pending and std.Io.Clock.awake.now(std.testing.io).nanoseconds < until) nanoui.runFor(0.01);
    try std.testing.expect(!worker.pending);
}

test "temperature requests coalesce without blocking and publish only complete data on main" {
    var fake: Fake = .{};
    var worker: Worker = .{ .reader = Fake.read, .reader_ctx = &fake };
    defer worker.deinit();
    defer fake.release.set(fake.io);
    const main_thread = std.Thread.getCurrentId();
    worker.request(fake.io, .{ .ctx = &fake, .func = Fake.notify });
    try std.testing.expect(!worker.failed);
    try fake.waitStarted();
    // The request returned with the reader still blocked. No timing threshold.
    try std.testing.expect(worker.pending and worker.latest == null);
    for (0..100) |_| worker.request(fake.io, .{ .ctx = &fake, .func = Fake.notify });
    try std.testing.expectEqual(1, fake.reads.load(.acquire));
    try std.testing.expectEqual(0, fake.notifications);
    fake.release.set(fake.io);
    try deliver(&worker);
    try std.testing.expectEqual(@as(f32, 48), worker.latest.?.temps.cpu);
    try std.testing.expect(worker.latest.?.sampled_at > 0);
    try std.testing.expectEqual(main_thread, fake.notified_thread.?);
    try std.testing.expectEqual(1, fake.notifications);
    nanoui.runFor(0.05);
    try std.testing.expectEqual(1, fake.reads.load(.acquire)); // idle never re-reads
    worker.request(fake.io, .{ .ctx = &fake, .func = Fake.notify });
    try deliver(&worker);
    try std.testing.expectEqual(2, fake.reads.load(.acquire));
    try std.testing.expectEqual(2, fake.notifications);
}

test "temperature teardown joins before freeing, retires queued notification, and is idempotent" {
    var fake: Fake = .{};
    const worker = try std.testing.allocator.create(Worker);
    worker.* = .{ .reader = Fake.read, .reader_ctx = &fake };
    var freed = false;
    defer if (!freed) {
        worker.deinit();
        std.testing.allocator.destroy(worker);
    };
    defer fake.release.set(fake.io);
    worker.request(fake.io, .{ .ctx = &fake, .func = Fake.notify });
    try std.testing.expect(!worker.failed);
    try fake.waitStarted();
    fake.release.set(fake.io);
    worker.deinit(); // worker may be running or its completion may be queued
    try std.testing.expect(worker.dead and worker.thread == null);
    try std.testing.expectEqual(0, worker.id);
    try std.testing.expect(!worker.take());
    worker.request(fake.io, null);
    try std.testing.expectEqual(1, fake.reads.load(.acquire));
    worker.deinit();
    std.testing.allocator.destroy(worker);
    freed = true;
    // Actually free/poison the context BEFORE the queued main-loop work runs.
    nanoui.runFor(0.05);
    try std.testing.expectEqual(0, fake.notifications);
}

test "paused UI holds temperatures while completion waits; resume publishes without sampling" {
    const App = @import("app.zig").App;
    var a: App = .init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    try @import("tests.zig").fake(&a);
    a.listen(null);
    a.sampler.system.cpu_temp = 42;
    const count = a.sampler.samples;
    const history = a.sampler.user_history.len;
    var fake: Fake = .{};
    defer fake.release.set(fake.io);
    const worker = &a.sampler.state.sensor_worker;
    worker.reader = Fake.read;
    worker.reader_ctx = &fake;
    worker.request(fake.io, a.sampler.on_temperature_update);
    a.sampler.system.temperature_pending = true;
    try std.testing.expect(!worker.failed);
    try fake.waitStarted();
    a.paused = true;
    fake.release.set(fake.io);
    try deliver(worker);
    try std.testing.expect(!a.sampler.system.temperature_pending);
    try std.testing.expectEqual(@as(f32, 42), a.sampler.system.cpu_temp);
    _ = a.tick(0);
    try std.testing.expectEqual(@as(f32, 42), a.sampler.system.cpu_temp);
    a.paused = false;
    _ = a.tick(1);
    try std.testing.expectEqual(@as(f32, 48), a.sampler.system.cpu_temp);
    try std.testing.expectEqual(count, a.sampler.samples);
    try std.testing.expectEqual(history, a.sampler.user_history.len);
    try std.testing.expect(a.sampler.system.temperature_sampled_at != null);
}

test "a failed worker clears stale temperatures without blocking or retry polling" {
    const App = @import("app.zig").App;
    var a: App = .init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    a.live = false;
    a.sampler.system.cpu_temp = 42;
    const worker = &a.sampler.state.sensor_worker;
    worker.latest = .{ .temps = .{ .cpu = 42 }, .sampled_at = 1 };
    worker.pending = true;
    worker.failed = true;
    worker.request(std.testing.io, null);
    a.sampler.refreshTemperatures();
    try std.testing.expect(worker.failed and !worker.pending and worker.latest == null);
    try std.testing.expectEqual(@as(f32, 0), a.sampler.system.cpu_temp);
    try std.testing.expect(a.sampler.system.temperature_sampled_at == null);
    try std.testing.expect(!a.sampler.system.temperature_pending);
    worker.request(std.testing.io, null);
    try std.testing.expect(worker.thread == null);
}

test "MCP does not enable the temperature worker" {
    var p = @import("mcp_stdio.zig").Provider.init(std.testing.allocator, std.testing.io);
    defer p.deinit();
    try std.testing.expect(!p.sampler.async_temperature);
    try std.testing.expect(p.sampler.state.sensor_worker.thread == null);
}

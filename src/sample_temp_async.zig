//! GUI-only temperature worker: one in-flight read, event-driven wake, main-
//! thread publication. Queued callbacks carry non-reused ids, NEVER an owner
//! pointer. MCP continues to use synchronous Sensors.read directly.
const std = @import("std");
const nanoui = @import("nanoui");
const native = @import("sample_temp_mac.zig");
const Notify = @import("sample.zig").Notify;

pub const Snapshot = struct {
    temps: native.Temps = .{},
    stats: native.Stats = .{},
    /// Seconds on Clock.awake; absent until a complete read has been published.
    sampled_at: f64 = 0,
    collection_ms: f64 = 0,
};

// Main-thread-only registry. Bounded resources, no heap context held by a queued
// callback, and no id reuse even if an allocator reuses a Worker's address.
const Entry = struct { id: usize = 0, worker: ?*Worker = null };
var entries: [32]Entry = @splat(.{});
var next_id: usize = 1;
fn allocateId(counter: *usize) ?usize {
    if (counter.* == std.math.maxInt(usize)) return null; // never wrap/reuse
    const id = counter.*;
    counter.* += 1;
    return id;
}
fn attach(worker: *Worker) ?usize {
    for (&entries) |*entry| if (entry.worker == null) {
        const id = allocateId(&next_id) orelse return null;
        entry.* = .{ .id = id, .worker = worker };
        return id;
    };
    return null;
}
fn find(id: usize) ?*Worker {
    for (entries) |entry| if (entry.id == id) return entry.worker;
    return null;
}
fn detach(id: usize) void {
    for (&entries) |*entry| if (entry.id == id) {
        entry.* = .{};
        return;
    };
}

/// request/take/deinit and reader configuration are MAIN-THREAD ONLY. Remain at
/// a stable address after request, and join before freeing the owner or its Io.
pub const Worker = struct {
    thread: ?std.Thread = null,
    io: ?std.Io = null,
    id: usize = 0, // immutable while the worker thread is running
    request_event: std.Io.Event = .unset,
    stopping: std.atomic.Value(bool) = .init(false),
    ready: std.atomic.Value(bool) = .init(false),
    queued: std.atomic.Value(bool) = .init(false),
    slot: Snapshot = .{}, // worker writes; main reads only after ready.acquire
    latest: ?Snapshot = null, // main thread only
    pending: bool = false, // main thread only
    failed: bool = false,
    dead: bool = false,
    notify: ?Notify = null,
    /// Tests inject a deterministic read, never accessing the real sensors.
    reader: ?*const fn (?*anyopaque) Snapshot = null,
    reader_ctx: ?*anyopaque = null,

    pub fn request(w: *Worker, io: std.Io, notify: ?Notify) void {
        if (w.dead) return;
        if (w.failed) {
            w.pending = false;
            w.latest = null;
            return;
        }
        w.notify = notify;
        _ = w.take();
        if (w.pending) return;
        if (w.thread == null) {
            w.io = io;
            w.id = attach(w) orelse {
                w.failed = true;
                return;
            };
            w.thread = std.Thread.spawn(.{}, work, .{w}) catch {
                detach(w.id);
                w.id = 0;
                w.failed = true;
                return;
            };
        }
        w.pending = true;
        w.request_event.set(io);
    }

    /// A sample may consume the result before its queued main callback runs.
    pub fn take(w: *Worker) bool {
        if (w.dead or !w.ready.swap(false, .acquire)) return false;
        w.latest = w.slot;
        w.pending = false;
        return true;
    }

    fn work(w: *Worker) void {
        const lifetime_pool = nanoui.objc.Pool.push();
        defer lifetime_pool.pop();
        var sensors: native.Sensors = .{};
        defer sensors.deinit();
        const io = w.io.?;
        while (true) {
            w.request_event.waitUncancelable(io);
            w.request_event.reset();
            if (w.stopping.load(.acquire)) return;
            const pool = nanoui.objc.Pool.push();
            defer pool.pop();
            const begin = std.Io.Clock.awake.now(io).nanoseconds;
            var result = if (w.reader) |reader| reader(w.reader_ctx) else block: {
                const temps = sensors.read();
                break :block Snapshot{ .temps = temps, .stats = sensors.last_read };
            };
            const end = std.Io.Clock.awake.now(io).nanoseconds;
            result.sampled_at = @as(f64, @floatFromInt(end)) / 1e9;
            result.collection_ms = @as(f64, @floatFromInt(end - begin)) / 1e6;
            if (w.stopping.load(.acquire)) return;
            w.slot = result;
            w.ready.store(true, .release);
            // At most one wake queued per owner. Even after a take-before-
            // callback, that wake will consume the newest completed slot.
            if (!w.queued.swap(true, .acq_rel)) nanoui.objc.dispatchMain(@ptrFromInt(w.id), complete);
        }
    }

    fn complete(ctx: ?*anyopaque) callconv(.c) void {
        const w = find(@intFromPtr(ctx orelse return)) orelse return;
        w.queued.store(false, .release);
        if (w.take()) if (w.notify) |n| n.func(n.ctx);
    }

    pub fn deinit(w: *Worker) void {
        if (w.dead) return;
        w.dead = true;
        w.notify = null;
        w.stopping.store(true, .release);
        if (w.io) |io| w.request_event.set(io);
        // Only teardown waits for HID; frames never join. Keep id immutable
        // until join because a racing completion may still enqueue that id.
        if (w.thread) |thread| thread.join();
        w.thread = null;
        detach(w.id);
        w.id = 0;
        w.ready.store(false, .monotonic);
        w.queued.store(false, .monotonic);
        w.slot = .{};
        w.pending = false;
    }
};

test "retired ids cannot find or publish into a replacement owner" {
    var first: Worker = .{};
    first.id = attach(&first).?;
    const old = first.id;
    first.deinit();
    var second: Worker = .{};
    second.id = attach(&second).?;
    defer second.deinit();
    try std.testing.expect(old != second.id);
    second.slot = .{ .temps = .{ .cpu = 48 } };
    second.ready.store(true, .release);
    second.pending = true;
    Worker.complete(@ptrFromInt(old));
    try std.testing.expect(second.latest == null and second.pending);
    Worker.complete(@ptrFromInt(second.id));
    try std.testing.expectEqual(@as(f32, 48), second.latest.?.temps.cpu);
}

test "bounded registry exhaustion fails without a synchronous fallback or new thread" {
    var counter = std.math.maxInt(usize) - @as(usize, 1);
    try std.testing.expectEqual(std.math.maxInt(usize) - @as(usize, 1), allocateId(&counter).?);
    try std.testing.expect(allocateId(&counter) == null);
    try std.testing.expectEqual(std.math.maxInt(usize), counter);
    var owners: [entries.len]Worker = @splat(.{});
    defer for (&owners) |*owner| owner.deinit();
    for (&owners) |*owner| owner.id = attach(owner).?;
    var overflow: Worker = .{};
    defer overflow.deinit();
    overflow.request(std.testing.io, null);
    try std.testing.expect(overflow.failed and overflow.thread == null and !overflow.pending);
}

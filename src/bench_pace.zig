//! Opt-in benchmark pacing, NOT an application frame loop. One deadline sleep,
//! no polling or spinning, no catch-up burst when work/sleep misses slots.
const std = @import("std");
pub const period_ns: i128 = @divTrunc(std.time.ns_per_s, 120);

pub const Result = struct {
    deadline_missed: bool = false,
    skipped_slots: usize = 0,
    finish_late_ms: f64 = 0,
};

pub const Pacer = struct {
    next_start_ns: i128,

    pub fn wait(p: Pacer, io: std.Io) !i128 {
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        if (now < p.next_start_ns) {
            const target: std.Io.Clock.Timestamp = .{
                .raw = .{ .nanoseconds = std.math.cast(i96, p.next_start_ns) orelse return error.DeadlineOverflow },
                .clock = .awake,
            };
            try target.wait(io);
        }
        return std.Io.Clock.awake.now(io).nanoseconds;
    }

    pub fn finish(p: *Pacer, end_ns: i128) Result {
        const deadline = p.next_start_ns + period_ns;
        const elapsed = @max(0, end_ns - p.next_start_ns);
        const steps = @max(1, @divTrunc(elapsed + period_ns - 1, period_ns));
        p.next_start_ns += steps * period_ns;
        return .{
            .deadline_missed = end_ns > deadline,
            .skipped_slots = @intCast(steps - 1),
            .finish_late_ms = milliseconds(@max(0, end_ns - deadline)),
        };
    }
};

pub fn milliseconds(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

test "pacer preserves absolute slots and does not start catch-up frames in the past" {
    const expect = std.testing.expectEqual;
    var p: Pacer = .{ .next_start_ns = 100 };
    const fast = p.finish(100 + period_ns / 2);
    try expect(false, fast.deadline_missed);
    try expect(0, fast.skipped_slots);
    try expect(100 + period_ns, p.next_start_ns);
    const on_time = p.finish(100 + period_ns * 2);
    try expect(false, on_time.deadline_missed);
    try expect(100 + period_ns * 2, p.next_start_ns);
    const late = p.finish(101 + period_ns * 5);
    try expect(true, late.deadline_missed);
    try expect(3, late.skipped_slots);
    try expect(100 + period_ns * 6, p.next_start_ns);
}

test "pacer separates a missed slot from cheap work that starts late" {
    var p: Pacer = .{ .next_start_ns = 0 };
    // A 0.2ms frame after a scheduler/timer delay still misses its deadline.
    const result = p.finish(period_ns + 200_000);
    try std.testing.expect(result.deadline_missed);
    try std.testing.expectEqual(1, result.skipped_slots);
    try std.testing.expectEqual(period_ns * 2, p.next_start_ns);
    // Exact boundary doesn't silently skip another available slot.
    const boundary = p.finish(period_ns * 3);
    try std.testing.expectEqual(0, boundary.skipped_slots);
    try std.testing.expectEqual(period_ns * 3, p.next_start_ns);
}

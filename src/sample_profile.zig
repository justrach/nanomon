//! Optional collection diagnostics; no clock reads when disabled (the default).
const std = @import("std");
pub const Phase = enum { processes, system, machine, extras, temperature, ticks };
pub const Timings = struct {
    processes: f64 = 0,
    system: f64 = 0,
    machine: f64 = 0,
    extras: f64 = 0,
    temperature: f64 = 0,
    ticks: f64 = 0,
};

pub const Meter = struct {
    io: std.Io,
    timings: ?*Timings,
    last: i96 = 0,

    pub fn init(io: std.Io, timings: ?*Timings) Meter {
        if (timings) |t| t.* = .{};
        return .{ .io = io, .timings = timings, .last = if (timings != null) std.Io.Clock.awake.now(io).nanoseconds else 0 };
    }

    pub fn end(m: *Meter, phase: Phase) void {
        if (m.timings == null) return;
        m.endAt(phase, std.Io.Clock.awake.now(m.io).nanoseconds);
    }

    fn endAt(m: *Meter, phase: Phase, now: i96) void {
        const t = m.timings orelse return;
        inline for (std.enums.values(Phase)) |p| if (phase == p) {
            @field(t, @tagName(p)) = @as(f64, @floatFromInt(now - m.last)) / 1e6;
        };
        m.last = now;
    }
};

test "optional sampling meter records each phase without changing the source" {
    var t: Timings = .{};
    var meter: Meter = .{ .io = std.testing.io, .timings = &t, .last = 10 };
    meter.endAt(.processes, 1_000_010);
    meter.endAt(.temperature, 3_000_010);
    try std.testing.expectEqual(1, t.processes);
    try std.testing.expectEqual(2, t.temperature);
    try std.testing.expectEqual(0, t.extras);
    meter.timings = null;
    meter.endAt(.temperature, 9_000_010);
    try std.testing.expectEqual(2, t.temperature);
}

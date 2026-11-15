//! Stable bounded top-K selection, memoized only while the source is unchanged.
//! App.order invalidates after every sample/refill/reordering. No process actions.
const std = @import("std");
const model = @import("model.zig");
pub const By = enum { cpu, memory, written };
pub const capacity = 12;

pub const Cache = struct {
    const Entry = struct {
        valid: bool = false,
        requested: usize = 0,
        len: usize = 0,
        values: [capacity]model.Process = undefined,
    };
    entries: std.EnumArray(By, Entry) = .initFill(.{}),
    /// Benchmark reference path; production leaves memoization enabled.
    enabled: bool = true,

    pub fn invalidate(c: *Cache) void {
        for (&c.entries.values) |*entry| entry.valid = false;
    }

    pub fn largest(c: *Cache, source: []const model.Process, out: []model.Process, by: By) usize {
        // Unusual callers still get precisely the same algorithm, not a
        // truncated cached prefix. Capacity matters even for IEEE NaNs.
        if (!c.enabled or out.len > capacity) return select(source, out, by);
        const e = c.entries.getPtr(by);
        if (!e.valid or e.requested != out.len) {
            e.len = select(source, e.values[0..out.len], by);
            e.requested = out.len;
            e.valid = true;
        }
        @memcpy(out[0..e.len], e.values[0..e.len]);
        return e.len;
    }
};

/// Original insertion algorithm, including ties, unknowns and floating-point
/// comparisons. No new comparison or reordering rules in the cache fast path.
pub fn select(source: []const model.Process, out: []model.Process, by: By) usize {
    var n: usize = 0;
    for (source) |p| {
        if (!p.known) continue;
        const v = key(p, by);
        if (v <= 0) continue;
        var at = n;
        while (at > 0 and key(out[at - 1], by) < v) : (at -= 1) {}
        if (at >= out.len) continue;
        var j = @min(n, out.len - 1);
        while (j > at) : (j -= 1) out[j] = out[j - 1];
        out[at] = p;
        n = @min(n + 1, out.len);
    }
    return n;
}

fn key(p: model.Process, by: By) f64 {
    return switch (by) {
        .cpu => p.cpu,
        .memory => @floatFromInt(p.memory),
        .written => if (p.detailed()) @floatFromInt(p.disk_written) else 0,
    };
}

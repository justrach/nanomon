//! Headless stdio entry point. No App, windows, GTK initialization, HTTP
//! listener, disk-backed history or sampling while waiting for requests.
const std = @import("std");
const builtin = @import("builtin");
const sample = @import("sample.zig");
const mcp = @import("mcp.zig");
const tools = @import("mcp_tools.zig");

pub const max_request_bytes = 1 << 20;
const min_interval = 0.25;

pub const Provider = struct {
    sampler: sample.Sampler,
    stamps: [sample.Hist.capacity]tools.Stamp = undefined,
    stamps_len: usize = 0,
    last_seconds: ?f64 = null,
    last_finished_seconds: f64 = 0,
    last_at_ms: i64 = 0,
    interval_seconds: ?f64 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Provider {
        return .{ .sampler = .{ .gpa = gpa, .io = io, .async_ps = false } };
    }

    pub fn deinit(p: *Provider) void {
        p.sampler.deinit();
    }

    pub fn source(p: *Provider) mcp.Source {
        return .{ .ptr = p, .sample = query };
    }

    fn seconds(p: *Provider) f64 {
        return @as(f64, @floatFromInt(std.Io.Clock.awake.now(p.sampler.io).nanoseconds)) / 1e9;
    }

    fn collect(p: *Provider) !void {
        const now = p.seconds();
        const wall_ms = std.Io.Clock.real.now(p.sampler.io).toMilliseconds();
        p.sampler.sample(now);
        if (p.sampler.procs.items.len == 0) {
            // A failed collection must not leave counters/history misaligned
            // or turn the next successful sample into a bogus rate.
            const gpa = p.sampler.gpa;
            const io = p.sampler.io;
            p.deinit();
            p.* = .init(gpa, io);
            return error.SamplingUnavailable;
        }
        p.interval_seconds = if (p.last_seconds) |last| now - last else null;
        p.last_seconds = now;
        p.last_at_ms = wall_ms;
        if (p.stamps_len == p.stamps.len) {
            std.mem.copyForwards(tools.Stamp, p.stamps[0 .. p.stamps.len - 1], p.stamps[1..]);
            p.stamps_len -= 1;
        }
        p.stamps[p.stamps_len] = .{ .at_ms = wall_ms, .available = p.sampler.system.available, .rates = p.sampler.system.rate_available };
        p.stamps_len += 1;
        p.last_finished_seconds = p.seconds();
    }

    pub fn due(p: *const Provider, now: f64) bool {
        return p.last_seconds == null or now - p.last_finished_seconds >= min_interval;
    }

    fn query(ctx: *anyopaque) !tools.Data {
        const p: *Provider = @ptrCast(@alignCast(ctx));
        if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.UnsupportedPlatform;
        if (p.last_seconds == null) {
            try p.collect();
            // A CPU percentage or byte rate needs TWO samples, never a
            // guessed zero. Sleep once; do not start a background timer.
            try std.Io.sleep(p.sampler.io, .fromMilliseconds(250), .awake);
            try p.collect();
        } else if (p.due(p.seconds())) {
            try p.collect();
        }
        return .{
            .sampler = &p.sampler,
            .sampled_at_ms = p.last_at_ms,
            .age_ms = @intFromFloat(@max(0, (p.seconds() - p.last_seconds.?) * 1000)),
            .interval_seconds = p.interval_seconds,
            .stamps = p.stamps[0..p.stamps_len],
        };
    }
};

pub fn run(init: std.process.Init) !void {
    var provider: Provider = .init(init.gpa, init.io);
    defer provider.deinit();
    var session: mcp.Session = .{ .source = provider.source() };
    // A fixed bound prevents an unterminated request from allocating forever.
    const in_buf = try init.gpa.alloc(u8, max_request_bytes);
    defer init.gpa.free(in_buf);
    var input = std.Io.File.stdin().readerStreaming(init.io, in_buf);
    var out_buf: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    while (try input.interface.takeDelimiter('\n')) |line| {
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        if (try session.handle(arena.allocator(), line)) |response| {
            try output.interface.writeAll(response);
            try output.interface.writeByte('\n');
            try output.interface.flush();
        }
    }
}

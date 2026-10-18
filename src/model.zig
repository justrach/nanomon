//! What nanomon shows: the processes, each with its CPU (a share of one
//! core, as Activity Monitor counts it), CPU time, threads, idle wake ups,
//! memory and disk, and the system's CPU, memory and disk, with a short
//! history of each, as Activity Monitor's tabs show them.
const std = @import("std");

pub const Process = struct {
    pid: i32,
    ppid: i32,
    uid: u32,
    /// The app's name for an app's process, else its program's.
    name: []const u8,
    user: []const u8,
    /// The app bundle it runs from, for its icon ("" if none).
    bundle: []const u8 = "",
    /// Percent of one core over the last interval.
    cpu: f32 = 0,
    cpu_time_ns: u64 = 0,
    /// Its memory footprint (on macOS, what Activity Monitor shows).
    memory: u64 = 0,
    /// Whether its CPU and memory could be read.
    known: bool = false,
    /// Read by `/bin/ps` (now and then), not by nanomon itself: then its
    /// threads, wake ups and disk are not known.
    from_ps: bool = false,
    threads: u32 = 0,
    /// Times it woke the CPU from idle in the last interval, and in all.
    wakeups: u32 = 0,
    wakeups_total: u64 = 0,
    /// Bytes it has read from and written to disk.
    disk_read: u64 = 0,
    disk_written: u64 = 0,

    /// Whether nanomon read it itself: threads, wake ups and disk known.
    pub fn detailed(p: Process) bool {
        return p.known and !p.from_ps;
    }
};

pub const System = struct {
    cores: u32 = 1,
    /// Percent of all cores, by kind.
    cpu_user: f32 = 0,
    cpu_system: f32 = 0,
    mem_total: u64 = 0,
    /// Memory in use, as Activity Monitor splits it.
    mem_app: u64 = 0,
    mem_wired: u64 = 0,
    mem_compressed: u64 = 0,
    /// Files kept in memory, given back when needed.
    mem_cached: u64 = 0,
    swap_used: u64 = 0,
    /// How hard memory is pressed: 0 (plenty free) to 100.
    pressure: f32 = 0,
    /// Disk operations and bytes since boot, and per second lately.
    reads: u64 = 0,
    writes: u64 = 0,
    read_bytes: u64 = 0,
    written_bytes: u64 = 0,
    reads_sec: f32 = 0,
    writes_sec: f32 = 0,
    read_sec: f32 = 0,
    written_sec: f32 = 0,
    /// Network bytes in and out since boot, and per second lately.
    net_in: u64 = 0,
    net_out: u64 = 0,
    net_in_sec: f32 = 0,
    net_out_sec: f32 = 0,
    /// The GPU's use, percent, and the memory it has in use.
    gpu: f32 = 0,
    gpu_renderer: f32 = 0,
    gpu_tiler: f32 = 0,
    gpu_memory: u64 = 0,
    /// Runnable threads over the last 1, 5 and 15 minutes.
    load: [3]f32 = @splat(0),
    uptime_s: u64 = 0,
    /// Every task and thread on the machine (0 when unknown).
    tasks: u32 = 0,
    threads: u32 = 0,
    /// How hot the machine runs: 0 nominal, 1 fair, 2 serious, 3 critical.
    thermal: u8 = 0,

    pub fn cpuBusy(s: System) f32 {
        return s.cpu_user + s.cpu_system;
    }

    pub fn memUsed(s: System) u64 {
        return s.mem_app + s.mem_wired + s.mem_compressed;
    }
};

/// What the machine is, read once.
pub const Info = struct {
    chip: []const u8 = "",
    model: []const u8 = "",
    os: []const u8 = "",
    host: []const u8 = "",
    gpu: []const u8 = "",
    gpu_cores: u32 = 0,
    /// Cores by kind: the fast ones and the frugal ones, with the
    /// system's names for them; the frugal ones come first in the list.
    fast: u32 = 0,
    frugal: u32 = 0,
    fast_name: []const u8 = "Performance",
    frugal_name: []const u8 = "Efficiency",
};

/// A uptime as "27d 20h", "3h 12m", "8m".
pub fn uptime(buf: []u8, s: u64) []const u8 {
    const d = s / 86400;
    const h = (s / 3600) % 24;
    const m = (s / 60) % 60;
    if (d > 0) return std.fmt.bufPrint(buf, "{d}d {d}h", .{ d, h }) catch "";
    if (h > 0) return std.fmt.bufPrint(buf, "{d}h {d}m", .{ h, m }) catch "";
    return std.fmt.bufPrint(buf, "{d}m", .{m}) catch "";
}

/// A rate as "7.28 MB/s", "12.3 KB/s".
pub fn rate(buf: []u8, per_s: f32) []const u8 {
    const f: f64 = @max(0, per_s);
    if (f >= 1 << 30) return std.fmt.bufPrint(buf, "{d:.2} GB/s", .{f / (1 << 30)}) catch "";
    if (f >= 1 << 20) return std.fmt.bufPrint(buf, "{d:.2} MB/s", .{f / (1 << 20)}) catch "";
    if (f >= 1 << 10) return std.fmt.bufPrint(buf, "{d:.1} KB/s", .{f / 1024}) catch "";
    return std.fmt.bufPrint(buf, "{d:.0} B/s", .{f}) catch "";
}

/// Activity Monitor's tabs that nanomon has (Energy and Network need what
/// only Apple's own daemon reads).
pub const Tab = enum { cpu, memory, disk };

pub const Sort = enum { name, cpu, time, threads, wakeups, memory, written, read, pid, user };

/// The last `n` values, oldest first.
pub fn History(comptime n: usize) type {
    return struct {
        values: [n]f32 = @splat(0),
        len: usize = 0,

        const Self = @This();
        pub const capacity = n;

        pub fn push(h: *Self, v: f32) void {
            if (h.len < n) {
                h.values[h.len] = v;
                h.len += 1;
                return;
            }
            std.mem.copyForwards(f32, h.values[0 .. n - 1], h.values[1..]);
            h.values[n - 1] = v;
        }

        pub fn slice(h: *const Self) []const f32 {
            return h.values[0..h.len];
        }
    };
}

/// Orders `procs` by `key`, smallest first or largest first; equals by pid.
pub fn sort(procs: []Process, key: Sort, ascending: bool) void {
    const Ctx = struct { key: Sort, asc: bool };
    std.mem.sort(Process, procs, Ctx{ .key = key, .asc = ascending }, struct {
        fn lt(ctx: Ctx, a: Process, b: Process) bool {
            // Numbers nobody could read go last, whichever the direction.
            const ka, const kb = switch (ctx.key) {
                .cpu, .time, .memory => .{ a.known, b.known },
                .threads, .wakeups, .written, .read => .{ a.detailed(), b.detailed() },
                .name, .user, .pid => .{ true, true },
            };
            if (ka != kb) return ka;
            const o = order(ctx.key, a, b);
            if (o == .eq) return a.pid < b.pid;
            return (o == .lt) == ctx.asc;
        }

        fn order(by: Sort, a: Process, b: Process) std.math.Order {
            return switch (by) {
                .name => std.ascii.orderIgnoreCase(a.name, b.name),
                .user => std.ascii.orderIgnoreCase(a.user, b.user),
                .pid => .eq,
                .cpu => std.math.order(a.cpu, b.cpu),
                .time => std.math.order(a.cpu_time_ns, b.cpu_time_ns),
                .threads => std.math.order(a.threads, b.threads),
                .wakeups => std.math.order(a.wakeups, b.wakeups),
                .memory => std.math.order(a.memory, b.memory),
                .written => std.math.order(a.disk_written, b.disk_written),
                .read => std.math.order(a.disk_read, b.disk_read),
            };
        }
    }.lt);
}

/// Sizes as Activity Monitor writes them: "1.50 GB", "340.2 MB", "12 KB".
pub fn bytes(buf: []u8, n: u64) []const u8 {
    const f: f64 = @floatFromInt(n);
    if (n >= 1 << 40) return std.fmt.bufPrint(buf, "{d:.2} TB", .{f / (1 << 40)}) catch "";
    if (n >= 1 << 30) return std.fmt.bufPrint(buf, "{d:.2} GB", .{f / (1 << 30)}) catch "";
    if (n >= 1 << 20) return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / (1 << 20)}) catch "";
    if (n >= 1 << 10) return std.fmt.bufPrint(buf, "{d:.0} KB", .{f / 1024}) catch "";
    return std.fmt.bufPrint(buf, "{d} bytes", .{n}) catch "";
}

/// CPU time as Activity Monitor writes it: "1:02:03.45", "12:34.56".
pub fn duration(buf: []u8, ns: u64) []const u8 {
    const cs = ns / 10_000_000;
    const s = cs / 100;
    const h = s / 3600;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}.{d:0>2}", .{ h, (s / 60) % 60, s % 60, cs % 100 }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}.{d:0>2}", .{ s / 60, s % 60, cs % 100 }) catch "";
}

/// Counts with thousands separated: "1,234,567".
pub fn count(buf: []u8, n: u64) []const u8 {
    var digits: [24]u8 = undefined;
    const d = std.fmt.bufPrint(&digits, "{d}", .{n}) catch return "";
    var len: usize = 0;
    for (d, 0..) |ch, i| {
        if (i > 0 and (d.len - i) % 3 == 0) {
            if (len >= buf.len) return buf[0..len];
            buf[len] = ',';
            len += 1;
        }
        if (len >= buf.len) return buf[0..len];
        buf[len] = ch;
        len += 1;
    }
    return buf[0..len];
}

test "sorting, sizes, times and counts" {
    var ps = [_]Process{
        .{ .pid = 3, .ppid = 1, .uid = 0, .name = "b", .user = "root", .cpu = 5, .memory = 10, .known = true },
        .{ .pid = 1, .ppid = 0, .uid = 0, .name = "a", .user = "root", .cpu = 50, .memory = 5, .known = true },
        .{ .pid = 2, .ppid = 1, .uid = 501, .name = "C", .user = "me", .cpu = 5, .memory = 99, .known = true, .threads = 7 },
    };
    sort(&ps, .cpu, false);
    try std.testing.expectEqual(@as(i32, 1), ps[0].pid);
    try std.testing.expectEqual(@as(i32, 2), ps[1].pid);
    sort(&ps, .name, true);
    try std.testing.expectEqualStrings("C", ps[2].name);
    sort(&ps, .memory, true);
    try std.testing.expectEqual(@as(u64, 5), ps[0].memory);
    sort(&ps, .threads, false);
    try std.testing.expectEqual(@as(u32, 7), ps[0].threads);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.50 GB", bytes(&buf, 3 << 29));
    try std.testing.expectEqualStrings("1:02:03.45", duration(&buf, 3723_450_000_000));
    try std.testing.expectEqualStrings("1,234,567", count(&buf, 1234567));
    try std.testing.expectEqualStrings("999", count(&buf, 999));
    try std.testing.expectEqualStrings("27d 20h", uptime(&buf, 27 * 86400 + 20 * 3600 + 59));
    try std.testing.expectEqualStrings("7.28 MB/s", rate(&buf, 7.28 * (1 << 20)));
    var h: History(3) = .{};
    for ([_]f32{ 1, 2, 3, 4 }) |v| h.push(v);
    try std.testing.expectEqualSlices(f32, &.{ 2, 3, 4 }, h.slice());
}

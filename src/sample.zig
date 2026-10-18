//! Taking a sample: the platform's processes and system figures (macOS,
//! Linux), then what changed since the last one: CPU percentages from CPU
//! time over the time between samples, as Activity Monitor computes them,
//! wake ups in the interval, and the disk's rates.
const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const Process = model.Process;

pub const os = switch (builtin.os.tag) {
    .macos => @import("sample_mac.zig"),
    .linux => @import("sample_linux.zig"),
    else => @import("sample_none.zig"),
};

/// Cumulative CPU ticks of the whole machine, by kind.
pub const Ticks = struct { user: u64 = 0, system: u64 = 0, idle: u64 = 0 };

pub const Notify = struct { ctx: *anyopaque, func: *const fn (*anyopaque) void };

const PsSeen = struct { time_ns: u64, wall: f64, cpu: f32 = 0 };

/// A process's counters at the last sample.
const Prev = struct { time_ns: u64, wakeups: u64 };

/// A process's names, worked out once: what it shows and its app bundle,
/// both slices of one allocation.
const Named = struct { owned: []u8, name: []const u8, bundle: []const u8 };

/// An hour of samples, every two seconds: the longest range shown.
pub const Hist = model.History(1800);

/// The most cores whose load is kept.
pub const max_cores = 256;

extern "c" fn getpwuid(uid: c_uint) ?*extern struct { name: ?[*:0]const u8 };

pub const Sampler = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    procs: std.ArrayList(Process) = .empty,
    system: model.System = .{},
    /// The CPU's user and system percents, memory pressure, and the disk's
    /// bytes read and written a second.
    user_history: Hist = .{},
    system_history: Hist = .{},
    pressure_history: Hist = .{},
    read_history: Hist = .{},
    write_history: Hist = .{},
    /// Memory in use by kind, percent of all; the GPU; the network.
    app_history: Hist = .{},
    wired_history: Hist = .{},
    compressed_history: Hist = .{},
    gpu_history: Hist = .{},
    in_history: Hist = .{},
    out_history: Hist = .{},
    /// Each core's ticks (filled by the platform with the totals), the
    /// last sample's, and its busy percent between them.
    cores: u32 = 0,
    core_ticks: [max_cores]Ticks = @splat(.{}),
    prev_core_ticks: [max_cores]Ticks = @splat(.{}),
    core_load: [max_cores]f32 = @splat(0),
    info: model.Info = .{},
    prev_net: [2]u64 = @splat(0),
    /// Each process's counters at the last sample, and when that was.
    prev: std.AutoHashMapUnmanaged(i32, Prev) = .empty,
    prev_wall: f64 = 0,
    prev_ticks: Ticks = .{},
    prev_disk: [4]u64 = @splat(0),
    /// Names by pid (a name is worked out once per process), and users.
    names: std.AutoHashMapUnmanaged(i32, Named) = .empty,
    users: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    state: os.State = .{},
    samples: usize = 0,
    /// Told when figures come between samples (ps's answers).
    on_update: ?Notify = null,
    /// What ps said of a process the last time it changed: its CPU time,
    /// when that was, and the percent worked out from it.
    ps_seen: std.AutoHashMapUnmanaged(i32, PsSeen) = .empty,

    pub fn deinit(s: *Sampler) void {
        s.procs.deinit(s.gpa);
        s.prev.deinit(s.gpa);
        s.ps_seen.deinit(s.gpa);
        var it = s.names.valueIterator();
        while (it.next()) |n| s.gpa.free(n.owned);
        s.names.deinit(s.gpa);
        var ut = s.users.valueIterator();
        while (ut.next()) |u| s.gpa.free(u.*);
        s.users.deinit(s.gpa);
        os.deinit(s);
    }

    /// The name of user `uid`.
    pub fn user(s: *Sampler, uid: u32) []const u8 {
        if (s.users.get(uid)) |u| return u;
        if (comptime builtin.os.tag == .windows) return "you";
        const login: []const u8 = if (getpwuid(uid)) |pw| (if (pw.name) |n| std.mem.span(n) else "") else "";
        const owned = (if (login.len > 0) s.gpa.dupe(u8, login) else std.fmt.allocPrint(s.gpa, "{d}", .{uid})) catch return "?";
        s.users.put(s.gpa, uid, owned) catch {
            s.gpa.free(owned);
            return "?";
        };
        return owned;
    }

    /// The names of process `pid`, from what `make.name` gives the first
    /// time: its program's path (or, without one, its short name).
    pub fn name(s: *Sampler, pid: i32, make: anytype) Named {
        if (s.names.get(pid)) |n| return n;
        var buf: [1024]u8 = undefined;
        const got = make.name(&buf);
        const owned = s.gpa.dupe(u8, got) catch return .{ .owned = &.{}, .name = "?", .bundle = "" };
        const named: Named = if (std.mem.indexOfScalar(u8, owned, '/') != null)
            .{ .owned = owned, .name = displayName(owned), .bundle = bundlePath(owned) }
        else
            .{ .owned = owned, .name = owned, .bundle = "" };
        s.names.put(s.gpa, pid, named) catch {
            s.gpa.free(owned);
            return .{ .owned = &.{}, .name = "?", .bundle = "" };
        };
        return named;
    }

    /// Takes a sample at `now` (seconds).
    pub fn sample(s: *Sampler, now: f64) void {
        s.procs.clearRetainingCapacity();
        const ticks = os.collect(s);
        const wall = now - s.prev_wall;
        var next: std.AutoHashMapUnmanaged(i32, Prev) = .empty;
        next.ensureTotalCapacity(s.gpa, @intCast(s.procs.items.len)) catch {};
        var next_seen: std.AutoHashMapUnmanaged(i32, PsSeen) = .empty;
        for (s.procs.items) |*p| {
            if (!p.known) continue;
            if (p.from_ps) {
                // ps answers every few samples: a percent over the time
                // between two answers that differ, kept until the next.
                var seen: PsSeen = s.ps_seen.get(p.pid) orelse .{ .time_ns = p.cpu_time_ns, .wall = now };
                if (p.cpu_time_ns != seen.time_ns and now > seen.wall) {
                    seen.cpu = @floatCast(@as(f64, @floatFromInt(p.cpu_time_ns -| seen.time_ns)) / ((now - seen.wall) * 1e9) * 100);
                    seen.time_ns = p.cpu_time_ns;
                    seen.wall = now;
                }
                p.cpu = seen.cpu;
                next_seen.put(s.gpa, p.pid, seen) catch {};
                continue;
            }
            next.putAssumeCapacity(p.pid, .{ .time_ns = p.cpu_time_ns, .wakeups = p.wakeups_total });
            if (s.samples > 0 and wall > 0) if (s.prev.get(p.pid)) |before| {
                const d: f64 = @floatFromInt(p.cpu_time_ns -| before.time_ns);
                p.cpu = @floatCast(d / (wall * 1e9) * 100);
                p.wakeups = @intCast(@min(std.math.maxInt(u32), p.wakeups_total -| before.wakeups));
            };
        }
        s.prev.deinit(s.gpa);
        s.prev = next;
        s.ps_seen.deinit(s.gpa);
        s.ps_seen = next_seen;
        s.forgetGone();
        // The machine's CPU, from its ticks since the last sample.
        const du = ticks.user -| s.prev_ticks.user;
        const ds = ticks.system -| s.prev_ticks.system;
        const di = ticks.idle -| s.prev_ticks.idle;
        const total: f32 = @floatFromInt(@max(1, du + ds + di));
        if (s.samples > 0) {
            s.system.cpu_user = @as(f32, @floatFromInt(du)) / total * 100;
            s.system.cpu_system = @as(f32, @floatFromInt(ds)) / total * 100;
        }
        // The disk's rates, from its counters since the last sample.
        const sy = &s.system;
        const disk = [4]u64{ sy.reads, sy.writes, sy.read_bytes, sy.written_bytes };
        if (s.samples > 0 and wall > 0) {
            const rate = struct {
                fn f(a: u64, b: u64, w: f64) f32 {
                    return @floatCast(@as(f64, @floatFromInt(a -| b)) / w);
                }
            }.f;
            sy.reads_sec = rate(disk[0], s.prev_disk[0], wall);
            sy.writes_sec = rate(disk[1], s.prev_disk[1], wall);
            sy.read_sec = rate(disk[2], s.prev_disk[2], wall);
            sy.written_sec = rate(disk[3], s.prev_disk[3], wall);
        }
        s.prev_disk = disk;
        if (s.samples > 0 and wall > 0) {
            sy.net_in_sec = @floatCast(@as(f64, @floatFromInt(sy.net_in -| s.prev_net[0])) / wall);
            sy.net_out_sec = @floatCast(@as(f64, @floatFromInt(sy.net_out -| s.prev_net[1])) / wall);
        }
        s.prev_net = .{ sy.net_in, sy.net_out };
        // Each core's busy share since the last sample.
        for (0..@min(s.cores, max_cores)) |i| {
            const now_t = s.core_ticks[i];
            const was = s.prev_core_ticks[i];
            const busy = (now_t.user + now_t.system) -| (was.user + was.system);
            const all = busy + (now_t.idle -| was.idle);
            if (s.samples > 0 and all > 0) s.core_load[i] = @floatCast(@as(f64, @floatFromInt(busy)) / @as(f64, @floatFromInt(all)) * 100);
            s.prev_core_ticks[i] = now_t;
        }
        s.prev_ticks = ticks;
        s.prev_wall = now;
        s.samples += 1;
        s.user_history.push(sy.cpu_user);
        s.system_history.push(sy.cpu_system);
        s.pressure_history.push(sy.pressure);
        s.read_history.push(sy.read_sec);
        s.write_history.push(sy.written_sec);
        const all_mem: f64 = @floatFromInt(@max(1, sy.mem_total));
        const pct = struct {
            fn f(n: u64, t: f64) f32 {
                return @floatCast(@as(f64, @floatFromInt(n)) / t * 100);
            }
        }.f;
        s.app_history.push(pct(sy.mem_app, all_mem));
        s.wired_history.push(pct(sy.mem_wired, all_mem));
        s.compressed_history.push(pct(sy.mem_compressed, all_mem));
        s.gpu_history.push(sy.gpu);
        s.in_history.push(sy.net_in_sec);
        s.out_history.push(sy.net_out_sec);
    }

    /// Fills in what ps has said since the sample, for the processes
    /// nanomon could not read; their percent comes at a later answer.
    pub fn refill(s: *Sampler, now: f64) void {
        if (comptime !@hasDecl(os, "known")) return;
        for (s.procs.items) |*p| {
            if (p.known) continue;
            const k = os.known(s, p.pid) orelse continue;
            p.* = .{ .pid = p.pid, .ppid = p.ppid, .uid = p.uid, .name = p.name, .user = p.user, .bundle = p.bundle, .cpu_time_ns = k.time_ns, .memory = k.rss, .known = true, .from_ps = true };
            s.ps_seen.put(s.gpa, p.pid, .{ .time_ns = k.time_ns, .wall = now }) catch {};
        }
    }

    /// Names of processes that ended go: a new process may take the pid.
    fn forgetGone(s: *Sampler) void {
        var alive: std.AutoHashMapUnmanaged(i32, void) = .empty;
        defer alive.deinit(s.gpa);
        alive.ensureTotalCapacity(s.gpa, @intCast(s.procs.items.len)) catch return;
        for (s.procs.items) |p| alive.putAssumeCapacity(p.pid, {});
        var gone: std.ArrayList(i32) = .empty;
        defer gone.deinit(s.gpa);
        var it = s.names.keyIterator();
        while (it.next()) |pid| if (!alive.contains(pid.*)) gone.append(s.gpa, pid.*) catch {};
        for (gone.items) |pid| if (s.names.fetchRemove(pid)) |e| s.gpa.free(e.value.owned);
    }
};

/// The name shown for a program at `path`: the app for anything inside
/// an app's bundle ("Safari", "Google Chrome Helper (Renderer)"), else the
/// program's file name.
pub fn displayName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, path, ".app/")) |end| {
        const start = if (std.mem.lastIndexOfScalar(u8, path[0..end], '/')) |i| i + 1 else 0;
        return path[start..end];
    }
    return std.fs.path.basename(path);
}

/// The app bundle a program at `path` runs from: the innermost one, as
/// its name is ("" if it is not in one).
pub fn bundlePath(path: []const u8) []const u8 {
    const end = std.mem.lastIndexOf(u8, path, ".app/") orelse return "";
    return path[0 .. end + 4];
}

test "names as Activity Monitor shows them" {
    try std.testing.expectEqualStrings("/Applications/Safari.app", bundlePath("/Applications/Safari.app/Contents/MacOS/Safari"));
    try std.testing.expectEqualStrings("", bundlePath("/sbin/launchd"));
    try std.testing.expectEqualStrings("Safari", displayName("/Applications/Safari.app/Contents/MacOS/Safari"));
    try std.testing.expectEqualStrings("Google Chrome Helper (Renderer)", displayName("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"));
    try std.testing.expectEqualStrings("launchd", displayName("/sbin/launchd"));
}

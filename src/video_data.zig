//! The machine the video shows: made-up figures and processes, moving a
//! little every half second, so nothing of the real machine (its users,
//! its processes) is in the picture. The app's `send` does nothing, and
//! nothing asks to quit, so no process is ever signaled.
const std = @import("std");
const App = @import("app.zig").App;

pub const me: u32 = 501;

/// Pids of the processes the story marks and graff suggests.
pub const music = 2214;
pub const preview = 2381;
pub const notes = 2407;
pub const web = 1311;

pub fn fill(a: *App) !void {
    a.live = false;
    a.dark = false;
    a.uid = me;
    a.send = record;
    const s = &a.sampler;
    s.system = .{ .cores = 28, .cpu_user = 21, .cpu_system = 7, .mem_total = 96 << 30, .mem_app = 38 << 30, .mem_wired = 9 << 30, .mem_compressed = 4 << 30, .mem_cached = 22 << 30, .swap_used = 0, .pressure = 22, .reads = 9_234_567, .writes = 5_765_432, .read_bytes = 1300 << 30, .written_bytes = 900 << 30, .read_sec = 18 << 20, .written_sec = 6 << 20, .net_in = 190 << 30, .net_out = 40 << 30, .net_in_sec = 420 << 10, .net_out_sec = 60 << 10, .gpu = 31, .gpu_renderer = 28, .gpu_tiler = 9, .gpu_memory = 3 << 30, .load = .{ 6.2, 5.4, 4.9 }, .uptime_s = 13 * 86400 + 5 * 3600, .tasks = 812, .threads = 4096 };
    s.info = .{ .chip = "Apple M3 Ultra", .model = "Mac15,14", .os = "macOS 27.0", .host = "Studio", .gpu = "Apple M3 Ultra", .gpu_cores = 60, .fast = 20, .frugal = 8, .fast_name = "Performance", .frugal_name = "Efficiency" };
    s.cores = 28;
    var r = std.Random.DefaultPrng.init(7);
    for (0..400) |_| push(a, r.random());
    try s.procs.appendSlice(s.gpa, &procs);
}

const procs = [_]@import("model.zig").Process{
    .{ .pid = 0, .ppid = 0, .uid = 0, .name = "kernel_task", .user = "root", .cpu = 6.1, .cpu_time_ns = 9_000_000_000_000, .memory = 4 << 30, .known = true, .from_ps = true },
    .{ .pid = 412, .ppid = 1, .uid = 88, .name = "WindowServer", .user = "_windowserver", .cpu = 24.0, .cpu_time_ns = 4_000_000_000_000, .memory = 1900 << 20, .known = true, .from_ps = true },
    .{ .pid = 48213, .ppid = 1, .uid = me, .name = "zig", .user = "me", .cpu = 96.0, .cpu_time_ns = 60_000_000_000, .memory = 5200 << 20, .known = true, .threads = 28, .wakeups = 30 },
    .{ .pid = 1204, .ppid = 1, .uid = me, .name = "Safari", .user = "me", .bundle = "/Applications/Safari.app", .cpu = 18.5, .cpu_time_ns = 900_000_000_000, .memory = 1400 << 20, .known = true, .threads = 31, .wakeups = 120 },
    .{ .pid = web, .ppid = 1204, .uid = me, .name = "Safari Web Content", .user = "me", .bundle = "/Applications/Safari.app", .cpu = 12.5, .cpu_time_ns = 1_260_000_000_000, .memory = 3400 << 20, .known = true, .threads = 14, .wakeups = 80 },
    .{ .pid = 3120, .ppid = 1, .uid = me, .name = "nanoterm", .user = "me", .cpu = 3.2, .cpu_time_ns = 1_840_000_000_000, .memory = 96 << 20, .known = true, .threads = 8, .wakeups = 2 },
    .{ .pid = 921, .ppid = 1, .uid = me, .name = "Finder", .user = "me", .bundle = "/System/Library/CoreServices/Finder.app", .cpu = 1.4, .cpu_time_ns = 3_200_000_000_000, .memory = 310 << 20, .known = true, .threads = 9 },
    .{ .pid = 1290, .ppid = 1, .uid = me, .name = "Mail", .user = "me", .bundle = "/System/Applications/Mail.app", .cpu = 0.9, .cpu_time_ns = 610_000_000_000, .memory = 420 << 20, .known = true, .threads = 11 },
    .{ .pid = 538, .ppid = 1, .uid = 0, .name = "mds_stores", .user = "root", .cpu = 7.8, .cpu_time_ns = 5_100_000_000_000, .memory = 260 << 20, .known = true, .from_ps = true },
    .{ .pid = 1450, .ppid = 1, .uid = me, .name = "Terminal", .user = "me", .bundle = "/System/Applications/Utilities/Terminal.app", .cpu = 0.5, .cpu_time_ns = 95_000_000_000, .memory = 140 << 20, .known = true, .threads = 7 },
    .{ .pid = music, .ppid = 1, .uid = me, .name = "Music", .user = "me", .bundle = "/System/Applications/Music.app", .cpu = 2.1, .cpu_time_ns = 2_700_000_000_000, .memory = 980 << 20, .known = true, .threads = 22 },
    .{ .pid = preview, .ppid = 1, .uid = me, .name = "Preview", .user = "me", .bundle = "/System/Applications/Preview.app", .cpu = 0.4, .cpu_time_ns = 48_000_000_000, .memory = 610 << 20, .known = true, .threads = 6 },
    .{ .pid = notes, .ppid = 1, .uid = me, .name = "Notes", .user = "me", .bundle = "/System/Applications/Notes.app", .cpu = 0.3, .cpu_time_ns = 31_000_000_000, .memory = 520 << 20, .known = true, .threads = 8 },
    .{ .pid = 3398, .ppid = 1, .uid = me, .name = "nanomon", .user = "me", .cpu = 0.7, .cpu_time_ns = 12_000_000_000, .memory = 38 << 20, .known = true, .threads = 4 },
    .{ .pid = 1, .ppid = 1, .uid = 0, .name = "launchd", .user = "root", .cpu = 0.2, .cpu_time_ns = 7_400_000_000_000, .memory = 30 << 20, .known = true, .from_ps = true },
};

fn record(_: c_int, _: c_int) callconv(.c) c_int {
    return 0;
}

var phase: f32 = 0;

/// A new sample: the graphs move along and the figures with them.
pub fn push(a: *App, rnd: std.Random) void {
    const s = &a.sampler;
    phase += 1;
    const wave = 0.5 + 0.5 * @sin(phase / 7);
    const busy = 18 + 22 * wave + rnd.float(f32) * 14;
    const user = busy * 0.72;
    s.user_history.push(user);
    s.system_history.push(busy - user);
    s.app_history.push(40 + 3 * @sin(phase / 23) + rnd.float(f32));
    s.wired_history.push(9.4);
    s.compressed_history.push(4 + @sin(phase / 9));
    s.pressure_history.push(22);
    const gpu = 20 + 30 * (0.5 + 0.5 * @sin(phase / 5)) + rnd.float(f32) * 12;
    s.gpu_history.push(gpu);
    const read = (6 + 30 * rnd.float(f32) * rnd.float(f32)) * (1 << 20);
    const written = (2 + 10 * rnd.float(f32) * rnd.float(f32)) * (1 << 20);
    s.read_history.push(read);
    s.write_history.push(written);
    const in = (150 + 500 * rnd.float(f32) * rnd.float(f32)) * 1024;
    s.in_history.push(in);
    s.out_history.push((30 + 40 * rnd.float(f32)) * 1024);
    s.system.cpu_user = user;
    s.system.cpu_system = busy - user;
    s.system.gpu = gpu;
    s.system.read_sec = read;
    s.system.written_sec = written;
    s.system.net_in_sec = in;
    for (0..s.cores) |i| {
        const fast = i < 20;
        const base: f32 = if (fast) busy * 1.1 else busy * 0.5;
        s.core_load[i] = std.math.clamp(base + (rnd.float(f32) - 0.5) * 40, 1, 100);
    }
    // Each process jitters around its own figure, never past its
    // neighbors, so the table keeps its order while the pointer is on it.
    for (s.procs.items) |*p| for (procs) |q| {
        if (q.pid == p.pid) p.cpu = q.cpu * (0.9 + 0.2 * rnd.float(f32));
    };
    a.dirty = true;
}

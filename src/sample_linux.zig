//! Processes and the system on Linux, from /proc: each process's name,
//! parent, CPU time and threads (stat), memory (statm), user (status,
//! once), disk bytes (io, the user's own), and the machine's CPU ticks
//! (stat), memory and swap (meminfo) and disks (diskstats).
const std = @import("std");
const sample = @import("sample.zig");
const model = @import("model.zig");
const Sampler = sample.Sampler;
const sys = @import("sample_sys_linux.zig");

extern "c" fn sysconf(name: c_int) c_long;

pub const State = struct {
    /// Clock ticks a second, bytes a page.
    hz: u64 = 0,
    page: u64 = 4096,
    uids: std.AutoHashMapUnmanaged(i32, u32) = .empty,
    text: sys.Text = .{},
    known_machine: bool = false,
};

pub fn deinit(s: *Sampler) void {
    s.state.uids.deinit(s.gpa);
}

const Namer = struct {
    comm: []const u8,
    pub fn name(n: Namer, _: []u8) []const u8 {
        return n.comm;
    }
};

pub fn collect(s: *Sampler) sample.Ticks {
    const st = &s.state;
    if (st.hz == 0) {
        st.hz = @intCast(@max(1, sysconf(2))); // _SC_CLK_TCK
        st.page = @intCast(@max(1, sysconf(30))); // _SC_PAGESIZE
    }
    var dir = std.Io.Dir.cwd().openDir(s.io, "/proc", .{ .iterate = true }) catch return .{};
    defer dir.close(s.io);
    var it = dir.iterate();
    var buf: [4096]u8 = undefined;
    var path: [64]u8 = undefined;
    while (it.next(s.io) catch null) |e| {
        const pid = std.fmt.parseInt(i32, e.name, 10) catch continue;
        const stat = dir.readFile(s.io, std.fmt.bufPrint(&path, "{d}/stat", .{pid}) catch continue, &buf) catch continue;
        const open = std.mem.indexOfScalar(u8, stat, '(') orelse continue;
        const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
        const comm = stat[open + 1 .. close];
        // After ") ": state, ppid, …; utime and stime are fields 14 and 15,
        // the threads 20.
        var f = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
        var fields: [18][]const u8 = undefined;
        var n: usize = 0;
        while (n < fields.len) : (n += 1) fields[n] = f.next() orelse break;
        if (n < fields.len) continue;
        const ppid = std.fmt.parseInt(i32, fields[1], 10) catch 0;
        const utime = std.fmt.parseInt(u64, fields[11], 10) catch 0;
        const stime = std.fmt.parseInt(u64, fields[12], 10) catch 0;
        const uid = st.uids.get(pid) orelse blk: {
            const u = uidOf(s, dir, pid);
            st.uids.put(s.gpa, pid, u) catch {};
            break :blk u;
        };
        var p: model.Process = .{ .pid = pid, .ppid = ppid, .uid = uid, .name = s.name(pid, Namer{ .comm = comm }).name, .user = s.user(uid) };
        p.cpu_time_ns = (utime + stime) * 1_000_000_000 / st.hz;
        p.threads = std.fmt.parseInt(u32, fields[17], 10) catch 0;
        if (dir.readFile(s.io, std.fmt.bufPrint(&path, "{d}/io", .{pid}) catch continue, &buf)) |io| {
            p.disk_read = field(io, "read_bytes:");
            p.disk_written = field(io, "write_bytes:");
        } else |_| {}
        if (dir.readFile(s.io, std.fmt.bufPrint(&path, "{d}/statm", .{pid}) catch continue, &buf)) |statm| {
            var m = std.mem.tokenizeScalar(u8, statm, ' ');
            _ = m.next();
            p.memory = (std.fmt.parseInt(u64, m.next() orelse "0", 10) catch 0) * st.page;
        } else |_| {}
        p.known = true;
        s.procs.append(s.gpa, p) catch break;
    }
    if (st.uids.count() > 4 * (s.procs.items.len + 64)) st.uids.clearRetainingCapacity();
    memory(s);
    disks(s);
    const t = ticks(s);
    if (!st.known_machine) {
        st.known_machine = true;
        sys.machine(s, &st.text);
    }
    sys.extras(s);
    return t;
}

/// The number after `key` in a "key: value" listing.
fn field(text: []const u8, key: []const u8) u64 {
    const at = std.mem.indexOf(u8, text, key) orelse return 0;
    var f = std.mem.tokenizeAny(u8, text[at + key.len ..], " \t\n");
    return std.fmt.parseInt(u64, f.next() orelse "0", 10) catch 0;
}

/// Whole disks' reads, writes and bytes (sectors of 512 bytes), summed;
/// partitions and virtual devices left out.
fn disks(s: *Sampler) void {
    var buf: [16384]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(s.io, "/proc/diskstats", &buf) catch return;
    var t: [4]u64 = @splat(0);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next();
        _ = f.next();
        const dev = f.next() orelse continue;
        if (!wholeDisk(dev)) continue;
        var v: [7]u64 = @splat(0);
        for (&v) |*x| x.* = std.fmt.parseInt(u64, f.next() orelse "0", 10) catch 0;
        // reads, merged, sectors read, ms, writes, merged, sectors written
        t[0] += v[0];
        t[1] += v[4];
        t[2] += v[2] * 512;
        t[3] += v[6] * 512;
    }
    s.system.reads = t[0];
    s.system.writes = t[1];
    s.system.read_bytes = t[2];
    s.system.written_bytes = t[3];
}

fn wholeDisk(dev: []const u8) bool {
    const last = dev[dev.len - 1];
    if (std.mem.startsWith(u8, dev, "nvme") or std.mem.startsWith(u8, dev, "mmcblk")) return std.mem.indexOfScalar(u8, dev, 'p') == null;
    for ([_][]const u8{ "sd", "vd", "xvd", "hd" }) |pre| if (std.mem.startsWith(u8, dev, pre)) return !std.ascii.isDigit(last);
    return false;
}

fn uidOf(s: *Sampler, dir: std.Io.Dir, pid: i32) u32 {
    var buf: [4096]u8 = undefined;
    var path: [64]u8 = undefined;
    const status = dir.readFile(s.io, std.fmt.bufPrint(&path, "{d}/status", .{pid}) catch return 0, &buf) catch return 0;
    const at = std.mem.indexOf(u8, status, "\nUid:") orelse return 0;
    var f = std.mem.tokenizeAny(u8, status[at + 5 ..], " \t\n");
    return std.fmt.parseInt(u32, f.next() orelse "0", 10) catch 0;
}

fn ticks(s: *Sampler) sample.Ticks {
    var buf: [8192]u8 = undefined;
    const stat = std.Io.Dir.cwd().readFile(s.io, "/proc/stat", &buf) catch return .{};
    var lines = std.mem.tokenizeScalar(u8, stat, '\n');
    var cores: u32 = 0;
    var t: sample.Ticks = .{};
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu")) break;
        const one_core = line.len > 3 and line[3] != ' ';
        var f = std.mem.tokenizeScalar(u8, line[3..], ' ');
        if (one_core) _ = f.next();
        var v: [8]u64 = @splat(0);
        for (&v) |*x| x.* = std.fmt.parseInt(u64, f.next() orelse "0", 10) catch 0;
        // user nice system idle iowait irq softirq steal
        const these: sample.Ticks = .{ .user = v[0] + v[1], .system = v[2] + v[5] + v[6] + v[7], .idle = v[3] + v[4] };
        if (one_core) {
            if (cores < sample.max_cores) s.core_ticks[cores] = these;
            cores += 1;
        } else t = these;
    }
    s.system.cores = @max(1, cores);
    s.cores = @min(cores, sample.max_cores);
    return t;
}

fn memory(s: *Sampler) void {
    var buf: [8192]u8 = undefined;
    const info = std.Io.Dir.cwd().readFile(s.io, "/proc/meminfo", &buf) catch return;
    var total: u64 = 0;
    var free: u64 = 0;
    var cached: u64 = 0;
    var available: u64 = 0;
    var swap_total: u64 = 0;
    var swap_free: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, info, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        var f = std.mem.tokenizeAny(u8, line[colon + 1 ..], " ");
        const kb = (std.fmt.parseInt(u64, f.next() orelse "0", 10) catch 0) * 1024;
        const key = line[0..colon];
        if (std.mem.eql(u8, key, "MemAvailable")) available = kb;
        if (std.mem.eql(u8, key, "SwapTotal")) swap_total = kb;
        if (std.mem.eql(u8, key, "SwapFree")) swap_free = kb;
        if (std.mem.eql(u8, key, "MemTotal")) total = kb else if (std.mem.eql(u8, key, "MemFree")) free = kb else if (std.mem.eql(u8, key, "Buffers") or std.mem.eql(u8, key, "Cached") or std.mem.eql(u8, key, "SReclaimable")) cached += kb;
    }
    s.system.mem_total = total;
    s.system.mem_cached = cached;
    s.system.mem_app = total -| free -| cached;
    s.system.mem_wired = 0;
    s.system.mem_compressed = 0;
    s.system.swap_used = swap_total -| swap_free;
    if (total > 0) s.system.pressure = @floatCast(100 - @as(f64, @floatFromInt(available)) / @as(f64, @floatFromInt(total)) * 100);
}

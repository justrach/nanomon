//! The rest of the machine on Linux, from /proc: what it is (the CPU's
//! model, the distribution, the host's name), and how it is doing: load
//! averages and every thread (loadavg), uptime, and bytes through every
//! interface but loopback (net/dev).
const std = @import("std");
const sample = @import("sample.zig");
const Sampler = sample.Sampler;

/// The machine's names, kept for `Info`'s slices.
pub const Text = struct {
    chip: [128]u8 = undefined,
    os: [128]u8 = undefined,
    host: [128]u8 = undefined,
};

fn read(s: *Sampler, path: []const u8, buf: []u8) []const u8 {
    return std.Io.Dir.cwd().readFile(s.io, path, buf) catch "";
}

/// The value of the first line starting with `key`, after its separator.
fn value(text: []const u8, key: []const u8, sep: u8) []const u8 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        const at = std.mem.indexOfScalar(u8, line, sep) orelse continue;
        return std.mem.trim(u8, line[at + 1 ..], " \t\"");
    }
    return "";
}

fn keep(dst: []u8, src: []const u8) []const u8 {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return dst[0..n];
}

/// What the machine is: once.
pub fn machine(s: *Sampler, t: *Text) void {
    var buf: [16384]u8 = undefined;
    s.info.chip = keep(&t.chip, value(read(s, "/proc/cpuinfo", &buf), "model name", ':'));
    s.info.os = keep(&t.os, value(read(s, "/etc/os-release", &buf), "PRETTY_NAME", '='));
    if (s.info.os.len == 0) s.info.os = "Linux";
    s.info.host = keep(&t.host, std.mem.trim(u8, read(s, "/proc/sys/kernel/hostname", &buf), " \n"));
    s.info.fast = s.cores;
    s.info.fast_name = "Cores";
}

/// How the machine is doing: each sample.
pub fn extras(s: *Sampler) void {
    var buf: [16384]u8 = undefined;
    const sy = &s.system;
    // "0.52 0.58 0.59 2/1234 5678": three loads, running/all threads.
    var f = std.mem.tokenizeScalar(u8, read(s, "/proc/loadavg", &buf), ' ');
    for (&sy.load) |*l| l.* = std.fmt.parseFloat(f32, f.next() orelse "0") catch 0;
    if (f.next()) |threads| if (std.mem.indexOfScalar(u8, threads, '/')) |slash| {
        sy.threads = std.fmt.parseInt(u32, threads[slash + 1 ..], 10) catch 0;
    };
    sy.tasks = @intCast(s.procs.items.len);
    var up = std.mem.tokenizeScalar(u8, read(s, "/proc/uptime", &buf), ' ');
    sy.uptime_s = @intFromFloat(@max(0, std.fmt.parseFloat(f64, up.next() orelse "0") catch 0));
    // net/dev: "  eth0: rx_bytes rx_packets … (8 fields) tx_bytes …".
    var in: u64 = 0;
    var out: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, read(s, "/proc/net/dev", &buf), '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " "), "lo")) continue;
        var v = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
        var n: usize = 0;
        while (v.next()) |x| : (n += 1) {
            if (n == 0) in += std.fmt.parseInt(u64, x, 10) catch 0;
            if (n == 8) out += std.fmt.parseInt(u64, x, 10) catch 0;
        }
    }
    sy.net_in = in;
    sy.net_out = out;
}

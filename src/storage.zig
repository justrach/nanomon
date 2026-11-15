//! Capacity, not I/O. One cheap statvfs on the existing sample cadence.
//! Free includes reserved blocks; available is what a normal user may use.
const std = @import("std");
const builtin = @import("builtin");

pub const Volume = struct {
    volume: []const u8 = "/",
    total_bytes: u64,
    used_bytes: u64,
    free_bytes: u64,
    available_bytes: u64,
};

// Darwin uses *32-bit* fsblkcnt_t/fsfilcnt_t even on arm64; glibc/musl
// use 64-bit counters here and reserve six ints. Never assume equal ABIs.
const Counter = if (builtin.os.tag == .macos) u32 else u64;
const Stat = extern struct {
    bsize: c_ulong,
    frsize: c_ulong,
    blocks: Counter,
    bfree: Counter,
    bavail: Counter,
    files: Counter,
    ffree: Counter,
    favail: Counter,
    fsid: c_ulong,
    flag: c_ulong,
    namemax: c_ulong,
    spare: [if (builtin.os.tag == .linux) 6 else 0]c_int,
};
extern "c" fn statvfs(path: [*:0]const u8, stat: *Stat) c_int;

pub fn fromBlocks(block: u64, total: u64, free: u64, available: u64) ?Volume {
    if (block == 0 or total == 0 or free > total or available > free) return null;
    const bytes = std.math.mul(u64, block, total) catch return null;
    const unused = std.math.mul(u64, block, free) catch return null;
    return .{ .total_bytes = bytes, .used_bytes = bytes - unused, .free_bytes = unused, .available_bytes = std.math.mul(u64, block, available) catch return null };
}

/// Binary units are explicit, and compact enough for the existing fact row.
pub fn summary(buf: []u8, v: Volume) []const u8 {
    var left: [32]u8 = undefined;
    var right: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} free / {s}", .{ brief(&left, v.available_bytes), brief(&right, v.total_bytes) }) catch "";
}
pub fn brief(buf: []u8, n: u64) []const u8 {
    const unit: u64 = if (n >= 1 << 40) 1 << 40 else if (n >= 1 << 30) 1 << 30 else if (n >= 1 << 20) 1 << 20 else 1;
    const label = if (unit == 1 << 40) "TiB" else if (unit == 1 << 30) "GiB" else if (unit == 1 << 20) "MiB" else "B";
    const x = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(unit));
    return if (x < 10 and unit > 1) std.fmt.bufPrint(buf, "{d:.1} {s}", .{ x, label }) catch "" else std.fmt.bufPrint(buf, "{d:.0} {s}", .{ x, label }) catch "";
}

pub fn read() ?Volume {
    if (comptime (@sizeOf(usize) != 8 or (builtin.os.tag != .macos and builtin.os.tag != .linux) or builtin.abi.isAndroid())) return null;
    comptime std.debug.assert(@sizeOf(Stat) == (if (builtin.os.tag == .macos) 64 else 112));
    var stat: Stat = undefined;
    if (statvfs("/", &stat) != 0) return null;
    return fromBlocks(stat.frsize, stat.blocks, stat.bfree, stat.bavail);
}

test "capacity preserves reserved space and rejects invalid/overflowing counters" {
    const v = fromBlocks(4096, 100, 30, 20).?;
    try std.testing.expectEqual(@as(u64, 409600), v.total_bytes);
    try std.testing.expectEqual(@as(u64, 286720), v.used_bytes);
    try std.testing.expectEqual(@as(u64, 122880), v.free_bytes);
    try std.testing.expectEqual(@as(u64, 81920), v.available_bytes);
    try std.testing.expect(fromBlocks(0, 10, 2, 1) == null);
    try std.testing.expect(fromBlocks(1, 10, 11, 1) == null);
    try std.testing.expect(fromBlocks(1, 10, 2, 3) == null);
    try std.testing.expect(fromBlocks(4096, std.math.maxInt(u64), 0, 0) == null);
}

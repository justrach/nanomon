//! Demand-only, bounded discovery from sampled process working directories.
//! Permission failures are normal, never stderr spam; no home/disk crawl.
const std = @import("std");
const builtin = @import("builtin");
const wt = @import("worktrees.zig");
const A = std.mem.Allocator;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, size: c_int) c_int;
const Vnode = extern struct { stat: [17]u64, kind: i32, pad: i32, fsid: [2]i32, path: [1024]u8 };

pub fn cwd(a: A, io: std.Io, pid: i32) ?[]const u8 {
    if (comptime builtin.os.tag == .macos) {
        comptime std.debug.assert(@sizeOf(Vnode) == 1176);
        var nodes: [2]Vnode = undefined;
        if (proc_pidinfo(pid, 9, 0, &nodes, @sizeOf(@TypeOf(nodes))) != @sizeOf(@TypeOf(nodes))) return null;
        const path = std.mem.sliceTo(&nodes[0].path, 0);
        if (!wt.validPath(path)) return null;
        return a.dupe(u8, path) catch null;
    } else if (comptime builtin.os.tag == .linux) {
        var name: [64]u8 = undefined;
        const link = std.fmt.bufPrint(&name, "/proc/{d}/cwd", .{pid}) catch return null;
        var buf: [4096]u8 = undefined;
        const n = std.Io.Dir.cwd().readLink(io, link, &buf) catch return null;
        const raw = buf[0..n];
        const suffix = " (deleted)";
        // A process may still hold the removed directory as its cwd. Keep
        // that registration active rather than treating the suffix as a name.
        const path = if (std.mem.endsWith(u8, raw, suffix)) raw[0 .. raw.len - suffix.len] else raw;
        if (!wt.validPath(path)) return null;
        return a.dupe(u8, path) catch null;
    } else return null;
}

/// Cached executable paths already read by the sampler; no new OS reads.
/// Also protects a running binary inside a checkout whose cwd is elsewhere.
pub fn executablePaths(a: A, sampler: *const @import("sample.zig").Sampler, pids: []const i32) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    for (pids[0..@min(512, pids.len)]) |pid| {
        const named = sampler.names.get(pid) orelse continue;
        if (!wt.validPath(named.owned)) continue;
        const dir = std.fs.path.dirname(named.owned) orelse continue;
        try roots.append(a, try a.dupe(u8, dir));
    }
    return roots.items;
}

pub const Paths = struct { roots: []const []const u8, incomplete: bool };
pub fn paths(a: A, io: std.Io, pids: []const i32) !Paths {
    var roots: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var incomplete = pids.len > 512;
    for (pids[0..@min(512, pids.len)]) |pid| {
        const path = cwd(a, io, pid) orelse {
            incomplete = true;
            continue;
        };
        const gop = try seen.getOrPut(a, path);
        if (gop.found_existing) continue;
        try roots.append(a, path);
    }
    return .{ .roots = roots.items, .incomplete = incomplete };
}
pub fn within(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or (std.mem.startsWith(u8, path, root) and
        path.len > root.len and path[root.len] == '/');
}
pub fn active(entry: wt.Entry, roots: []const []const u8) bool {
    for (roots) |path| if (within(path, entry.path)) return true;
    return false;
}

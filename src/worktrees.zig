//! Bounded, read-only Git metadata. No git subprocess, config, hooks, shell,
//! directory sizing or deletion here. Dirty/merged are UNKNOWN until a GUI
//! review probes Git; metadata/mtime alone never authorize removal.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const A = std.mem.Allocator;
const builtin = @import("builtin");
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
pub const max_entries = 200;
pub const Reasons = struct { missing: bool = false, branch_deleted: bool = false, merged: bool = false, untouched: bool = false };
pub const Entry = struct {
    path: []const u8,
    git_dir: []const u8,
    repo: []const u8,
    branch: []const u8 = "",
    head: []const u8 = "",
    is_primary: bool = false,
    locked: bool = false,
    missing: ?bool = null,
    dirty: ?bool = null,
    active: bool = false,
    last_modified_unix_ms: ?i64 = null,
    size_bytes: ?u64 = null,
    reasons: Reasons = .{},
    prunable: bool = false,
    checked: bool = false,
    note: []const u8 = "Needs GUI safety check",

    pub fn stale(e: Entry) bool {
        return e.reasons.missing or e.reasons.branch_deleted or e.reasons.merged or e.reasons.untouched;
    }
};
pub const Snapshot = struct {
    entries: []Entry = &.{},
    truncated: bool = false,
    errors: usize = 0,
    inspected_at_unix_ms: i64 = 0,
};

pub fn validPath(p: []const u8) bool {
    if (p.len == 0 or p.len > 4096 or !std.fs.path.isAbsolute(p) or !std.unicode.utf8ValidateSlice(p)) return false;
    for (p) |ch| if (ch < 32 or ch == 127) return false;
    return true;
}
pub fn validRef(ref: []const u8) bool {
    if (!std.mem.startsWith(u8, ref, "refs/heads/") or ref.len <= 11 or ref.len > 1024) return false;
    if (std.mem.indexOf(u8, ref, "..") != null or std.mem.indexOf(u8, ref, "@{") != null) return false;
    for (ref) |ch| if (ch <= 32 or std.mem.indexOfScalar(u8, "~^:?*[\\", ch) != null or ch == 127) return false;
    var parts = std.mem.splitScalar(u8, ref, '/');
    while (parts.next()) |part| if (part.len == 0 or part[0] == '.' or std.mem.endsWith(u8, part, ".lock")) return false;
    return std.unicode.utf8ValidateSlice(ref);
}
pub fn validOid(oid: []const u8) bool {
    if (oid.len != 40 and oid.len != 64) return false;
    for (oid) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}
pub fn join(a: A, x: []const u8, y: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ x, y });
}
/// All metadata opens reject a final symlink, non-files and >1 MiB files.
pub fn readFile(a: A, io: Io, path: []const u8) !?[]const u8 {
    return readBounded(a, io, path, 8192);
}
fn readBounded(a: A, io: Io, path: []const u8, limit: usize) !?[]const u8 {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.UnsupportedPlatform;
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    // A FIFO substituted for metadata must never block open().
    const flags: c_int = if (builtin.os.tag == .macos) 0x4 | 0x100 | 0x1000000 else 0o4000 | 0o400000 | 0o2000000;
    const fd = open(z, flags);
    if (fd < 0) return switch (std.c.errno(fd)) {
        .NOENT => null,
        else => error.InvalidMetadata,
    };
    const f: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer f.close(io);
    const stat = try f.stat(io);
    if (stat.kind != .file or stat.size > limit) return error.InvalidMetadata;
    var buf: [4096]u8 = undefined;
    var reader = f.reader(io, &buf);
    return try reader.interface.allocRemaining(a, .limited(limit));
}
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, "\r\n");
}
fn exists(io: Io, p: []const u8) !bool {
    _ = Dir.cwd().statFile(io, p, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// Only ordinary .git directories / linked worktrees are supported. Bare
/// repositories and separate git-dir layouts are deliberately not guessed.
pub fn repository(a: A, io: Io, start: []const u8) !?[]const u8 {
    if (!validPath(start)) return null;
    var path: []const u8 = try Dir.realPathFileAbsoluteAlloc(io, start, a);
    for (0..24) |_| {
        const git = try join(a, path, ".git");
        const stat = Dir.cwd().statFile(io, git, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                path = std.fs.path.dirname(path) orelse return null;
                continue;
            },
            else => return err,
        };
        var common = git;
        if (stat.kind == .file) {
            const text = trim((try readFile(a, io, git)) orelse return error.InvalidMetadata);
            if (!std.mem.startsWith(u8, text, "gitdir: ")) return error.InvalidMetadata;
            const admin = try std.fs.path.resolve(a, &.{ path, text[8..] });
            const rel = trim((try readFile(a, io, try join(a, admin, "commondir"))) orelse return error.InvalidMetadata);
            common = try std.fs.path.resolve(a, &.{ admin, rel });
        } else if (stat.kind != .directory) return error.InvalidMetadata;
        common = try Dir.realPathFileAbsoluteAlloc(io, common, a);
        if (!validPath(common) or !std.mem.eql(u8, std.fs.path.basename(common), ".git")) return error.UnsupportedRepository;
        return common;
    }
    return null;
}

fn head(a: A, io: Io, e: *Entry, common: []const u8) !void {
    const h = trim((try readFile(a, io, try join(a, e.git_dir, "HEAD"))) orelse return error.InvalidMetadata);
    if (validOid(h)) {
        e.head = h;
        return;
    }
    if (!std.mem.startsWith(u8, h, "ref: ") or !validRef(h[5..])) return error.InvalidMetadata;
    const ref = h[5..];
    e.branch = ref[11..];
    if (try readFile(a, io, try join(a, common, ref))) |loose| {
        const oid = trim(loose);
        if (!validOid(oid)) return error.InvalidMetadata;
        e.head = oid;
        return;
    }
    // Packed refs can be large; do not retain one copy per worktree in the
    // request arena. Only the matching OID is copied out of this scratch area.
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    if (try readBounded(scratch.allocator(), io, try join(a, common, "packed-refs"), 1 << 20)) |packed_refs| {
        var lines = std.mem.splitScalar(u8, packed_refs, '\n');
        while (lines.next()) |line| {
            const sep = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            if (std.mem.eql(u8, line[sep + 1 ..], ref) and validOid(line[0..sep])) {
                e.head = try a.dupe(u8, line[0..sep]);
                return;
            }
        }
    }
    e.reasons.branch_deleted = !e.is_primary;
}
fn inspect(a: A, io: Io, e: *Entry, common: []const u8, now: i64, days: usize) !void {
    try head(a, io, e, common);
    if (!e.is_primary) e.locked = try exists(io, try join(a, e.git_dir, "locked"));
    const stat = Dir.cwd().statFile(io, e.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            e.missing = true;
            e.reasons.missing = true;
            e.size_bytes = 0;
            e.note = "Missing checkout; metadata only (no directory bytes to reclaim)";
            return;
        },
        else => return err,
    };
    e.missing = false;
    if (stat.kind != .directory) return error.InvalidMetadata;
    e.last_modified_unix_ms = stat.mtime.toMilliseconds();
    e.reasons.untouched = !e.is_primary and now > stat.mtime.toMilliseconds() and
        now - stat.mtime.toMilliseconds() > @as(i64, @intCast(days)) * 86400000;
}

pub fn scan(a: A, io: Io, roots: []const []const u8, now: i64, days: usize) !Snapshot {
    var result: Snapshot = .{ .inspected_at_unix_ms = now };
    var rows: std.ArrayList(Entry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (roots) |root| {
        const common = (repository(a, io, root) catch {
            result.errors += 1;
            continue;
        }) orelse continue;
        const gop = try seen.getOrPut(a, common);
        if (gop.found_existing) continue;
        if (rows.items.len >= max_entries) {
            result.truncated = true;
            break;
        }
        const repo = std.fs.path.dirname(common) orelse continue;
        var primary: Entry = .{ .repo = repo, .path = repo, .git_dir = common, .is_primary = true };
        inspect(a, io, &primary, common, now, days) catch {
            result.errors += 1;
            continue;
        };
        primary.note = "Primary checkout — kept";
        try rows.append(a, primary);
        var dir = Dir.cwd().openDir(io, try join(a, common, "worktrees"), .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                result.errors += 1;
                continue;
            },
        };
        defer dir.close(io);
        var it = dir.iterate();
        var visited: usize = 0;
        while (try it.next(io)) |item| {
            visited += 1;
            if (visited > max_entries or rows.items.len >= max_entries) {
                result.truncated = true;
                break;
            }
            if (item.kind != .directory) continue;
            const admin = try join(a, try join(a, common, "worktrees"), item.name);
            const gitfile = trim((readFile(a, io, try join(a, admin, "gitdir")) catch {
                result.errors += 1;
                continue;
            }) orelse continue);
            if (!validPath(gitfile) or !std.mem.eql(u8, std.fs.path.basename(gitfile), ".git")) {
                result.errors += 1;
                continue;
            }
            const path = try std.fs.path.resolve(a, &.{std.fs.path.dirname(gitfile) orelse continue});
            var e: Entry = .{ .path = path, .repo = repo, .git_dir = admin };
            inspect(a, io, &e, common, now, days) catch {
                result.errors += 1;
                continue;
            };
            try rows.append(a, e);
        }
    }
    result.entries = rows.items;
    return result;
}

/// A second independent gate, also used after revalidation immediately before
/// git worktree remove. No force flag exists anywhere in the cleanup path.
pub fn eligible(e: Entry) bool {
    return e.checked and !e.is_primary and !e.locked and e.missing != null and
        e.dirty == false and !e.active and e.branch.len > 0 and validOid(e.head) and e.stale();
}
pub fn same(a: Entry, b: Entry) bool {
    return std.mem.eql(u8, a.path, b.path) and std.mem.eql(u8, a.git_dir, b.git_dir) and
        std.mem.eql(u8, a.repo, b.repo) and std.mem.eql(u8, a.head, b.head) and std.mem.eql(u8, a.branch, b.branch);
}

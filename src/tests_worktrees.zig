//! Real Git repositories only in temporary directories; no user checkouts,
//! agent state, system clipboard or windows. Removal tests cannot escape tmp.
const std = @import("std");
const builtin = @import("builtin");
const wt = @import("worktrees.zig");
const checks = @import("worktree_git.zig");
const discovery = @import("worktree_discovery.zig");
const io = std.testing.io;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator = .init(std.testing.allocator),
    root: []const u8 = "",
    repo: []const u8 = "",
    now: i64 = 0,

    fn init() !Fixture {
        if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
        var f: Fixture = .{ .tmp = std.testing.tmpDir(.{}) };
        errdefer f.deinit();
        return f;
    }
    fn setup(f: *Fixture) !void {
        const a = f.arena.allocator();
        var buf: [4096]u8 = undefined;
        const n = try f.tmp.dir.realPath(io, &buf);
        f.root = try a.dupe(u8, buf[0..n]);
        f.repo = try wt.join(a, f.root, "repo");
        try f.tmp.dir.createDir(io, "repo", .default_dir);
        f.now = std.Io.Clock.real.now(io).toMilliseconds() + 15 * 86400000;
        try f.run(f.repo, &.{ "init", "-b", "main" });
        try f.run(f.repo, &.{ "config", "user.name", "Fixture" });
        try f.run(f.repo, &.{ "config", "user.email", "fixture@example.invalid" });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "repo/tracked", .data = "original\n" });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "repo/.gitignore", .data = "build/\n" });
        try f.run(f.repo, &.{ "add", "." });
        try f.run(f.repo, &.{ "commit", "-m", "fixture" });
    }
    fn run(f: *Fixture, repo: []const u8, argv: []const []const u8) !void {
        const r = try checks.git(f.arena.allocator(), io, repo, argv);
        if (r.term != .exited or r.term.exited != 0) return error.FixtureGitFailed;
    }
    fn add(f: *Fixture, name: []const u8) ![]const u8 {
        const path = try wt.join(f.arena.allocator(), f.root, name);
        try f.run(f.repo, &.{ "worktree", "add", "-b", name, path });
        return path;
    }
    fn snapshot(f: *Fixture) !wt.Snapshot {
        return wt.scan(f.arena.allocator(), io, &.{f.repo}, f.now, 14);
    }
    fn entry(f: *Fixture, path: []const u8) !wt.Entry {
        const s = try f.snapshot();
        for (s.entries) |e| if (std.mem.eql(u8, e.path, path)) return e;
        return error.EntryNotFound;
    }
    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.tmp.cleanup();
    }
};

test "metadata is read-only, deduplicated and never declares an unprobed checkout safe" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const path = try f.add("candidate");
    const a = f.arena.allocator();
    const s = try wt.scan(a, io, &.{ f.repo, path, f.repo }, f.now, 14);
    try equal(@as(usize, 2), s.entries.len);
    try expect(s.entries[0].is_primary);
    const e = try f.entry(path);
    try expect(e.reasons.untouched);
    try expect(e.dirty == null and !e.checked and !e.prunable);
    try expect(!wt.eligible(e));
}

test "GUI revalidates and removes only an explicitly selected clean temporary worktree" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const path = try f.add("candidate");
    const sibling = try f.add("keep");
    var e = try f.entry(path);
    checks.probe(f.arena.allocator(), io, &e, &.{});
    try expect(e.prunable and wt.eligible(e) and e.reasons.merged);
    try checks.remove(f.arena.allocator(), io, e, &.{}, f.now, 14);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{}));
    _ = try std.Io.Dir.cwd().statFile(io, sibling, .{});
    _ = try std.Io.Dir.cwd().statFile(io, f.repo, .{});
    // Removing a checkout does not delete its branch.
    try f.run(f.repo, &.{ "show-ref", "--verify", "refs/heads/candidate" });
}

test "changes after preview, including ignored files, are never forced away" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const path = try f.add("candidate");
    var e = try f.entry(path);
    checks.probe(f.arena.allocator(), io, &e, &.{});
    try expect(e.prunable);
    try f.tmp.dir.createDir(io, "candidate/build", .default_dir);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "candidate/build/important", .data = "keep this ignored file" });
    try std.testing.expectError(error.WorktreeChanged, checks.remove(f.arena.allocator(), io, e, &.{}, f.now, 14));
    var fresh = try f.entry(path);
    checks.probe(f.arena.allocator(), io, &fresh, &.{});
    try expect(fresh.dirty == true and !fresh.prunable);
    _ = try f.tmp.dir.statFile(io, "candidate/build/important", .{});
}

test "primary locked active detached and dirty worktrees are retained" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const a = f.arena.allocator();
    var primary = try f.entry(f.repo);
    checks.probe(a, io, &primary, &.{});
    try expect(!primary.prunable);
    const path = try f.add("candidate");
    try f.run(f.repo, &.{ "worktree", "lock", path });
    var e = try f.entry(path);
    checks.probe(a, io, &e, &.{});
    try expect(e.locked and !e.prunable);
    try f.run(f.repo, &.{ "worktree", "unlock", path });
    e = try f.entry(path);
    checks.probe(a, io, &e, &.{try wt.join(a, path, "subdirectory")});
    try expect(e.active and !e.prunable);
    try f.run(path, &.{ "checkout", "--detach" });
    e = try f.entry(path);
    checks.probe(a, io, &e, &.{});
    try expect(e.branch.len == 0 and !e.prunable);
    try f.run(path, &.{ "checkout", "candidate" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "candidate/tracked", .data = "unsaved\n" });
    e = try f.entry(path);
    checks.probe(a, io, &e, &.{});
    try expect(e.dirty == true and !e.prunable);
}

test "new untracked files, new locks, new commits and new activity invalidate confirmation" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const a = f.arena.allocator();
    const path = try f.add("candidate");
    var e = try f.entry(path);
    checks.probe(a, io, &e, &.{});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "candidate/unsaved", .data = "preserve" });
    try std.testing.expectError(error.WorktreeChanged, checks.remove(a, io, e, &.{}, f.now, 14));
    try f.tmp.dir.deleteFile(io, "candidate/unsaved");
    try f.run(f.repo, &.{ "worktree", "lock", path });
    try std.testing.expectError(error.WorktreeChanged, checks.remove(a, io, e, &.{}, f.now, 14));
    try f.run(f.repo, &.{ "worktree", "unlock", path });
    try std.testing.expectError(error.WorktreeChanged, checks.remove(a, io, e, &.{path}, f.now, 14));
    try f.run(path, &.{ "commit", "--allow-empty", "-m", "new HEAD after preview" });
    try std.testing.expectError(error.WorktreeChanged, checks.remove(a, io, e, &.{}, f.now, 14));
    _ = try std.Io.Dir.cwd().statFile(io, path, .{});
}

test "missing checkouts clear only verified-clean registration and never claim reclaimed directory bytes" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const path = try f.add("candidate");
    try f.tmp.dir.deleteTree(io, "candidate");
    var e = try f.entry(path);
    checks.probe(f.arena.allocator(), io, &e, &.{});
    try expect(e.missing == true and e.reasons.missing and e.prunable);
    try equal(@as(?u64, 0), e.size_bytes);
    try checks.remove(f.arena.allocator(), io, e, &.{}, f.now, 14);
    try equal(@as(usize, 1), (try f.snapshot()).entries.len);
    try f.run(f.repo, &.{ "show-ref", "--verify", "refs/heads/candidate" });
}

test "missing checkout with staged data keeps its last saved index" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const path = try f.add("candidate");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "candidate/tracked", .data = "last saved staged changes" });
    try f.run(path, &.{ "add", "tracked" });
    try f.tmp.dir.deleteTree(io, "candidate");
    var e = try f.entry(path);
    checks.probe(f.arena.allocator(), io, &e, &.{});
    try expect(!e.prunable and e.dirty == null);
    _ = try std.Io.Dir.cwd().statFile(io, try wt.join(f.arena.allocator(), e.git_dir, "index"), .{});
}

test "custom Git filters are refused before status can execute one" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const path = try f.add("candidate");
    try f.run(f.repo, &.{ "config", "filter.sentinel.clean", "false" });
    var e = try f.entry(path);
    checks.probe(f.arena.allocator(), io, &e, &.{});
    try expect(!e.prunable and !e.checked and e.dirty == null);
    try expect(std.mem.indexOf(u8, e.note, "filters") != null);
}

test "size is logical, bounded, cancelable and does not follow directory symlinks" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    try f.tmp.dir.createDir(io, "sizing", .default_dir);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "sizing/a", .data = "12345" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "do not count this" });
    try f.tmp.dir.symLink(io, "../outside", "sizing/link", .{});
    var stop: checks.Cancel = .init(false);
    try equal(@as(?u64, 5), checks.size(io, try wt.join(f.arena.allocator(), f.root, "sizing"), &stop));
    stop.store(true, .release);
    try expect(checks.size(io, f.root, &stop) == null);
}

test "native cwd discovery protects only our temporary helper, including a deleted Linux cwd" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const path = try f.add("candidate");
    const a = f.arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "10" }, .cwd = .{ .path = path }, .environ_map = &env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer child.kill(io);
    const found = discovery.cwd(a, io, @intCast(child.id.?)) orelse return error.NoHelperCwd;
    try std.testing.expectEqualStrings(path, found);
    var e = try f.entry(path);
    checks.probe(a, io, &e, &.{found});
    try expect(e.active and !e.prunable);
    if (comptime builtin.os.tag == .linux) {
        try f.tmp.dir.deleteTree(io, "candidate");
        const deleted = discovery.cwd(a, io, @intCast(child.id.?)) orelse return error.NoDeletedHelperCwd;
        try std.testing.expectEqualStrings(path, deleted);
        e = try f.entry(path);
        checks.probe(a, io, &e, &.{deleted});
        try expect(e.missing == true and e.active and !e.prunable);
    }
}

test "cached executable directories are copied and protect a running binary's checkout" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var sampler: @import("sample.zig").Sampler = .{ .gpa = std.testing.allocator, .io = io };
    defer sampler.deinit();
    const owned = try std.testing.allocator.dupe(u8, "/demo/wt/zig-out/bin/app");
    try sampler.names.put(std.testing.allocator, 42, .{ .owned = owned, .name = "app", .bundle = "" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const roots = try discovery.executablePaths(arena.allocator(), &sampler, &.{ 42, 99 });
    @memset(owned, 'x'); // The worker must not borrow mutable sampler metadata.
    try equal(@as(usize, 1), roots.len);
    try std.testing.expectEqualStrings("/demo/wt/zig-out/bin", roots[0]);
    try expect(discovery.active(.{ .path = "/demo/wt", .git_dir = "/demo/.git/worktrees/wt", .repo = "/demo/main" }, roots));
}

test "packed refs survive scratch allocator teardown" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const path = try f.add("candidate");
    try f.run(f.repo, &.{ "pack-refs", "--all" });
    const e = try f.entry(path);
    try expect(wt.validOid(e.head));
    var checked = e;
    checks.probe(f.arena.allocator(), io, &checked, &.{});
    try expect(checked.prunable);
}

test "missing intent-to-add index is retained" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const path = try f.add("candidate");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "candidate/new", .data = "not yet staged" });
    try f.run(path, &.{ "add", "-N", "new" });
    try f.tmp.dir.deleteTree(io, "candidate");
    var e = try f.entry(path);
    checks.probe(f.arena.allocator(), io, &e, &.{});
    try expect(!e.prunable);
}

test "changed administrative registration cannot authorize a stale preview" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const path = try f.add("candidate");
    const a = f.arena.allocator();
    var e = try f.entry(path);
    checks.probe(a, io, &e, &.{});
    try expect(e.prunable);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try wt.join(a, e.git_dir, "commondir"), .data = "../../other-repo\n" });
    try std.testing.expectError(error.WorktreeChanged, checks.remove(a, io, e, &.{}, f.now, 14));
    _ = try std.Io.Dir.cwd().statFile(io, path, .{});
}

test "a tracked symlink removal cannot delete its external temporary target" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const path = try f.add("candidate");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "preserve target" });
    try f.tmp.dir.symLink(io, "../outside", "candidate/link", .{});
    try f.run(path, &.{ "add", "link" });
    try f.run(path, &.{ "commit", "-m", "symlink fixture" });
    var e = try f.entry(path);
    checks.probe(f.arena.allocator(), io, &e, &.{});
    try expect(e.prunable);
    try checks.remove(f.arena.allocator(), io, e, &.{}, f.now, 14);
    _ = try f.tmp.dir.statFile(io, "outside", .{});
}

test "metadata FIFO substitution never blocks the read-only reader" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const c = struct {
        extern "c" fn mkfifo([*:0]const u8, c_uint) c_int;
    };
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const a = f.arena.allocator();
    const fifo = try a.dupeSentinel(u8, try wt.join(a, f.root, "pipe"), 0);
    try equal(@as(c_int, 0), c.mkfifo(fifo, 0o600));
    try std.testing.expectError(error.InvalidMetadata, wt.readFile(a, io, fifo));
}

test "metadata rejects symlink files, malformed refs and path controls" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setup();
    const a = f.arena.allocator();
    const path = try f.add("candidate");
    const e = try f.entry(path);
    try f.tmp.dir.symLink(io, "../tracked", "repo/link", .{});
    try std.testing.expectError(error.InvalidMetadata, wt.readFile(a, io, try wt.join(a, f.repo, "link")));
    try expect(!wt.validRef("refs/heads/../../escape"));
    try expect(!wt.validRef("refs/heads/name\ninstruction"));
    try expect(!wt.validPath("/tmp/a\nnot-an-instruction"));
    try expect(!discovery.within("/tmp/repo-other", "/tmp/repo"));
    try expect(!wt.same(e, .{ .path = "/different", .repo = e.repo, .git_dir = e.git_dir }));
}

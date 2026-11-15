//! GUI-only Git safety checks and explicit single-worktree removal. Never
//! imported by MCP. No shell, force, recursive delete, prune-all or hooks.
const std = @import("std");
const wt = @import("worktrees.zig");
const discovery = @import("worktree_discovery.zig");
const A = std.mem.Allocator;
pub const Cancel = std.atomic.Value(bool);

pub fn git(a: A, io: std.Io, repo: []const u8, args: []const []const u8) !std.process.RunResult {
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("LC_ALL", "C");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_TERMINAL_PROMPT", "0");
    try env.put("COMMAND_LINE_INSTALL", "1"); // macOS stub must not open an installer
    try env.put("GIT_ATTR_NOSYSTEM", "1");
    try env.put("GIT_OPTIONAL_LOCKS", "0");
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "/usr/bin/git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false", "-c", "protocol.allow=never", "-C", repo });
    try argv.appendSlice(a, args);
    return std.process.run(a, io, .{ .argv = argv.items, .environ_map = &env, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(8192), .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } } });
}
fn ok(r: std.process.RunResult) bool {
    return r.term == .exited and r.term.exited == 0;
}
fn free(a: A, r: std.process.RunResult) void {
    a.free(r.stdout);
    a.free(r.stderr);
}

pub fn probe(a: A, io: std.Io, e: *wt.Entry, active_roots: []const []const u8) void {
    e.prunable = false;
    e.checked = false;
    e.active = discovery.active(e.*, active_roots);
    if (e.is_primary) {
        e.note = "Primary checkout — kept";
        return;
    }
    if (e.locked) {
        e.note = "Locked — kept";
        return;
    }
    if (e.missing == null) {
        e.note = "Unknown checkout state — kept";
        return;
    }
    if (e.active) {
        e.note = "A sampled process is working here — kept";
        return;
    }
    if (e.branch.len == 0 or !wt.validOid(e.head)) {
        e.note = "Detached/unresolved HEAD — kept";
        return;
    }
    if (!registered(a, io, e.*)) {
        e.note = "Registration changed or unsupported — kept";
        return;
    }
    if (e.missing == true) {
        probeMissing(a, io, e);
        return;
    }
    const stat = std.Io.Dir.cwd().statFile(io, e.path, .{ .follow_symlinks = false }) catch {
        e.note = "Unreadable checkout — kept";
        return;
    };
    if (stat.kind != .directory) {
        e.note = "Not a real directory — kept";
        return;
    }
    const filters = git(a, io, e.path, &.{ "config", "--get-regexp", "^filter\\." }) catch {
        e.note = "Git config check unavailable — kept";
        return;
    };
    defer free(a, filters);
    if (filters.term != .exited or (filters.term.exited != 0 and filters.term.exited != 1) or filters.stdout.len > 0) {
        e.note = "Custom Git filters/config require manual review — kept";
        return;
    }
    const submodules = wt.readFile(a, io, wt.join(a, e.path, ".gitmodules") catch return) catch {
        e.note = "Unreadable submodule metadata — kept";
        return;
    };
    if (submodules != null) {
        e.note = "Submodules require manual review — kept";
        return;
    }
    const status = git(a, io, e.path, &.{ "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching", "--ignore-submodules=all" }) catch {
        e.note = "Git status failed or exceeded its bound — kept";
        return;
    };
    defer free(a, status);
    if (!ok(status)) {
        e.note = "Git status unavailable — kept";
        return;
    }
    e.dirty = status.stdout.len != 0;
    if (e.dirty.?) {
        e.note = "Changed, untracked or ignored files — kept";
        return;
    }
    const head = git(a, io, e.path, &.{ "rev-parse", "--verify", "HEAD" }) catch return;
    defer free(a, head);
    if (!ok(head) or !std.mem.eql(u8, std.mem.trim(u8, head.stdout, "\r\n"), e.head)) {
        e.note = "HEAD changed during review — kept";
        return;
    }
    const merged = git(a, io, e.repo, &.{ "merge-base", "--is-ancestor", e.head, "refs/heads/main" }) catch return;
    defer free(a, merged);
    e.reasons.merged = ok(merged);
    e.checked = true;
    e.prunable = wt.eligible(e.*);
    e.note = if (e.prunable) "Clean candidate — review before clearing" else "No stale reason — kept";
}

fn registered(a: A, io: std.Io, e: wt.Entry) bool {
    const common = wt.join(a, e.repo, ".git") catch return false;
    const rel = (wt.readFile(a, io, wt.join(a, e.git_dir, "commondir") catch return false) catch return false) orelse return false;
    const resolved = std.fs.path.resolve(a, &.{ e.git_dir, std.mem.trim(u8, rel, "\r\n") }) catch return false;
    if (!std.mem.eql(u8, resolved, common)) return false;
    if (e.missing == true) return true;
    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(io, e.path, a) catch return false;
    if (!std.mem.eql(u8, canonical, e.path)) return false;
    const pointer = (wt.readFile(a, io, wt.join(a, e.path, ".git") catch return false) catch return false) orelse return false;
    const text = std.mem.trim(u8, pointer, "\r\n");
    if (!std.mem.startsWith(u8, text, "gitdir: ")) return false;
    const admin = std.fs.path.resolve(a, &.{ e.path, text[8..] }) catch return false;
    return std.mem.eql(u8, admin, e.git_dir);
}

// A missing directory has zero directory bytes to reclaim. Before removing
// its registration, prove its saved index has no staged/unmerged/intent-to-add
// changes and no submodule metadata. Never throw away an unknown saved index.
fn probeMissing(a: A, io: std.Io, e: *wt.Entry) void {
    e.note = "Missing checkout; saved index not verified — kept";
    const modules = wt.join(a, e.git_dir, "modules") catch return;
    if (std.Io.Dir.cwd().statFile(io, modules, .{ .follow_symlinks = false })) |_| return else |err| {
        if (err != error.FileNotFound) return;
    }
    const index = wt.join(a, e.git_dir, "index") catch return;
    const index_stat = std.Io.Dir.cwd().statFile(io, index, .{ .follow_symlinks = false }) catch return;
    if (index_stat.kind != .file or index_stat.size > 64 << 20) return;
    const tree = git(a, io, e.repo, &.{ "--git-dir", e.git_dir, "ls-tree", "HEAD", "--", ".gitmodules" }) catch return;
    defer free(a, tree);
    if (!ok(tree) or tree.stdout.len != 0) return;
    const status = git(a, io, e.repo, &.{ "--git-dir", e.git_dir, "--work-tree", e.path, "diff-index", "--cached", "--quiet", "--ita-visible-in-index", "HEAD", "--" }) catch return;
    defer free(a, status);
    if (!ok(status)) return;
    e.dirty = false;
    e.checked = true;
    e.prunable = wt.eligible(e.*);
    e.note = "Missing checkout, saved index clean — registration only (0 directory bytes)";
}

/// Estimate logical bytes, not allocated/reclaimable APFS bytes. Never follows
/// symlinks, stops after 20k entries, honors cancellation; unknown stays null.
pub fn size(io: std.Io, path: []const u8, stop: *Cancel) ?u64 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch return null;
    defer dir.close(io);
    const Frame = struct { dir: std.Io.Dir, it: std.Io.Dir.Iterator };
    var stack: [32]Frame = undefined;
    var depth: usize = 1;
    stack[0] = .{ .dir = dir, .it = dir.iterate() };
    // The root is closed above; close all children even on a budget/error exit.
    defer while (depth > 1) {
        depth -= 1;
        stack[depth].dir.close(io);
    };
    var total: u64 = 0;
    var count: usize = 0;
    while (depth > 0) {
        if (stop.load(.acquire)) return null;
        const frame = &stack[depth - 1];
        const item = (frame.it.next(io) catch return null) orelse {
            if (depth == 1) break;
            depth -= 1;
            stack[depth].dir.close(io);
            continue;
        };
        count += 1;
        if (count > 20000) return null;
        if (item.kind == .directory) {
            if (depth == stack.len) return null;
            const child = frame.dir.openDir(io, item.name, .{ .iterate = true, .follow_symlinks = false }) catch return null;
            stack[depth] = .{ .dir = child, .it = child.iterate() };
            depth += 1;
        } else if (item.kind == .file) {
            const stat = frame.dir.statFile(io, item.name, .{ .follow_symlinks = false }) catch return null;
            if (stat.kind != .file) return null;
            total = std.math.add(u64, total, stat.size) catch return null;
        }
    }
    return total;
}

pub fn remove(a: A, io: std.Io, expected: wt.Entry, roots: []const []const u8, now: i64, days: usize) !void {
    if (!wt.eligible(expected) or !expected.prunable) return error.UnsafeWorktree;
    const fresh = try wt.scan(a, io, &.{expected.repo}, now, days);
    if (fresh.truncated or fresh.errors > 0) return error.IncompleteRevalidation;
    for (fresh.entries) |entry| {
        if (!wt.same(expected, entry)) continue;
        var checked = entry;
        probe(a, io, &checked, roots);
        if (!wt.eligible(checked) or !checked.prunable) return error.WorktreeChanged;
        const r = try git(a, io, checked.repo, &.{ "worktree", "remove", "--", checked.path });
        defer free(a, r);
        if (!ok(r)) return error.GitRefusedRemoval;
        return;
    }
    return error.WorktreeChanged;
}

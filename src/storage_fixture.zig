//! Synthetic storage/worktree fixture, only for tests/offscreen previews.
//! No filesystem discovery, Git operation or cleanup is performed.
const std = @import("std");
const App = @import("app.zig").App;
const wt = @import("worktrees.zig");
pub fn attach(a: *App) !void {
    a.sampler.system.storage = .{ .total_bytes = 512 << 30, .used_bytes = 370 << 30, .free_bytes = 142 << 30, .available_bytes = 142 << 30 };
    a.worktrees.latest = .{ .arena = .init(a.sampler.gpa) };
    const alloc = a.worktrees.latest.?.arena.allocator();
    const entries = try alloc.dupe(wt.Entry, &.{
        .{ .path = "/demo/nanomon", .repo = "/demo/nanomon", .git_dir = "/demo/nanomon/.git", .branch = "main", .is_primary = true, .missing = false, .note = "Primary checkout — kept" },
        .{ .path = "/demo/nanomon-old-panels", .repo = "/demo/nanomon", .git_dir = "/demo/nanomon/.git/worktrees/old-panels", .branch = "feat/panels", .head = "1111111111111111111111111111111111111111", .missing = false, .dirty = false, .checked = true, .prunable = true, .size_bytes = 4200 << 20, .reasons = .{ .merged = true, .untouched = true }, .note = "Clean candidate — review before clearing" },
        .{ .path = "/demo/nanomon-agent-work", .repo = "/demo/nanomon", .git_dir = "/demo/nanomon/.git/worktrees/agent-work", .branch = "agent/work", .missing = false, .dirty = true, .size_bytes = 1300 << 20, .reasons = .{ .untouched = true }, .note = "Changed, untracked or ignored files — kept" },
        .{ .path = "/demo/nanomon-release", .repo = "/demo/nanomon", .git_dir = "/demo/nanomon/.git/worktrees/release", .branch = "release", .missing = false, .locked = true, .size_bytes = 900 << 20, .reasons = .{ .untouched = true }, .note = "Locked — kept" },
        .{ .path = "/demo/nanomon-missing", .repo = "/demo/nanomon", .git_dir = "/demo/nanomon/.git/worktrees/missing", .branch = "old", .missing = true, .reasons = .{ .missing = true }, .note = "Missing checkout — metadata only; no directory to clear" },
    });
    a.worktrees.latest.?.snapshot = .{ .entries = entries, .inspected_at_unix_ms = 1794700800000 };
    a.worktrees.message = "Synthetic preview — no repositories were scanned or cleared.";
}

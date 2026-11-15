//! Worker completion/cancellation use only a temporary Git repository and
//! impossible PIDs, never the developer's repositories or process directories.
const std = @import("std");
const builtin = @import("builtin");
const App = @import("app.zig").App;
const Manager = @import("worktree_worker.zig").Manager;
const io = std.testing.io;

test "worktree worker is explicit, coalesces busy requests, and publishes a whole result" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: App = .init(std.testing.allocator, io);
    defer a.deinit();
    a.live = false;
    try std.testing.expect(a.worktrees.thread == null and a.worktrees.latest == null);
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    a.worktrees.gpa = std.testing.allocator;
    a.worktrees.selected_repo = try std.testing.allocator.dupe(u8, path[0..n]);
    a.worktrees.start(&a, null);
    try std.testing.expect(a.worktrees.busy);
    const request = a.worktrees.request.?.pids.ptr;
    a.worktrees.start(&a, null);
    try std.testing.expectEqual(request, a.worktrees.request.?.pids.ptr);
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5_000_000_000;
    // Test-only wait. Production has only a readable-pipe event, no timer.
    while (!a.worktrees.ready.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds > deadline) return error.WorkerTimeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    a.worktrees.take();
    try std.testing.expect(!a.worktrees.busy and a.worktrees.thread == null);
    try std.testing.expectEqual(@as(usize, 0), a.worktrees.latest.?.snapshot.entries.len);
    try std.testing.expect(a.worktrees.request == null and a.worktrees.slot == null);
}

test "teardown cancels pending pipe wake and joins before releasing request and owner" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: App = .init(std.testing.allocator, io);
    defer a.deinit();
    a.live = false;
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    a.worktrees.gpa = std.testing.allocator;
    a.worktrees.selected_repo = try std.testing.allocator.dupe(u8, path[0..n]);
    a.worktrees.start(&a, null);
    a.worktrees.deinit();
    try std.testing.expect(a.worktrees.thread == null and a.worktrees.watch == null);
    try std.testing.expect(a.worktrees.latest == null and a.worktrees.request == null);
    try std.testing.expectEqual([2]c_int{ -1, -1 }, a.worktrees.fds);
    // Reusing the same owner storage cannot inherit the prior request/result.
    a.worktrees = .{};
    try std.testing.expect(!a.worktrees.ready.load(.acquire));
}

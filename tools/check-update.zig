//! Exercise the actual shared updater without windows or relaunching.
//! Called only by verify-release.py, with copies in its marked temp root.
const std = @import("std");
const nanoui = @import("nanoui");

pub fn main(init: std.process.Init) !void {
    if (comptime @import("builtin").os.tag != .macos) return error.MacOnly;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 6) return error.ExpectedBundleFeedOldNewOutcome;
    const root = init.environ_map.get("NANOMON_UPDATE_TEST_ROOT") orelse return error.TestRootRequired;
    if (!std.fs.path.isAbsolute(root) or std.mem.indexOf(u8, root, "/nanomon-release-") == null) return error.NotTestRoot;
    const marker = try std.fs.path.join(a, &.{ root, "update-fixture" });
    const marked = try std.Io.Dir.cwd().readFileAlloc(init.io, marker, a, .limited(64));
    if (!std.mem.eql(u8, marked, "nanomon headless update fixture\n")) return error.NotTestRoot;
    const prefix = try std.fmt.allocPrint(a, "{s}/", .{root});
    const feed_prefix = try std.fmt.allocPrint(a, "file://{s}/", .{root});
    if (!std.mem.startsWith(u8, args[1], prefix) or !std.mem.startsWith(u8, args[2], feed_prefix)) return error.OutsideTestRoot;
    const u = try init.gpa.create(nanoui.Updater);
    u.* = .{
        .gpa = init.gpa,
        .io = init.io,
        .options = .{ .repo = "unused/local-fixture", .asset = "nanomon-macos-arm64.zip", .name = "unused" },
        .bundle = try init.gpa.dupe(u8, args[1]),
        .feed = try init.gpa.dupe(u8, args[2]),
        .current = try init.gpa.dupe(u8, args[3]),
        .cache = try std.fs.path.join(init.gpa, &.{ std.fs.path.dirname(args[1]).?, "cache" }),
    };
    u.phase.store(.idle, .release);
    u.checkNow();
    var waits: usize = 0;
    while (u.working.load(.acquire) and waits < 6000) : (waits += 1) nanoui.runFor(0.01);
    if (u.working.load(.acquire)) return error.UpdateTimedOut;
    const accept = std.mem.eql(u8, args[5], "accept");
    if (accept) {
        const ready = u.ready() orelse return error.ExpectedVerifiedUpdate;
        if (!std.mem.eql(u8, ready, args[4])) return error.WrongReadyVersion;
    } else if (u.ready() != null) {
        // Never install an unexpectedly accepted candidate, even in a fixture.
        u.phase.store(.idle, .release);
        u.deinit();
        return error.BadUpdateAccepted;
    }
    // Public deinit installs a verified ready copy on quit, without starting
    // another process. Its only destination is the fixture's bundle above.
    u.deinit();
    var buffer: [128]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try out.interface.print("update fixture: {s}\n", .{args[5]});
    try out.interface.flush();
}

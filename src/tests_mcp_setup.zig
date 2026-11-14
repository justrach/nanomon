//! All config tests use a private temporary home, never real agent state.
const std = @import("std");
const builtin = @import("builtin");
const clients = @import("mcp_clients.zig");
const reg = @import("mcp_register.zig");
const Store = @import("mcp_config_file.zig").Store;
const Setup = @import("agent_setup.zig").Setup;
const nanoui = @import("nanoui");
const tests = @import("tests.zig");
const App = @import("app.zig").App;
const ui = nanoui.ui;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const io = std.testing.io;
const exe = "/Applications/My Tools/nanomon.app/Contents/MacOS/nanomon";

const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: std.Io.Dir,
    arena: std.heap.ArenaAllocator = .init(std.testing.allocator),

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io, "home", if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700));
        return .{ .tmp = tmp, .home = try tmp.dir.openDir(io, "home", .{}) };
    }

    fn deinit(f: *Fixture) void {
        f.home.close(io);
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn ctx(f: *Fixture) !reg.Context {
        var buf: [4096]u8 = undefined;
        const n = try f.home.realPath(io, &buf);
        return .{ .home = f.home, .home_path = try f.arena.allocator().dupe(u8, buf[0..n]), .exe = exe, .io = io };
    }

    fn store(f: *Fixture) Store {
        return .{ .home = f.home, .io = io, .gpa = f.arena.allocator() };
    }

    fn seed(f: *Fixture, c: clients.Client, bytes: []const u8) !void {
        try f.store().prepareParent(clients.path(c));
        try f.home.writeFile(io, .{ .sub_path = clients.path(c), .data = bytes });
    }

    fn attach(f: *Fixture, s: *Setup) !void {
        var context = try f.ctx();
        context.home = try f.home.openDir(io, ".", .{});
        s.attach(std.testing.allocator, .{ .context = context });
    }
};

fn state(report: reg.Report, client: clients.Client) reg.Row {
    for (report) |r| if (r.client == client) return r;
    unreachable;
}

test "client setup is additive, idempotent, private, backed up and reversible" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const original = "{\"theme\":\"dark\",\"mcpServers\":{\"other\":{\"command\":\"keep\",\"env\":{\"SECRET\":\"unchanged\"}}}}\n";
    try f.seed(.cursor, original);
    const context = try f.ctx();
    const planned = state(try reg.run(a, context, .install, true, null), .cursor);
    try equal(reg.State.would_add, planned.state);
    try std.testing.expectEqualStrings(original, (try f.store().read(clients.path(.cursor))).?);
    const connected = state(try reg.run(a, context, .install, false, null), .cursor);
    try equal(reg.State.added, connected.state);
    try std.testing.expectEqualStrings(original, (try f.store().read(connected.backup.?)).?);
    const bytes = (try f.store().read(clients.path(.cursor))).?;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    const servers = parsed.object.get("mcpServers").?.object;
    try std.testing.expectEqualStrings("keep", servers.get("other").?.object.get("command").?.string);
    try std.testing.expectEqualStrings(exe, servers.get("nanomon").?.object.get("command").?.string);
    try std.testing.expectEqualStrings("mcp", servers.get("nanomon").?.object.get("args").?.array.items[0].string);
    if (builtin.os.tag != .windows) {
        try equal(0o600, (try f.home.statFile(io, clients.path(.cursor), .{})).permissions.toMode() & 0o777);
        try equal(0o600, (try f.home.statFile(io, connected.backup.?, .{})).permissions.toMode() & 0o777);
    }
    const again = state(try reg.run(a, context, .install, false, null), .cursor);
    try equal(reg.State.installed, again.state);
    try expect(again.backup == null);
    try std.testing.expectEqualStrings(bytes, (try f.store().read(clients.path(.cursor))).?);
    const remove_plan = state(try reg.run(a, context, .uninstall, true, null), .cursor);
    try equal(reg.State.would_remove, remove_plan.state);
    const removed = state(try reg.run(a, context, .uninstall, false, null), .cursor);
    try equal(reg.State.removed, removed.state);
    try std.testing.expectEqualStrings(bytes, (try f.store().read(removed.backup.?)).?);
    const after = try std.json.parseFromSliceLeaky(std.json.Value, a, (try f.store().read(clients.path(.cursor))).?, .{});
    try expect(!after.object.get("mcpServers").?.object.contains("nanomon"));
    try expect(after.object.get("mcpServers").?.object.contains("other"));
    try std.testing.expectEqualStrings("dark", after.object.get("theme").?.string);
}

test "setup leaves missing clients and malformed/custom/disabled configs alone" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const context = try f.ctx();
    const absent = try reg.run(a, context, .install, false, null);
    for (absent) |r| try equal(reg.State.absent, r.state);
    try expect((try f.store().read(".cursor/mcp.json")) == null);
    for ([_][]const u8{ "{bad", "[]", "\xff", "{\"mcpServers\":null}", "{\"mcpServers\":[]}", "{\"mcpServers\":{},\"mcpServers\":{}}" }) |text| {
        try f.seed(.cursor, text);
        try equal(reg.State.invalid_config, state(try reg.run(a, context, .install, false, null), .cursor).state);
        try std.testing.expectEqualStrings(text, (try f.store().read(clients.path(.cursor))).?);
    }
    for ([_][]const u8{
        "{\"mcpServers\":{\"nanomon\":{\"command\":\"custom\",\"args\":[\"mcp\"]}}}",
        "{\"mcpServers\":{\"nanomon\":{\"command\":\"/Applications/My Tools/nanomon.app/Contents/MacOS/nanomon\",\"args\":[\"mcp\"],\"disabled\":true}}}",
    }) |text| {
        try f.seed(.cursor, text);
        for ([_]reg.Action{ .install, .uninstall }) |action| {
            try equal(reg.State.conflict, state(try reg.run(a, context, action, false, null), .cursor).state);
            try std.testing.expectEqualStrings(text, (try f.store().read(clients.path(.cursor))).?);
        }
    }
    var custom = context;
    custom.custom_claude_home = true;
    try equal(reg.State.custom_profile, state(try reg.run(a, custom, .install, false, .claude_code), .claude_code).state);
    try expect((try f.store().read(".claude.json")) == null);
}

test "explicit targets may create a profile, and unsafe executable paths are rejected" {
    var f = try Fixture.init();
    defer f.deinit();
    var context = try f.ctx();
    const a = f.arena.allocator();
    try equal(reg.State.would_add, state(try reg.run(a, context, .install, true, .gemini), .gemini).state);
    try expect((try f.store().read(clients.path(.gemini))) == null);
    try equal(reg.State.added, state(try reg.run(a, context, .install, false, .gemini), .gemini).state);
    for ([_][]const u8{ "nanomon", "/Volumes/nanomon/nanomon.app/Contents/MacOS/nanomon", "/private/AppTranslocation/ABC/nanomon", "/tmp/bad\npath" }) |bad| {
        context.exe = bad;
        try std.testing.expectError(error.InstallApplicationFirst, reg.run(a, context, .install, false, null));
    }
}

test "setup preserves number precision and bounds config input/output" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const context = try f.ctx();
    const number = "1.230000000000000000000000123";
    try f.seed(.cursor, "{\"precision\":" ++ number ++ "}");
    try equal(reg.State.added, state(try reg.run(a, context, .install, false, null), .cursor).state);
    try expect(std.mem.indexOf(u8, (try f.store().read(clients.path(.cursor))).?, number) != null);
    const large = try a.alloc(u8, (1 << 20) + 1);
    @memset(large, ' ');
    try std.testing.expectError(error.ConfigTooLarge, f.store().replace("too-big.json", null, large));
    try expect((try f.store().read("too-big.json")) == null);
    try f.seed(.cursor, large);
    try equal(reg.State.failed, state(try reg.run(a, context, .install, false, null), .cursor).state);
    try equal(large.len, (try f.home.statFile(io, clients.path(.cursor), .{})).size);
}

test "setup refuses config symlinks and stale edits without touching targets" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.home.createDir(io, "outside", .default_dir);
    try f.home.writeFile(io, .{ .sub_path = "outside/mcp.json", .data = "{}" });
    try f.home.symLink(io, "outside", ".cursor", .{ .is_directory = true });
    const symlink = state(try reg.run(a, try f.ctx(), .install, false, null), .cursor);
    try equal(reg.State.failed, symlink.state);
    try std.testing.expectEqualStrings("{}", (try f.store().read("outside/mcp.json")).?);
    try f.home.deleteFile(io, ".cursor");
    try f.home.createDir(io, ".cursor", .default_dir);
    try f.home.symLink(io, "../outside/mcp.json", ".cursor/mcp.json", .{});
    try equal(reg.State.failed, state(try reg.run(a, try f.ctx(), .install, false, null), .cursor).state);
    try std.testing.expectEqualStrings("{}", (try f.store().read("outside/mcp.json")).?);
    try f.seed(.gemini, "{\"newer\":true}");
    try std.testing.expectError(error.ConcurrentModification, f.store().replace(clients.path(.gemini), "{}", "{\"lost\":true}"));
    try std.testing.expectEqualStrings("{\"newer\":true}", (try f.store().read(clients.path(.gemini))).?);
}

test "first-launch agent consent: showing/dismissing writes no client config, choice survives" {
    if (!@import("agent_setup.zig").supported) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.home.createDir(io, ".cursor", .default_dir);
    var a: App = .init(std.testing.allocator, io);
    defer a.deinit();
    try tests.fake(&a);
    try f.attach(&a.agents);
    try equal(Setup.State.offer, a.agents.state);
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1020, .height = 760 });
    defer t.deinit();
    t.settle(2);
    try expect(t.hasText("Connect agents to nanomon") and t.hasText("Cursor"));
    try expect((try f.store().read(clients.path(.cursor))) == null);
    try t.clickText("Not now");
    t.settle(1);
    try equal(Setup.State.closed, a.agents.state);
    try expect((try f.store().read(clients.path(.cursor))) == null);
    var reopened: Setup = .{};
    defer reopened.deinit();
    try f.attach(&reopened);
    try equal(Setup.State.closed, reopened.state);
    try t.clickText("Agent connections…");
    t.settle(1);
    try equal(Setup.State.offer, a.agents.state);
}

test "one explicit connect writes only temporary client configs and reports asynchronously" {
    if (!@import("agent_setup.zig").supported) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.home.createDir(io, ".cursor", .default_dir);
    var a: App = .init(std.testing.allocator, io);
    defer a.deinit();
    try tests.fake(&a);
    try f.attach(&a.agents);
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1020, .height = 760 });
    defer t.deinit();
    t.settle(2);
    try t.clickText("Connect detected clients");
    var waits: usize = 0;
    while (a.agents.state == .running and waits < 500) : (waits += 1) nanoui.runFor(0.01);
    try equal(Setup.State.done, a.agents.state);
    try expect(!a.agents.failed);
    try equal(reg.State.added, state(a.agents.report, .cursor).state);
    t.settle(1);
    try expect(t.hasText("Cursor: connected"));
    try expect((try f.store().read(clients.path(.cursor))) != null);
    try t.clickText("Done");
    t.settle(1);
    try equal(Setup.State.closed, a.agents.state);
    try f.home.deleteFile(io, clients.path(.cursor));
    var after_removal: Setup = .{};
    defer after_removal.deinit();
    try f.attach(&after_removal);
    try equal(Setup.State.closed, after_removal.state);
    try expect((try f.store().read(clients.path(.cursor))) == null);
}

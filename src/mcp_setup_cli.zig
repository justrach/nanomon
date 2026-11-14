//! Human-facing setup, separate from the protocol's stdout and tool list.
const std = @import("std");
const builtin = @import("builtin");
const clients = @import("mcp_clients.zig");
const reg = @import("mcp_register.zig");

const usage =
    \\nanomon mcp                         read-only MCP server (stdio)
    \\nanomon mcp install [--dry-run] [--client NAME]
    \\nanomon mcp uninstall [--dry-run] [--client NAME]
    \\nanomon mcp status [--client NAME]
    \\
    \\Auto-detects existing user profiles; never adds tools to project configs.
    \\Clients: claude-code, claude-desktop, cursor, gemini, windsurf, codex.
    \\--client explicitly targets one client, even if its profile is absent.
    \\Only nanomon's entry is changed; conflicts/invalid configs are skipped.
    \\Existing changed files get private backups beside them. Restart the client.
    \\Connecting shares local process/system metadata with that agent/model.
    \\
;

pub const Opened = struct {
    context: reg.Context,

    pub fn open(init: std.process.Init) !Opened {
        const a = init.arena.allocator();
        const home_path = init.environ_map.get("HOME") orelse return error.HomeNotSet;
        if (!std.fs.path.isAbsolute(home_path)) return error.HomeMustBeAbsolute;
        const home = try std.Io.Dir.cwd().openDir(init.io, home_path, .{});
        errdefer home.close(init.io);
        const path_env = init.environ_map.get("PATH") orelse "";
        const program = findProgram(a, init.io, path_env, "codex") orelse
            if (clients.present(.codex, home, init.io)) findCodexFallback(a, init.io, home_path) else null;
        return .{ .context = .{
            .home = home,
            .home_path = home_path,
            .exe = try std.process.executablePathAlloc(init.io, a),
            .path_env = path_env,
            .codex_program = program,
            .custom_codex_home = init.environ_map.get("CODEX_HOME") != null,
            .custom_claude_home = init.environ_map.get("CLAUDE_CONFIG_DIR") != null,
            .io = init.io,
        } };
    }

    pub fn close(o: Opened) void {
        o.context.home.close(o.context.io);
    }
};

fn findProgram(a: std.mem.Allocator, io: std.Io, path: []const u8, name: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    var dirs = std.mem.tokenizeScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        const p = std.fs.path.join(a, &.{ dir, name }) catch return null;
        if (executable(io, p)) return p;
    }
    return null;
}

fn executable(io: std.Io, path: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return false;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file and st.permissions.toMode() & 0o111 != 0;
}

fn findCodexFallback(a: std.mem.Allocator, io: std.Io, home: []const u8) ?[]const u8 {
    // Finder launches have a minimal PATH. No login shell or version probing:
    // only inspect familiar install locations when a Codex profile exists.
    for ([_][]const u8{ ".local/bin/codex", ".cargo/bin/codex", ".npm-global/bin/codex" }) |suffix| {
        const p = std.fs.path.join(a, &.{ home, suffix }) catch return null;
        if (executable(io, p)) return p;
    }
    for ([_][]const u8{ "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex" }) |p| {
        if (executable(io, p)) return p;
    }
    return null;
}

pub fn run(init: std.process.Init, args: []const [:0]const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) {
        try out.writeAll(usage);
        try out.flush();
        return;
    }
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SetupSupportedOnMacAndLinuxOnly;
    const action = std.meta.stringToEnum(reg.Action, args[0]) orelse return error.UnknownSetupCommand;
    var dry = false;
    var only: ?clients.Client = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dry-run")) {
            dry = true;
        } else if (std.mem.eql(u8, args[i], "--client")) {
            i += 1;
            if (i == args.len or only != null) return error.ExpectedOneClient;
            only = clients.parse(args[i]) orelse return error.UnknownClient;
        } else return error.UnexpectedSetupArgument;
    }
    const opened = try Opened.open(init);
    defer opened.close();
    const ctx = opened.context;
    if (action == .install) try out.writeAll("Connects local read-only system/process metadata to the detected agents and their model providers.\n");
    const report = try reg.run(init.arena.allocator(), ctx, action, dry, only);
    for (report) |row| {
        if (only) |one| if (row.client != one) continue;
        try out.print("{s}: {s}\n  {s}/{s}\n", .{ clients.name(row.client), reg.message(row.state), ctx.home_path, clients.path(row.client) });
        if (row.backup) |backup| try out.print("  backup: {s}/{s}\n", .{ ctx.home_path, backup });
        if (row.reason) |reason| try out.print("  reason: {s}\n", .{reason});
    }
    if (action != .status and !dry) {
        var connected = false;
        for (report) |r| if (r.state == .added or r.state == .installed) {
            connected = true;
        };
        if (action == .uninstall or connected) {
            @import("mcp_setup_choice.zig").save(init.arena.allocator(), ctx, if (action == .uninstall) .dismissed else .connected) catch |err|
                try out.print("Setup preference not saved: {s}\n", .{@errorName(err)});
        }
        try out.writeAll("Restart connected clients to refresh their MCP tools. Undo with: nanomon mcp uninstall\n");
    }
    try out.flush();
}

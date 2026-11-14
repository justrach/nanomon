//! Let Codex's own parser/editing code handle TOML; do not append guessed
//! tables or rewrite unrelated TOML. No shell, project CWD or server startup.
const std = @import("std");
const reg = @import("mcp_register.zig");
const Store = @import("mcp_config_file.zig").Store;
const json = std.json;
const path = ".codex/config.toml";

pub fn change(a: std.mem.Allocator, ctx: reg.Context, action: reg.Action, dry: bool) !reg.Row {
    const program = ctx.codex_program orelse return .{ .client = .codex, .state = .needs_codex_cli };
    const store: Store = .{ .home = ctx.home, .io = ctx.io, .gpa = a };
    const old = try store.read(path); // Reject symlinks/unsafe directories even in dry runs.
    if (dry) return .{ .client = .codex, .state = .would_check };
    if (action == .install) {
        // An explicit CODEX_HOME must already exist for Codex to resolve it.
        try store.prepareParent(path);
    } else {
        const profile = ctx.home.openDir(ctx.io, ".codex", .{ .follow_symlinks = false }) catch |err| {
            if (err == error.FileNotFound) return .{ .client = .codex, .state = .missing };
            return err;
        };
        profile.close(ctx.io);
    }
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("HOME", ctx.home_path);
    try env.put("CODEX_HOME", try std.fs.path.join(a, &.{ ctx.home_path, ".codex" }));
    try env.put("PATH", ctx.path_env);
    try env.put("LC_ALL", "C");
    const got = try invoke(a, ctx, &env, &.{ program, "mcp", "get", "nanomon", "--json" });
    const exists = exited(got);
    if (!exists and std.mem.indexOf(u8, got.stderr, "No MCP server named 'nanomon' found") == null)
        return .{ .client = .codex, .state = .failed, .reason = "Codex could not read its configuration" };
    if (exists) {
        const entry = json.parseFromSliceLeaky(json.Value, a, got.stdout, .{}) catch return .{ .client = .codex, .state = .invalid_config };
        if (!owned(entry, ctx.exe)) return .{ .client = .codex, .state = .conflict };
        if (action != .uninstall) return .{ .client = .codex, .state = .installed };
    } else if (action != .install) return .{ .client = .codex, .state = .missing };
    // Check again after asking Codex; never base an edit on stale bytes.
    if (!try store.matches(path, old)) return error.ConcurrentModification;
    const backup = try store.backup(path, old);
    try store.prepareParent(path);
    const args: []const []const u8 = if (action == .install)
        &.{ program, "mcp", "add", "nanomon", "--", ctx.exe, "mcp" }
    else
        &.{ program, "mcp", "remove", "nanomon" };
    const changed = try invoke(a, ctx, &env, args);
    if (!exited(changed)) return .{ .client = .codex, .state = .failed, .backup = backup, .reason = "Codex rejected the config change" };
    return .{ .client = .codex, .state = if (action == .install) .added else .removed, .backup = backup };
}

fn exited(r: std.process.RunResult) bool {
    return r.term == .exited and r.term.exited == 0;
}

fn invoke(a: std.mem.Allocator, ctx: reg.Context, env: *std.process.Environ.Map, args: []const []const u8) !std.process.RunResult {
    return std.process.run(a, ctx.io, .{
        .argv = args,
        .environ_map = env,
        .cwd = .{ .dir = ctx.home },
        .stdout_limit = .limited(128 << 10),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
    });
}

fn empty(v: ?json.Value) bool {
    const value = v orelse return true;
    return switch (value) {
        .null => true,
        .object => value.object.count() == 0,
        .array => value.array.items.len == 0,
        else => false,
    };
}

fn owned(v: json.Value, exe: []const u8) bool {
    if (v != .object) return false;
    if (v.object.get("enabled")) |on| if (on != .bool or !on.bool) return false;
    if (!empty(v.object.get("enabled_tools")) or !empty(v.object.get("disabled_tools"))) return false;
    const t = v.object.get("transport") orelse return false;
    if (t != .object) return false;
    const kind = t.object.get("type") orelse return false;
    const cmd = t.object.get("command") orelse return false;
    const args = t.object.get("args") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "stdio") or cmd != .string or !std.mem.eql(u8, cmd.string, exe)) return false;
    if (args != .array or args.array.items.len != 1 or args.array.items[0] != .string or !std.mem.eql(u8, args.array.items[0].string, "mcp")) return false;
    return empty(t.object.get("env")) and empty(t.object.get("env_vars")) and empty(t.object.get("cwd"));
}

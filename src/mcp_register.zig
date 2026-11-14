//! Add/remove only nanomon's user-scope entry. Existing custom entries,
//! invalid configs and clients' explicit disabled settings are not overwritten.
const std = @import("std");
const clients = @import("mcp_clients.zig");
const config = @import("mcp_config_file.zig");
const codex = @import("mcp_register_codex.zig");
const json = std.json;

pub const Action = enum { install, uninstall, status };
pub const State = enum { absent, missing, installed, added, removed, would_add, would_remove, would_check, conflict, invalid_config, failed, needs_codex_cli, custom_profile };
pub const Row = struct { client: clients.Client, state: State, backup: ?[]const u8 = null, reason: ?[]const u8 = null };
pub const Report = [clients.all.len]Row;
pub const Context = struct {
    home: std.Io.Dir,
    home_path: []const u8,
    exe: []const u8,
    path_env: []const u8 = "",
    codex_program: ?[]const u8 = null,
    custom_codex_home: bool = false,
    custom_claude_home: bool = false,
    io: std.Io,
};

pub fn run(arena: std.mem.Allocator, ctx: Context, action: Action, dry_run: bool, only: ?clients.Client) !Report {
    if (!clients.validExecutable(ctx.exe)) return error.InstallApplicationFirst;
    var report: Report = undefined;
    for (clients.all, &report) |client, *row| {
        row.* = .{ .client = client, .state = .absent };
        if (only) |selected| if (selected != client) continue;
        const detected = clients.present(client, ctx.home, ctx.io) or (client == .codex and ctx.codex_program != null);
        if (!detected and only == null) continue;
        if ((client == .codex and ctx.custom_codex_home) or (client == .claude_code and ctx.custom_claude_home)) {
            row.state = .custom_profile;
            continue;
        }
        row.* = (if (client == .codex)
            codex.change(arena, ctx, action, dry_run)
        else
            changeJson(arena, ctx, client, action, dry_run)) catch |err| .{
            .client = client,
            .state = .failed,
            .reason = @errorName(err),
        };
    }
    return report;
}

fn changeJson(arena: std.mem.Allocator, ctx: Context, client: clients.Client, action: Action, dry: bool) !Row {
    const store: config.Store = .{ .home = ctx.home, .io = ctx.io, .gpa = arena };
    const path = clients.path(client);
    const old = try store.read(path);
    if (old) |bytes| if (!std.unicode.utf8ValidateSlice(bytes)) return .{ .client = client, .state = .invalid_config };
    const root = if (old) |text|
        json.parseFromSliceLeaky(json.Value, arena, text, .{ .allocate = .alloc_always, .parse_numbers = false }) catch return .{ .client = client, .state = .invalid_config }
    else
        json.Value{ .object = .empty };
    if (root != .object) return .{ .client = client, .state = .invalid_config };
    var data = root;
    var servers = data.object.get("mcpServers") orelse json.Value{ .object = .empty };
    if (servers != .object) return .{ .client = client, .state = .invalid_config };
    const entry = servers.object.get("nanomon");
    if (entry) |v| {
        if (!owned(v, ctx.exe)) return .{ .client = client, .state = .conflict };
        if (action != .uninstall) return .{ .client = client, .state = .installed };
    } else if (action != .install) return .{ .client = client, .state = .missing };
    if (dry) return .{ .client = client, .state = if (action == .install) .would_add else .would_remove };
    if (action == .install) {
        const encoded = try json.Stringify.valueAlloc(arena, .{ .command = ctx.exe, .args = .{"mcp"} }, .{});
        const value = try json.parseFromSliceLeaky(json.Value, arena, encoded, .{});
        try servers.object.put(arena, "nanomon", value);
    } else _ = servers.object.orderedRemove("nanomon");
    try data.object.put(arena, "mcpServers", servers);
    const text = try json.Stringify.valueAlloc(arena, data, .{ .whitespace = .indent_2 });
    const bytes = try std.fmt.allocPrint(arena, "{s}\n", .{text});
    return .{ .client = client, .state = if (action == .install) .added else .removed, .backup = try store.replace(path, old, bytes) };
}

fn owned(value: json.Value, exe: []const u8) bool {
    if (value != .object or value.object.count() != 2) return false;
    const cmd = value.object.get("command") orelse return false;
    const args = value.object.get("args") orelse return false;
    if (cmd != .string or !std.mem.eql(u8, cmd.string, exe) or args != .array or args.array.items.len != 1) return false;
    return args.array.items[0] == .string and std.mem.eql(u8, args.array.items[0].string, "mcp");
}

pub fn message(state: State) []const u8 {
    return switch (state) {
        .absent => "not detected; untouched",
        .missing => "not connected",
        .installed => "already connected; unchanged",
        .added => "connected",
        .removed => "disconnected",
        .would_add => "would connect (dry run)",
        .would_remove => "would disconnect (dry run)",
        .would_check => "would check/update through Codex CLI (dry run; no command executed)",
        .conflict => "custom/disabled nanomon entry; untouched",
        .invalid_config => "invalid config; untouched",
        .failed => "setup failed; inspect config/permissions",
        .needs_codex_cli => "Codex CLI not found; untouched",
        .custom_profile => "custom client config directory; untouched (configure manually)",
    };
}

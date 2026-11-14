//! Known user-scope MCP config locations. Detection never launches apps,
//! scans project trees, or creates profiles for clients that are absent.
const std = @import("std");
const builtin = @import("builtin");

pub const Client = enum { claude_code, claude_desktop, cursor, gemini, windsurf, codex };
pub const all = std.enums.values(Client);

pub fn name(c: Client) []const u8 {
    return switch (c) {
        .claude_code => "Claude Code",
        .claude_desktop => "Claude Desktop",
        .cursor => "Cursor",
        .gemini => "Gemini CLI",
        .windsurf => "Windsurf",
        .codex => "Codex",
    };
}

pub fn key(c: Client) []const u8 {
    return switch (c) {
        .claude_code => "claude-code",
        .claude_desktop => "claude-desktop",
        else => @tagName(c),
    };
}

pub fn parse(text: []const u8) ?Client {
    for (all) |c| if (std.mem.eql(u8, key(c), text)) return c;
    return null;
}

pub fn path(c: Client) []const u8 {
    return switch (c) {
        .claude_code => ".claude.json",
        .claude_desktop => if (builtin.os.tag == .macos) "Library/Application Support/Claude/claude_desktop_config.json" else ".config/Claude/claude_desktop_config.json",
        .cursor => ".cursor/mcp.json",
        .gemini => ".gemini/settings.json",
        .windsurf => ".codeium/windsurf/mcp_config.json",
        .codex => ".codex/config.toml",
    };
}

pub fn marker(c: Client) []const u8 {
    return switch (c) {
        .claude_code => ".claude",
        else => std.fs.path.dirname(path(c)).?,
    };
}

pub fn present(c: Client, home: std.Io.Dir, io: std.Io) bool {
    _ = home.statFile(io, path(c), .{ .follow_symlinks = false }) catch {
        var dir = home.openDir(io, marker(c), .{ .follow_symlinks = false }) catch return false;
        dir.close(io);
        return true;
    };
    return true;
}

pub fn validExecutable(exe: []const u8) bool {
    if (!std.fs.path.isAbsolute(exe) or !std.unicode.utf8ValidateSlice(exe)) return false;
    if (std.mem.startsWith(u8, exe, "/Volumes/") or std.mem.indexOf(u8, exe, "/AppTranslocation/") != null or
        std.mem.indexOf(u8, exe, "/.zig-cache/") != null) return false;
    for (exe) |ch| if (ch < 32 or ch == 127) return false;
    return true;
}

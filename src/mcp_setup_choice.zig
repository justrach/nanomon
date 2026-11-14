//! Remember explicit consent or dismissal, including CLI uninstall, so an
//! update or normal MCP startup never re-adds a server the user removed.
const std = @import("std");
const reg = @import("mcp_register.zig");
const Store = @import("mcp_config_file.zig").Store;
const path = ".nanomon/mcp-setup.json";

pub fn decided(a: std.mem.Allocator, ctx: reg.Context) bool {
    const store: Store = .{ .home = ctx.home, .io = ctx.io, .gpa = a };
    // Treat an unreadable/invalid preference as a decision, not permission
    // to repeatedly offer connections or repair anything automatically.
    return (store.read(path) catch return true) != null;
}

pub fn save(a: std.mem.Allocator, ctx: reg.Context, decision: enum { connected, dismissed }) !void {
    const store: Store = .{ .home = ctx.home, .io = ctx.io, .gpa = a };
    const old = try store.read(path);
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .decision = decision }, .{});
    if (old) |text| if (std.mem.eql(u8, text, bytes)) return;
    _ = try store.replace(path, old, bytes);
}

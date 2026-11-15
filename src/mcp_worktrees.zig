//! Read-only, paginated view of a demand-only metadata scan. No paths in the
//! query, no Git subprocesses, sizing, mutation or pruning tool.
const std = @import("std");
const tools = @import("mcp_tools.zig");
const wt = @import("worktrees.zig");
pub const Options = struct { stale_only: bool = true, stale_after_days: usize = 14, limit: usize = 50, offset: usize = 0 };

pub fn execute(a: std.mem.Allocator, d: tools.Data, opts: Options) ![]u8 {
    const Wire = struct {
        path: []const u8,
        git_dir: []const u8,
        repo: []const u8,
        branch: []const u8,
        is_primary: bool,
        locked: bool,
        missing: ?bool,
        dirty: ?bool,
        last_modified_unix_ms: ?i64,
        size_bytes: ?u64,
        reasons: []const []const u8,
        prunable: bool,
        status_checked: bool,
    };
    var rows: std.ArrayList(Wire) = .empty;
    defer rows.deinit(a);
    var total: usize = 0;
    var stale: usize = 0;
    var bytes: u64 = 0;
    var unknown_size = false;
    for (d.worktrees.entries) |e| {
        if (e.stale() and !e.is_primary) {
            stale += 1;
            if (e.size_bytes) |n| {
                bytes +|= n;
            } else unknown_size = true;
        }
        if (opts.stale_only and !e.stale()) continue;
        const at = total;
        total += 1;
        if (at < opts.offset or rows.items.len >= opts.limit) continue;
        var reasons: std.ArrayList([]const u8) = .empty;
        inline for (@typeInfo(wt.Reasons).@"struct".field_names) |name| {
            if (@field(e.reasons, name)) try reasons.append(a, name);
        }
        try rows.append(a, .{ .path = e.path, .git_dir = e.git_dir, .repo = e.repo, .branch = e.branch, .is_primary = e.is_primary, .locked = e.locked, .missing = e.missing, .dirty = e.dirty, .last_modified_unix_ms = e.last_modified_unix_ms, .size_bytes = e.size_bytes, .reasons = reasons.items, .prunable = false, .status_checked = false });
    }
    return std.json.Stringify.valueAlloc(a, .{
        .meta = tools.metadata(d),
        .inspected_at_unix_ms = d.worktrees.inspected_at_unix_ms,
        .truncated = d.worktrees.truncated,
        .metadata_errors = d.worktrees.errors,
        .scope = "Repositories found from sampled own-user working/executable directories and MCP cwd; no disk crawl",
        .safety = "Metadata only: dirty/merged/size are unknown. Age is not proof of inactivity. GUI review is required; no MCP cleanup tool.",
        .total_matches = total,
        .offset = opts.offset,
        .next_offset = if (opts.offset < total and total - opts.offset > rows.items.len) @as(?usize, opts.offset + rows.items.len) else null,
        .stale_count = stale,
        .stale_bytes = if (unknown_size) @as(?u64, null) else bytes,
        .worktrees = rows.items,
    }, .{});
}

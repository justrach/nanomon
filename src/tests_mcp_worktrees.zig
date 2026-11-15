//! Synthetic MCP capacity/worktree fixtures: no filesystem or processes.
const std = @import("std");
const tools = @import("mcp_tools.zig");
const mcp = @import("mcp.zig");
const wt = @import("worktrees.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const J = std.json.Value;
fn field(v: J, key: []const u8) J {
    return v.object.get(key).?;
}
const Fixture = struct {
    sampler: @import("sample.zig").Sampler = .{ .gpa = std.testing.allocator, .io = std.testing.io },
    samples: usize = 0,
    inspections: usize = 0,
    rows: [3]wt.Entry = .{
        .{ .path = "/demo/main", .repo = "/demo/main", .git_dir = "/demo/main/.git", .is_primary = true },
        .{ .path = "/demo/old", .repo = "/demo/main", .git_dir = "/demo/main/.git/worktrees/old", .reasons = .{ .untouched = true } },
        .{ .path = "/demo/gone", .repo = "/demo/main", .git_dir = "/demo/main/.git/worktrees/gone", .missing = true, .reasons = .{ .missing = true } },
    },
    fn data(f: *Fixture) tools.Data {
        return .{ .sampler = &f.sampler, .sampled_at_ms = 123, .interval_seconds = null, .stamps = &.{}, .worktrees = .{ .entries = &f.rows, .inspected_at_unix_ms = 456 } };
    }
    fn sample(ctx: *anyopaque) !tools.Data {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        f.samples += 1;
        return f.data();
    }
    fn inspect(ctx: *anyopaque, _: std.mem.Allocator, _: usize) !wt.Snapshot {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        f.inspections += 1;
        return f.data().worktrees;
    }
};
fn parse(a: std.mem.Allocator, text: []const u8) !J {
    return std.json.parseFromSliceLeaky(J, a, text, .{});
}

test "get_system storage is nullable and preserves free versus available bytes" {
    var f: Fixture = .{};
    defer f.sampler.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var result = try parse(a, try tools.execute(a, .system, f.data()));
    try expect(field(result, "storage") == .null);
    f.sampler.system.storage = .{ .total_bytes = 1000, .used_bytes = 700, .free_bytes = 300, .available_bytes = 200 };
    result = try parse(a, try tools.execute(a, .system, f.data()));
    const s = field(result, "storage");
    try equal(1000, field(s, "total_bytes").integer);
    try equal(300, field(s, "free_bytes").integer);
    try equal(200, field(s, "available_bytes").integer);
    try expect(field(result, "disk") == .null); // Capacity does not pretend I/O was measured.
}

test "worktrees filter page and retain unknowns without exposing cleanup" {
    var f: Fixture = .{};
    defer f.sampler.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const q = try tools.Query.parse("list_worktrees", try parse(a, "{\"limit\":1}"));
    try equal(14, q.worktrees.stale_after_days);
    const result = try parse(a, try tools.execute(a, q, f.data()));
    try equal(2, field(result, "total_matches").integer);
    try equal(2, field(result, "stale_count").integer);
    try equal(1, field(result, "next_offset").integer);
    try expect(field(result, "stale_bytes") == .null);
    const row = field(result, "worktrees").array.items[0];
    try expect(field(row, "dirty") == .null and field(row, "size_bytes") == .null);
    try expect(!field(row, "prunable").bool and !field(row, "status_checked").bool);
    const page = try parse(a, try tools.execute(a, .{ .worktrees = .{ .stale_only = false, .offset = 3 } }, f.data()));
    try equal(3, field(page, "total_matches").integer);
    try equal(0, field(page, "worktrees").array.items.len);
    try expect(field(page, "next_offset") == .null);
    try std.testing.expectError(error.UnknownTool, tools.Query.parse("prune_worktrees", try parse(a, "{}")));
}

test "worktree schema bounds reject arbitrary paths and every invalid scalar before discovery" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{\"path\":\"/etc\"}", "{\"dry_run\":false}", "{\"stale_only\":1}", "{\"limit\":0}", "{\"limit\":201}", "{\"offset\":100001}", "{\"offset\":-1}", "{\"stale_after_days\":0}", "{\"stale_after_days\":366}", "{\"limit\":1.5}" }) |text| {
        try std.testing.expectError(error.InvalidArguments, tools.Query.parse("list_worktrees", try parse(a, text)));
    }
}

test "MCP notifications discovery and other tools never trigger repository inspection" {
    var f: Fixture = .{};
    defer f.sampler.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: mcp.Session = .{ .source = .{ .ptr = &f, .sample = Fixture.sample, .worktrees = Fixture.inspect } };
    _ = try s.handle(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\"}}");
    _ = try s.handle(a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    try expect(try s.handle(a, "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"list_worktrees\"}}") == null);
    try equal(0, f.samples);
    try equal(0, f.inspections);
    _ = try s.handle(a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"get_system\"}}");
    try equal(1, f.samples);
    try equal(0, f.inspections);
    _ = try s.handle(a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"list_worktrees\",\"arguments\":{\"path\":\"/tmp\"}}}");
    try equal(1, f.samples);
    try equal(0, f.inspections);
    const response = try parse(a, (try s.handle(a, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"list_worktrees\"}}")).?);
    try equal(2, f.samples);
    try equal(1, f.inspections);
    const result = field(response, "result");
    const serialized = try std.json.Stringify.valueAlloc(a, field(result, "structuredContent"), .{});
    try std.testing.expectEqualStrings(serialized, field(field(result, "content").array.items[0], "text").string);
}

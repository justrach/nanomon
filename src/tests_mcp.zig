//! MCP tested without a window, a network, an agent or a real process
//! signal. The source is injected, so protocol errors must not sample.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const mcp = @import("mcp.zig");
const tools = @import("mcp_tools.zig");
const sample = @import("sample.zig");
const Provider = @import("mcp_stdio.zig").Provider;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

const Fixture = struct {
    sampler: sample.Sampler = .{ .gpa = std.testing.allocator, .io = std.testing.io, .async_ps = false },
    calls: usize = 0,
    fail: bool = false,
    stamps: [3]tools.Stamp = .{
        .{ .at_ms = 1000, .available = .{ .cpu = true, .memory = true, .disk = true }, .rates = .{} },
        .{ .at_ms = 1500, .available = .{ .cpu = true, .memory = true, .disk = true }, .rates = .{ .cpu = true, .disk = true } },
        .{ .at_ms = 10000, .available = .{ .cpu = true, .memory = true }, .rates = .{ .cpu = true } },
    },

    fn init(f: *Fixture) !void {
        const s = &f.sampler;
        s.samples = 3;
        s.system = .{
            .available = .{ .cpu = true, .memory = true, .disk = true, .network = true },
            .rate_available = .{ .cpu = true, .disk = true, .network = true },
            .cores = 4,
            .cpu_user = 20,
            .cpu_system = 5,
            .mem_total = 8 << 30,
            .mem_app = 2 << 30,
            .read_sec = 1234,
        };
        s.info.chip = "test CPU";
        s.cores = 4;
        s.core_load[0..4].* = .{ 100, 0, 0, 0 };
        s.user_history.push(0);
        s.user_history.push(20);
        s.user_history.push(30);
        s.read_history.push(0);
        s.read_history.push(1234);
        s.read_history.push(0);
        try s.procs.appendSlice(s.gpa, &.{
            .{ .pid = 990001, .ppid = 1, .uid = 0, .name = "restricted", .user = "root" },
            .{ .pid = 990002, .ppid = 1, .uid = 501, .name = "Browser \"quoted\"\nline", .user = "ada", .known = true, .cpu_known = true, .cpu = 125, .memory = 1000, .threads = 4, .disk_known = true },
            .{ .pid = 990003, .ppid = 1, .uid = 501, .name = "browser helper", .user = "ada", .known = true, .cpu_known = true, .cpu = 25, .memory = 2000, .disk_known = false },
            .{ .pid = 990004, .ppid = 1, .uid = 501, .name = "just started", .user = "ada", .known = true, .cpu_known = false },
        });
    }

    fn source(f: *Fixture) mcp.Source {
        return .{ .ptr = f, .sample = get };
    }

    fn get(ctx: *anyopaque) !tools.Data {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        f.calls += 1;
        if (f.fail) return error.SamplingUnavailable;
        return .{ .sampler = &f.sampler, .sampled_at_ms = 10000, .interval_seconds = 8.5, .stamps = &f.stamps };
    }
};

fn request(s: *mcp.Session, a: std.mem.Allocator, line: []const u8) !json.Value {
    const response = (try s.handle(a, line)) orelse return error.MissingResponse;
    try expect(std.mem.indexOfScalar(u8, response, '\n') == null);
    return json.parseFromSliceLeaky(json.Value, a, response, .{});
}

fn field(v: json.Value, key: []const u8) json.Value {
    return v.object.get(key).?;
}

fn payload(response: json.Value) !json.Value {
    const result = field(response, "result");
    try equal(false, field(result, "isError").bool);
    const structured = field(result, "structuredContent");
    const text = field(field(result, "content").array.items[0], "text").string;
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const serialized = try json.Stringify.valueAlloc(a.allocator(), structured, .{});
    try std.testing.expectEqualStrings(serialized, text);
    return structured;
}

fn initialize(s: *mcp.Session, a: std.mem.Allocator) !void {
    _ = try request(s, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\"}}");
    try equal(null, try s.handle(a, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"));
}

fn call(s: *mcp.Session, a: std.mem.Allocator, name: []const u8, args: []const u8) !json.Value {
    const line = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ name, args });
    return request(s, a, line);
}

test "MCP initialization, negotiation, catalog and ping need no samples" {
    var f: Fixture = .{};
    defer f.sampler.deinit();
    var s: mcp.Session = .{ .source = f.source() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try call(&s, a, "get_system", "{}");
    try equal(-32600, field(field(before, "error"), "code").integer);
    try initialize(&s, a);
    const response = try request(&s, a, "{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2099-01-01\"}}");
    try std.testing.expectEqualStrings("a\"b", field(response, "id").string);
    try std.testing.expectEqualStrings("2025-11-25", field(field(response, "result"), "protocolVersion").string);
    for ([_][]const u8{ "2025-03-26", "2025-06-18" }) |version| {
        const line = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"{s}\"}}}}", .{version});
        const negotiated = try request(&s, a, line);
        try std.testing.expectEqualStrings(version, field(field(negotiated, "result"), "protocolVersion").string);
    }
    const list = try request(&s, a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    const catalog = field(field(list, "result"), "tools").array.items;
    try equal(4, catalog.len);
    for (catalog) |t| {
        try expect(field(field(t, "annotations"), "readOnlyHint").bool);
        try expect(!field(field(t, "inputSchema"), "additionalProperties").bool);
    }
    const ping = try request(&s, a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}");
    try expect(field(ping, "result") == .object);
    try equal(0, field(ping, "result").object.count());
    try equal(0, f.calls);
}

test "MCP validates malformed requests and arguments before touching the sampler" {
    var f: Fixture = .{};
    defer f.sampler.deinit();
    var s: mcp.Session = .{ .source = f.source() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try initialize(&s, a);
    for ([_][]const u8{ "{", "[]", "null", "{\"method\":3}", "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}" }) |line| {
        const result = try request(&s, a, line);
        try expect(field(result, "error") == .object);
    }
    const bad_utf8 = try request(&s, a, "{\"jsonrpc\":\"2.0\",\"id\":\"bad\xff\",\"method\":\"ping\"}");
    try equal(-32700, field(field(bad_utf8, "error"), "code").integer);
    const long_name: [257]u8 = @splat('x');
    const long_query = try json.Stringify.valueAlloc(a, .{ .query = long_name[0..] }, .{});
    const too_long = try call(&s, a, "list_processes", long_query);
    try equal(-32602, field(field(too_long, "error"), "code").integer);
    const unknown = try call(&s, a, "kill_process", "{\"pid\":1}");
    try equal(-32602, field(field(unknown, "error"), "code").integer);
    for ([_][]const u8{
        "{\"limit\":0}",              "{\"limit\":201}",     "{\"limit\":1.5}",   "{\"limit\":\"5\"}",
        "{\"offset\":-1}",            "{\"offset\":100001}", "{\"query\":false}", "{\"sort_by\":\"read\"}",
        "{\"command\":\"anything\"}", "[]",                  "null",
    }) |args| {
        const result = try call(&s, a, "list_processes", args);
        try equal(-32602, field(field(result, "error"), "code").integer);
    }
    for ([_][]const u8{ "{}", "{\"pid\":0}", "{\"pid\":-1}", "{\"pid\":2147483648}", "{\"pid\":1,\"signal\":9}" }) |args| {
        const result = try call(&s, a, "get_process", args);
        try equal(-32602, field(field(result, "error"), "code").integer);
    }
    for ([_][]const u8{ "{}", "{\"metric\":\"unknown\"}", "{\"metric\":\"cpu_user_percent\",\"max_points\":301}" }) |args| {
        const result = try call(&s, a, "get_history", args);
        try equal(-32602, field(field(result, "error"), "code").integer);
    }
    try equal(null, try s.handle(a, "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"get_system\"}}"));
    try equal(null, try s.handle(a, "{\"jsonrpc\":\"2.0\",\"method\":\"unknown/notification\"}"));
    const unknown_method = try request(&s, a, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"run_command\"}");
    try equal(-32601, field(field(unknown_method, "error"), "code").integer);
    try equal(0, f.calls);
}

test "MCP process pagination/filtering, units, null counters and JSON escaping" {
    var f: Fixture = .{};
    defer f.sampler.deinit();
    try f.init();
    var s: mcp.Session = .{ .source = f.source() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try initialize(&s, a);
    const filtered = try payload(try call(&s, a, "list_processes", "{\"query\":\"BROWSER\",\"sort_by\":\"memory\",\"limit\":1}"));
    try equal(2, field(filtered, "total_matching").integer);
    try equal(1, field(filtered, "next_offset").integer);
    const first = field(filtered, "processes").array.items[0];
    try equal(990003, field(first, "pid").integer);
    try expect(field(first, "disk_read_bytes") == .null);
    const next = try payload(try call(&s, a, "list_processes", "{\"query\":\"browser\",\"sort_by\":\"memory\",\"limit\":1,\"offset\":1}"));
    try expect(field(next, "next_offset") == .null);
    const second = field(next, "processes").array.items[0];
    try std.testing.expectEqualStrings("Browser \"quoted\"\nline", field(second, "name").string);
    try equal(125, field(second, "cpu_percent").integer);
    try equal(0, field(second, "disk_read_bytes").integer);
    const restricted = field(try payload(try call(&s, a, "get_process", "{\"pid\":990001}")), "process");
    try expect(field(restricted, "memory_bytes") == .null);
    try expect(field(restricted, "cpu_percent") == .null);
    const started = field(try payload(try call(&s, a, "get_process", "{\"pid\":990004}")), "process");
    try expect(field(started, "cpu_percent") == .null);
    const past = try payload(try call(&s, a, "list_processes", "{\"offset\":100000}"));
    try equal(0, field(past, "processes").array.items.len);
    const missing = field(try call(&s, a, "get_process", "{\"pid\":123456}"), "result");
    try expect(field(missing, "isError").bool);
    // Querying/sorting never changes the GUI/sampler's process order.
    try equal(990001, f.sampler.procs.items[0].pid);
    f.sampler.procs.items[0].name = "bad\xff";
    const bad_name = field(try payload(try call(&s, a, "get_process", "{\"pid\":990001}")), "process");
    try std.testing.expectEqualStrings("[non-UTF-8 metadata]", field(bad_name, "name").string);
}

test "MCP system/history keeps real timestamps, null baselines and unavailable sources" {
    var f: Fixture = .{};
    defer f.sampler.deinit();
    try f.init();
    var s: mcp.Session = .{ .source = f.source() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try initialize(&s, a);
    const sys = try payload(try call(&s, a, "get_system", "{}"));
    try equal(25, field(field(sys, "cpu"), "busy_percent").integer);
    try equal(8 << 30, field(field(sys, "memory"), "total_bytes").integer);
    try expect(field(sys, "gpu") == .null);
    const hist = try payload(try call(&s, a, "get_history", "{\"metric\":\"cpu_user_percent\"}"));
    const points = field(hist, "points").array.items;
    try equal(3, points.len);
    try expect(field(points[0], "value") == .null);
    try equal(1500, field(points[1], "sampled_at_unix_ms").integer);
    try equal(10000, field(points[2], "sampled_at_unix_ms").integer);
    try equal(30, field(points[2], "value").integer);
    const disk = try payload(try call(&s, a, "get_history", "{\"metric\":\"disk_read_bytes_per_second\",\"max_points\":2}"));
    const disk_points = field(disk, "points").array.items;
    try equal(2, disk_points.len);
    try equal(1234, field(disk_points[0], "value").integer);
    try expect(field(disk_points[1], "value") == .null);
    const gpu = field(try call(&s, a, "get_history", "{\"metric\":\"gpu_percent\"}"), "result");
    try expect(field(gpu, "isError").bool);
    f.sampler.system.available = .{};
    f.sampler.system.rate_available = .{};
    const unavailable = try payload(try call(&s, a, "get_system", "{}"));
    try expect(field(unavailable, "disk") == .null);
    try expect(field(unavailable, "memory") == .null);
    try expect(field(field(unavailable, "cpu"), "busy_percent") == .null);
    f.fail = true;
    const failed = field(try call(&s, a, "get_system", "{}"), "result");
    try expect(field(failed, "isError").bool);
}

test "MCP live provider primes CPU rates without an app or background workers" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var p: Provider = .init(std.testing.allocator, std.testing.io);
    defer p.deinit();
    const source = p.source();
    const first = try source.sample(source.ptr);
    try equal(2, p.sampler.samples);
    try equal(2, first.stamps.len);
    try expect(first.interval_seconds.? >= 0.25);
    try expect(p.sampler.procs.items.len > 0);
    try expect(p.sampler.system.available.memory);
    try expect(p.sampler.system.rate_available.cpu);
    try expect(!p.sampler.async_ps);
    if (builtin.os.tag == .macos) {
        try equal(-1, p.sampler.state.ps.fd);
        try expect(p.sampler.state.ps.watch == null);
        try expect(p.sampler.state.ps.known.count() > 0);
    }
    // Throttling is measured from collection's end, even if collecting
    // took longer than the minimum interval; no real-time race in this test.
    try expect(!p.due(p.last_finished_seconds));
    try expect(!p.due(p.last_finished_seconds + 0.1));
    try expect(p.due(p.last_finished_seconds + 0.3));
}

//! Validated queries and JSON views of the sampler. All counters have
//! units, unknown readings are null, and the sampler is never mutated.
const std = @import("std");
const builtin = @import("builtin");
const sample = @import("sample.zig");
const model = @import("model.zig");
const json = std.json;

pub const Data = struct {
    sampler: *const sample.Sampler,
    sampled_at_ms: i64,
    age_ms: i64 = 0,
    interval_seconds: ?f64,
    stamps: []const Stamp,
};

pub const Stamp = struct { at_ms: i64, available: model.Availability, rates: model.Availability };

pub const Metric = enum {
    cpu_user_percent,
    cpu_system_percent,
    memory_pressure_percent,
    memory_app_percent,
    gpu_percent,
    disk_read_bytes_per_second,
    disk_written_bytes_per_second,
    network_in_bytes_per_second,
    network_out_bytes_per_second,
};

pub const Query = union(enum) {
    system,
    processes: struct { query: []const u8 = "", sort_by: model.Sort = .cpu, limit: usize = 20, offset: usize = 0 },
    process: i32,
    history: struct { metric: Metric, max_points: usize = 60 },

    pub fn parse(name: []const u8, args: json.Value) !Query {
        if (args != .object) return error.InvalidArguments;
        if (std.mem.eql(u8, name, "get_system")) {
            try keys(args, &.{});
            return .system;
        }
        if (std.mem.eql(u8, name, "list_processes")) {
            try keys(args, &.{ "query", "sort_by", "limit", "offset" });
            var q: Query = .{ .processes = .{} };
            if (args.object.get("query")) |v| {
                if (v != .string or v.string.len > 256) return error.InvalidArguments;
                q.processes.query = v.string;
            }
            if (args.object.get("sort_by")) |v| {
                if (v != .string) return error.InvalidArguments;
                q.processes.sort_by = std.meta.stringToEnum(model.Sort, v.string) orelse return error.InvalidArguments;
                switch (q.processes.sort_by) {
                    .cpu, .memory, .pid, .name => {},
                    else => return error.InvalidArguments,
                }
            }
            q.processes.limit = try integer(args, "limit", 20, 1, 200);
            q.processes.offset = try integer(args, "offset", 0, 0, 100000);
            return q;
        }
        if (std.mem.eql(u8, name, "get_process")) {
            try keys(args, &.{"pid"});
            return .{ .process = @intCast(try integer(args, "pid", null, 1, std.math.maxInt(i32))) };
        }
        if (std.mem.eql(u8, name, "get_history")) {
            try keys(args, &.{ "metric", "max_points" });
            const m = args.object.get("metric") orelse return error.InvalidArguments;
            if (m != .string) return error.InvalidArguments;
            return .{ .history = .{
                .metric = std.meta.stringToEnum(Metric, m.string) orelse return error.InvalidArguments,
                .max_points = try integer(args, "max_points", 60, 1, 300),
            } };
        }
        return error.UnknownTool;
    }
};

fn keys(args: json.Value, allowed: []const []const u8) !void {
    for (args.object.keys()) |key| {
        for (allowed) |one| {
            if (std.mem.eql(u8, key, one)) break;
        } else return error.InvalidArguments;
    }
}

fn integer(args: json.Value, name: []const u8, default: ?usize, min: usize, max: usize) !usize {
    const v = args.object.get(name) orelse return default orelse error.InvalidArguments;
    if (v != .integer or v.integer < min or v.integer > max) return error.InvalidArguments;
    return @intCast(v.integer);
}

fn safe(text: []const u8) []const u8 {
    return if (std.unicode.utf8ValidateSlice(text)) text else "[non-UTF-8 metadata]";
}

fn metadata(d: Data) Meta {
    return .{
        .sample_count = d.sampler.samples,
        .sampled_at_unix_ms = d.sampled_at_ms,
        .sample_age_ms = d.age_ms,
        .interval_seconds = d.interval_seconds,
        .available = d.sampler.system.available,
        .rate_available = d.sampler.system.rate_available,
    };
}

const Meta = struct {
    schema_version: u32 = 1,
    source: []const u8 = "nanomon MCP session (independent of GUI)",
    platform: []const u8 = @tagName(builtin.os.tag),
    sample_count: usize,
    sampled_at_unix_ms: i64,
    sample_age_ms: i64,
    interval_seconds: ?f64,
    available: model.Availability,
    rate_available: model.Availability,
    process_cpu_scale: []const u8 = "percent of one logical CPU; can exceed 100",
    system_cpu_scale: []const u8 = "percent of all logical CPUs; 0 to 100",
    history_collection: []const u8 = "on demand, not periodic; no GUI history",
};

pub const Process = struct {
    pid: i32,
    parent_pid: i32,
    uid: u32,
    name: []const u8,
    user: []const u8,
    bundle: []const u8,
    stats_source: enum { native, ps, unavailable },
    cpu_percent: ?f32,
    cpu_time_ns: ?u64,
    memory_bytes: ?u64,
    memory_kind: enum { physical_footprint, resident_set },
    threads: ?u32,
    wakeups_last_interval: ?u32,
    disk_read_bytes: ?u64,
    disk_written_bytes: ?u64,
};

fn process(p: model.Process, rates: bool) Process {
    return .{
        .pid = p.pid,
        .parent_pid = p.ppid,
        .uid = p.uid,
        .name = safe(p.name),
        .user = safe(p.user),
        .bundle = safe(p.bundle),
        .stats_source = if (!p.known) .unavailable else if (p.from_ps) .ps else .native,
        .cpu_percent = if (p.known and p.cpu_known and rates) p.cpu else null,
        .cpu_time_ns = if (p.known) p.cpu_time_ns else null,
        .memory_bytes = if (p.known) p.memory else null,
        .memory_kind = if (builtin.os.tag == .macos and !p.from_ps) .physical_footprint else .resident_set,
        .threads = if (p.detailed() and p.threads > 0) p.threads else null,
        .wakeups_last_interval = if (builtin.os.tag == .macos and p.detailed() and p.cpu_known and rates) p.wakeups else null,
        .disk_read_bytes = if (p.disk_known) p.disk_read else null,
        .disk_written_bytes = if (p.disk_known) p.disk_written else null,
    };
}

pub fn execute(gpa: std.mem.Allocator, q: Query, d: Data) ![]u8 {
    const rates = d.interval_seconds != null and d.sampler.samples > 1;
    switch (q) {
        .system => return system(gpa, d, rates),
        .process => |pid| {
            for (d.sampler.procs.items) |p| {
                if (p.pid == pid) return json.Stringify.valueAlloc(gpa, .{ .meta = metadata(d), .process = process(p, rates) }, .{});
            }
            return error.ProcessNotFound;
        },
        .processes => |a| {
            var rows: std.ArrayList(model.Process) = .empty;
            defer rows.deinit(gpa);
            for (d.sampler.procs.items) |p| {
                var buf: [16]u8 = undefined;
                const pid = std.fmt.bufPrint(&buf, "{d}", .{p.pid}) catch unreachable;
                if (a.query.len > 0 and std.ascii.findIgnoreCase(p.name, a.query) == null and
                    std.ascii.findIgnoreCase(p.user, a.query) == null and std.mem.indexOf(u8, pid, a.query) == null) continue;
                try rows.append(gpa, p);
            }
            model.sort(rows.items, a.sort_by, a.sort_by == .name or a.sort_by == .pid);
            const start = @min(rows.items.len, a.offset);
            const end = @min(rows.items.len, start + a.limit);
            const out = try gpa.alloc(Process, end - start);
            defer gpa.free(out);
            for (rows.items[start..end], out) |p, *o| o.* = process(p, rates);
            return json.Stringify.valueAlloc(gpa, .{
                .meta = metadata(d),
                .total_matching = rows.items.len,
                .offset = a.offset,
                .next_offset = if (end < rows.items.len) @as(?usize, end) else null,
                .processes = out,
            }, .{});
        },
        .history => |a| return history(gpa, d, a.metric, a.max_points),
    }
}

fn system(gpa: std.mem.Allocator, d: Data, rates: bool) ![]u8 {
    const s = d.sampler;
    const sy = s.system;
    var info = s.info;
    inline for (@typeInfo(model.Info).@"struct".field_names) |name| {
        if (@TypeOf(@field(info, name)) == []const u8) @field(info, name) = safe(@field(info, name));
    }
    const mac = builtin.os.tag == .macos;
    const cpu_rates = rates and sy.rate_available.cpu;
    const disk_rates = rates and sy.rate_available.disk;
    const net_rates = rates and sy.rate_available.network;
    return json.Stringify.valueAlloc(gpa, .{
        .meta = metadata(d),
        .info = info,
        .cpu = .{
            .logical_cpus = if (sy.available.cpu) @as(?u32, sy.cores) else null,
            .user_percent = if (cpu_rates) @as(?f32, sy.cpu_user) else null,
            .system_percent = if (cpu_rates) @as(?f32, sy.cpu_system) else null,
            .busy_percent = if (cpu_rates) @as(?f32, sy.cpuBusy()) else null,
            .per_core_percent = if (cpu_rates) @as(?[]const f32, s.core_load[0..@min(s.cores, sample.max_cores)]) else null,
            .load_average_1_5_15_minutes = sy.load,
        },
        .memory = if (sy.available.memory) .{
            .total_bytes = sy.mem_total,
            .used_bytes = sy.memUsed(),
            .app_bytes = sy.mem_app,
            .wired_bytes = if (mac) @as(?u64, sy.mem_wired) else null,
            .compressed_bytes = if (mac) @as(?u64, sy.mem_compressed) else null,
            .cached_bytes = sy.mem_cached,
            .swap_used_bytes = sy.swap_used,
            .pressure_percent = sy.pressure,
        } else null,
        .disk = if (sy.available.disk) .{
            .read_operations = sy.reads,
            .write_operations = sy.writes,
            .read_bytes = sy.read_bytes,
            .written_bytes = sy.written_bytes,
            .read_bytes_per_second = if (disk_rates) @as(?f32, sy.read_sec) else null,
            .written_bytes_per_second = if (disk_rates) @as(?f32, sy.written_sec) else null,
            .read_operations_per_second = if (disk_rates) @as(?f32, sy.reads_sec) else null,
            .write_operations_per_second = if (disk_rates) @as(?f32, sy.writes_sec) else null,
        } else null,
        .network = if (sy.available.network) .{
            .received_bytes = sy.net_in,
            .sent_bytes = sy.net_out,
            .received_bytes_per_second = if (net_rates) @as(?f32, sy.net_in_sec) else null,
            .sent_bytes_per_second = if (net_rates) @as(?f32, sy.net_out_sec) else null,
            .excludes_loopback = true,
        } else null,
        .gpu = if (sy.available.gpu) .{
            .busy_percent = sy.gpu,
            .renderer_percent = sy.gpu_renderer,
            .tiler_percent = sy.gpu_tiler,
            .memory_bytes = sy.gpu_memory,
        } else null,
        .temperature_celsius = .{
            .cpu = if (sy.cpu_temp > 0) @as(?f32, sy.cpu_temp) else null,
            .cpu_max = if (sy.cpu_temp_max > 0) @as(?f32, sy.cpu_temp_max) else null,
            .gpu = if (sy.gpu_temp > 0) @as(?f32, sy.gpu_temp) else null,
            .soc = if (sy.soc_temp > 0) @as(?f32, sy.soc_temp) else null,
        },
        .thermal_state = if (mac) @as(?u8, sy.thermal) else null,
        .uptime_seconds = sy.uptime_s,
        .visible_process_count = s.procs.items.len,
        .system_thread_count = if (sy.threads > 0) @as(?u32, sy.threads) else null,
    }, .{});
}

fn history(gpa: std.mem.Allocator, d: Data, metric: Metric, max_points: usize) ![]u8 {
    const s = d.sampler;
    if (metric == .gpu_percent and !s.system.available.gpu) {
        for (d.stamps) |stamp| {
            if (stamp.available.gpu) break;
        } else return error.MetricUnavailable;
    }
    const h = switch (metric) {
        .cpu_user_percent => &s.user_history,
        .cpu_system_percent => &s.system_history,
        .memory_pressure_percent => &s.pressure_history,
        .memory_app_percent => &s.app_history,
        .gpu_percent => &s.gpu_history,
        .disk_read_bytes_per_second => &s.read_history,
        .disk_written_bytes_per_second => &s.write_history,
        .network_in_bytes_per_second => &s.in_history,
        .network_out_bytes_per_second => &s.out_history,
    };
    const count = @min(h.len, d.stamps.len);
    const start = count - @min(count, max_points);
    const Point = struct { sampled_at_unix_ms: i64, value: ?f32 };
    const points = try gpa.alloc(Point, count - start);
    defer gpa.free(points);
    for (points, start..) |*p, i| {
        const stamp = d.stamps[i];
        const available = switch (metric) {
            .cpu_user_percent, .cpu_system_percent => stamp.rates.cpu,
            .memory_pressure_percent, .memory_app_percent => stamp.available.memory,
            .gpu_percent => stamp.available.gpu,
            .disk_read_bytes_per_second, .disk_written_bytes_per_second => stamp.rates.disk,
            .network_in_bytes_per_second, .network_out_bytes_per_second => stamp.rates.network,
        };
        p.* = .{ .sampled_at_unix_ms = stamp.at_ms, .value = if (available) h.values[i] else null };
    }
    return json.Stringify.valueAlloc(gpa, .{
        .meta = metadata(d),
        .metric = metric,
        .unit = switch (metric) {
            .cpu_user_percent, .cpu_system_percent, .memory_pressure_percent, .memory_app_percent, .gpu_percent => "percent",
            else => "bytes/second",
        },
        .points = points,
    }, .{});
}

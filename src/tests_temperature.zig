//! Differential preservation of the original ordered float aggregation.
const std = @import("std");
const temperature = @import("temperature.zig");
const Reading = struct { name: ?[]const u8, value: ?f32 };
const Source = struct {
    readings: []const Reading,
    requested: [256]usize = undefined,
    count: usize = 0,
    pub fn len(s: *Source) usize {
        return s.readings.len;
    }
    pub fn name(s: *Source, i: usize, buf: *[96]u8) ?[]const u8 {
        const label = s.readings[i].name orelse return null;
        if (label.len >= buf.len) return null;
        @memcpy(buf[0..label.len], label);
        buf[label.len] = 0;
        return std.mem.sliceTo(buf, 0);
    }
    pub fn value(s: *Source, i: usize) ?f32 {
        s.requested[s.count] = i;
        s.count += 1;
        return s.readings[i].value;
    }
};

fn original(s: *Source) temperature.Temps {
    var cpu: [2]f32 = .{ 0, 0 };
    var gpu: [2]f32 = .{ 0, 0 };
    var soc: [2]f32 = .{ 0, 0 };
    var hottest: f32 = 0;
    for (0..s.len()) |i| {
        var buf: [96]u8 = undefined;
        const name = s.name(i, &buf) orelse continue;
        const c = s.value(i) orelse continue;
        if (c <= 5 or c >= 130) continue;
        if (std.mem.indexOf(u8, name, "GPU") != null) {
            gpu[0] += c;
            gpu[1] += 1;
        } else if (std.mem.indexOf(u8, name, "tdie") != null or std.mem.indexOf(u8, name, "ACC MTR") != null or std.mem.indexOf(u8, name, "CPU") != null) {
            cpu[0] += c;
            cpu[1] += 1;
            hottest = @max(hottest, c);
        } else if (std.mem.indexOf(u8, name, "tdev") != null or std.mem.indexOf(u8, name, "SOC") != null) {
            soc[0] += c;
            soc[1] += 1;
        }
    }
    return .{
        .cpu = if (cpu[1] > 0) cpu[0] / cpu[1] else 0,
        .cpu_max = hottest,
        .gpu = if (gpu[1] > 0) gpu[0] / gpu[1] else 0,
        .soc = if (soc[1] > 0) soc[0] / soc[1] else 0,
    };
}

fn same(a: temperature.Temps, b: temperature.Temps) !void {
    inline for (@typeInfo(temperature.Temps).@"struct".field_names) |field|
        try std.testing.expectEqual(@as(u32, @bitCast(@field(a, field))), @as(u32, @bitCast(@field(b, field))));
}

test "temperature filtering preserves original bits and relative request order" {
    var rng: std.Random.DefaultPrng = .init(0x1207eaf);
    const random = rng.random();
    const long: [96]u8 = @splat('x');
    const names = [_]?[]const u8{ null, "", "NAND", "PMU tdie0", "ACC MTR", "CPU die", "GPU CPU SOC", "SOC CPU", "SOC", "tdev", "gpu", "CPU\x00GPU", &long };
    var readings: [256]Reading = undefined;
    for (0..100) |round| {
        for (&readings, 0..) |*r, i| r.* = .{
            .name = names[random.uintLessThan(usize, names.len)],
            .value = switch ((i + round) % 17) {
                0 => null,
                1 => std.math.nan(f32),
                2 => std.math.inf(f32),
                3 => -std.math.inf(f32),
                4 => -0.0,
                5 => 5,
                6 => 130,
                else => @as(f32, @floatFromInt(random.int(u8))) / 2,
            },
        };
        var old: Source = .{ .readings = readings[0..@min(round * 5, readings.len)] };
        var new: Source = .{ .readings = old.readings };
        const wanted = original(&old);
        try same(wanted, temperature.collect(&new, true));
        var expected: usize = 0;
        for (0..old.count) |i| {
            const index = old.requested[i];
            var buf: [96]u8 = undefined;
            if (temperature.classify(old.name(index, &buf).?) == .none) continue;
            try std.testing.expectEqual(index, new.requested[expected]);
            expected += 1;
        }
        try std.testing.expectEqual(expected, new.count);
        var reference: Source = .{ .readings = old.readings };
        try same(wanted, temperature.collect(&reference, false));
    }
}

test "temperature reads fresh labels, preserves precedence, and omits only irrelevant events" {
    var readings = [_]Reading{
        .{ .name = "NAND", .value = 99 }, .{ .name = "PMU tdie0", .value = 50 },
        .{ .name = "CPU", .value = 54 },  .{ .name = "GPU CPU SOC", .value = 61 },
        .{ .name = "SOC", .value = 40 },  .{ .name = "CPU", .value = null },
    };
    var source: Source = .{ .readings = &readings };
    try same(.{ .cpu = 52, .cpu_max = 54, .gpu = 61, .soc = 40 }, temperature.collect(&source, true));
    try std.testing.expectEqual(5, source.count);
    readings[0].name = "CPU";
    source.count = 0;
    const changed = temperature.collect(&source, true);
    try std.testing.expectEqual(@as(f32, 99), changed.cpu_max);
    try std.testing.expectEqual(6, source.count);
}

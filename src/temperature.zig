//! Temperature aggregation and demand-driven reads, independent of IOKit.
//! Preserve sensor order and floating-point operations; never reassociate sums.
const std = @import("std");
pub const Temps = struct { cpu: f32 = 0, cpu_max: f32 = 0, gpu: f32 = 0, soc: f32 = 0 };
pub const Part = enum { none, cpu, gpu, soc };

pub fn classify(name: []const u8) Part {
    const has = struct {
        fn f(n: []const u8, part: []const u8) bool {
            return std.mem.indexOf(u8, n, part) != null;
        }
    }.f;
    if (has(name, "GPU")) return .gpu;
    if (has(name, "tdie") or has(name, "ACC MTR") or has(name, "CPU")) return .cpu;
    if (has(name, "tdev") or has(name, "SOC")) return .soc;
    return .none;
}

/// Source supplies fresh names and optional values by index. Only skip a value
/// request when its name contributes to NO output, including when it is NaN.
/// `filtered=false` is the original reference path for the native A/B benchmark.
pub fn collect(source: anytype, filtered: bool) Temps {
    var sum: Sum = .{};
    var i: usize = 0;
    const count = source.len();
    while (i < count) : (i += 1) {
        var buf: [96]u8 = undefined;
        const name = source.name(i, &buf) orelse continue;
        const part = classify(name);
        if (filtered and part == .none) continue;
        const value = source.value(i) orelse continue;
        sum.addPart(part, value);
    }
    return sum.temps();
}

pub const Sum = struct {
    cpu: [2]f32 = .{ 0, 0 },
    gpu: [2]f32 = .{ 0, 0 },
    soc: [2]f32 = .{ 0, 0 },
    hottest: f32 = 0,

    pub fn add(s: *Sum, name: []const u8, c: f32) void {
        s.addPart(classify(name), c);
    }

    pub fn addPart(s: *Sum, part: Part, c: f32) void {
        // Same rejection/comparison rules as the original, including IEEE NaNs.
        if (c <= 5 or c >= 130) return;
        switch (part) {
            .none => {},
            .gpu => {
                s.gpu[0] += c;
                s.gpu[1] += 1;
            },
            .cpu => {
                s.cpu[0] += c;
                s.cpu[1] += 1;
                s.hottest = @max(s.hottest, c);
            },
            .soc => {
                s.soc[0] += c;
                s.soc[1] += 1;
            },
        }
    }

    pub fn temps(s: Sum) Temps {
        const mean = struct {
            fn f(p: [2]f32) f32 {
                return if (p[1] > 0) p[0] / p[1] else 0;
            }
        }.f;
        return .{ .cpu = mean(s.cpu), .cpu_max = s.hottest, .gpu = mean(s.gpu), .soc = mean(s.soc) };
    }
};

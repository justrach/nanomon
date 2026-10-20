//! How hot the chip runs, in degrees, without admin rights: the system's
//! temperature sensors as IOKit's HID event system lists them (the
//! vendor page 0xff00, usage 5), the way menu bar monitors read them. The
//! CPU's dies ("tdie", or "ACC MTR" on newer chips) give the CPU's mean and
//! its hottest; GPU sensors the GPU's, when the chip names any; the rest of
//! the SoC ("tdev") stands in otherwise.
const std = @import("std");

extern "c" fn IOHIDEventSystemClientCreate(allocator: ?*anyopaque) ?*anyopaque;
extern "c" fn IOHIDEventSystemClientSetMatching(client: *anyopaque, matching: *anyopaque) c_int;
extern "c" fn IOHIDEventSystemClientCopyServices(client: *anyopaque) ?*anyopaque;
extern "c" fn IOHIDServiceClientCopyProperty(service: *anyopaque, key: *anyopaque) ?*anyopaque;
extern "c" fn IOHIDServiceClientCopyEvent(service: *anyopaque, kind: i64, options: i32, timestamp: i64) ?*anyopaque;
extern "c" fn IOHIDEventGetFloatValue(event: *anyopaque, field: i32) f64;
extern "c" fn CFArrayGetCount(array: *anyopaque) isize;
extern "c" fn CFArrayGetValueAtIndex(array: *anyopaque, i: isize) *anyopaque;
extern "c" fn CFStringCreateWithCString(allocator: ?*anyopaque, s: [*:0]const u8, encoding: u32) ?*anyopaque;
extern "c" fn CFStringGetCString(s: *anyopaque, buf: [*]u8, len: isize, encoding: u32) bool;
extern "c" fn CFNumberCreate(allocator: ?*anyopaque, kind: isize, value: *const anyopaque) ?*anyopaque;
extern "c" fn CFDictionaryCreate(allocator: ?*anyopaque, keys: [*]const *anyopaque, values: [*]const *anyopaque, n: isize, kc: ?*const anyopaque, vc: ?*const anyopaque) ?*anyopaque;
extern "c" fn CFRelease(obj: *anyopaque) void;
extern "c" const kCFTypeDictionaryKeyCallBacks: u8;
extern "c" const kCFTypeDictionaryValueCallBacks: u8;

const utf8: u32 = 0x08000100;
/// kIOHIDEventTypeTemperature, and its value's field.
const temperature: i64 = 15;
const field: i32 = 15 << 16;

/// Degrees Celsius; 0 where nothing was read.
pub const Temps = struct { cpu: f32 = 0, cpu_max: f32 = 0, gpu: f32 = 0, soc: f32 = 0 };

pub const Sensors = struct {
    client: ?*anyopaque = null,
    services: ?*anyopaque = null,
    product: ?*anyopaque = null,
    tried: bool = false,

    pub fn deinit(s: *Sensors) void {
        if (s.services) |o| CFRelease(o);
        if (s.product) |o| CFRelease(o);
        if (s.client) |o| CFRelease(o);
        s.* = .{ .tried = true };
    }

    fn open(s: *Sensors) void {
        s.tried = true;
        const client = IOHIDEventSystemClientCreate(null) orelse return;
        s.client = client;
        const page: i32 = 0xff00;
        const usage: i32 = 5;
        const k0 = CFStringCreateWithCString(null, "PrimaryUsagePage", utf8) orelse return;
        defer CFRelease(k0);
        const k1 = CFStringCreateWithCString(null, "PrimaryUsage", utf8) orelse return;
        defer CFRelease(k1);
        const v0 = CFNumberCreate(null, 3, &page) orelse return;
        defer CFRelease(v0);
        const v1 = CFNumberCreate(null, 3, &usage) orelse return;
        defer CFRelease(v1);
        const keys = [_]*anyopaque{ k0, k1 };
        const values = [_]*anyopaque{ v0, v1 };
        const matching = CFDictionaryCreate(null, &keys, &values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return;
        defer CFRelease(matching);
        _ = IOHIDEventSystemClientSetMatching(client, matching);
        s.services = IOHIDEventSystemClientCopyServices(client);
        s.product = CFStringCreateWithCString(null, "Product", utf8);
    }

    /// Every sensor now, summed up by part.
    pub fn read(s: *Sensors) Temps {
        if (!s.tried) s.open();
        const services = s.services orelse return .{};
        const product = s.product orelse return .{};
        var sum: Sum = .{};
        var i: isize = 0;
        while (i < CFArrayGetCount(services)) : (i += 1) {
            const svc = CFArrayGetValueAtIndex(services, i);
            const name_ref = IOHIDServiceClientCopyProperty(svc, product) orelse continue;
            defer CFRelease(name_ref);
            var buf: [96]u8 = undefined;
            if (!CFStringGetCString(name_ref, &buf, buf.len, utf8)) continue;
            const event = IOHIDServiceClientCopyEvent(svc, temperature, 0, 0) orelse continue;
            defer CFRelease(event);
            sum.add(std.mem.sliceTo(&buf, 0), @floatCast(IOHIDEventGetFloatValue(event, field)));
        }
        return sum.temps();
    }
};

/// Sensors by part, as `read` sorts them (apart, so it's tested).
pub const Sum = struct {
    cpu: [2]f32 = .{ 0, 0 },
    gpu: [2]f32 = .{ 0, 0 },
    soc: [2]f32 = .{ 0, 0 },
    hottest: f32 = 0,

    pub fn add(s: *Sum, name: []const u8, c: f32) void {
        // Readings out of reason are sensors not in use.
        if (c <= 5 or c >= 130) return;
        const has = struct {
            fn f(n: []const u8, part: []const u8) bool {
                return std.mem.indexOf(u8, n, part) != null;
            }
        }.f;
        if (has(name, "GPU")) {
            s.gpu[0] += c;
            s.gpu[1] += 1;
        } else if (has(name, "tdie") or has(name, "ACC MTR") or has(name, "CPU")) {
            s.cpu[0] += c;
            s.cpu[1] += 1;
            s.hottest = @max(s.hottest, c);
        } else if (has(name, "tdev") or has(name, "SOC")) {
            s.soc[0] += c;
            s.soc[1] += 1;
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

test "sensors sort by part: the CPU's dies, the GPU, the rest" {
    var s: Sum = .{};
    s.add("PMU tdie1", 50);
    s.add("PMU tdie2", 54);
    s.add("PMU tdev1", 40);
    s.add("GPU MTR Temp Sensor1", 61);
    s.add("NAND CH0 temp", 42);
    s.add("PMU tdie3", 0);
    const t = s.temps();
    try std.testing.expectEqual(@as(f32, 52), t.cpu);
    try std.testing.expectEqual(@as(f32, 54), t.cpu_max);
    try std.testing.expectEqual(@as(f32, 61), t.gpu);
    try std.testing.expectEqual(@as(f32, 40), t.soc);
}

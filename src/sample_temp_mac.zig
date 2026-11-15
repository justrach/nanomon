//! How hot the chip runs, in degrees, without admin rights: the system's
//! temperature sensors as IOKit's HID event system lists them (the
//! vendor page 0xff00, usage 5), the way menu bar monitors read them. The
//! CPU's dies ("tdie", or "ACC MTR" on newer chips) give the CPU's mean and
//! its hottest; GPU sensors the GPU's, when the chip names any; the rest of
//! the SoC ("tdev") stands in otherwise.
const std = @import("std");
const aggregation = @import("temperature.zig");

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
pub const Temps = aggregation.Temps;
pub const Sum = aggregation.Sum;
pub const Stats = struct { services: usize = 0, events: usize = 0 };

pub const Sensors = struct {
    client: ?*anyopaque = null,
    services: ?*anyopaque = null,
    product: ?*anyopaque = null,
    tried: bool = false,
    /// False only in the native reference benchmark, never in the GUI or MCP.
    filter_events: bool = true,
    last_read: Stats = .{},

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

    /// Names are still read afresh; only irrelevant event requests are skipped.
    /// No cached labels, readings, slower sample cadence or changed averaging.
    pub fn read(s: *Sensors) Temps {
        s.last_read = .{};
        if (!s.tried) s.open();
        const services = s.services orelse return .{};
        const product = s.product orelse return .{};
        var reader: Reader = .{ .services = services, .product = product, .stats = &s.last_read };
        return aggregation.collect(&reader, s.filter_events);
    }
};

const Reader = struct {
    services: *anyopaque,
    product: *anyopaque,
    stats: *Stats,

    pub fn len(r: *Reader) usize {
        r.stats.services = @intCast(CFArrayGetCount(r.services));
        return r.stats.services;
    }

    pub fn name(r: *Reader, index: usize, buf: *[96]u8) ?[]const u8 {
        const svc = CFArrayGetValueAtIndex(r.services, @intCast(index));
        const property = IOHIDServiceClientCopyProperty(svc, r.product) orelse return null;
        defer CFRelease(property);
        if (!CFStringGetCString(property, buf, buf.len, utf8)) return null;
        return std.mem.sliceTo(buf, 0);
    }

    pub fn value(r: *Reader, index: usize) ?f32 {
        r.stats.events += 1;
        const svc = CFArrayGetValueAtIndex(r.services, @intCast(index));
        const event = IOHIDServiceClientCopyEvent(svc, temperature, 0, 0) orelse return null;
        defer CFRelease(event);
        return @floatCast(IOHIDEventGetFloatValue(event, field));
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

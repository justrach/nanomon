//! What IOKit's registry tells anyone who asks: the disks' counters since
//! boot (every block storage driver's "Statistics": operations and bytes,
//! read and written, summed), and the GPU's use (its accelerator's
//! "PerformanceStatistics"), name and core count.
const std = @import("std");

const CFType = *anyopaque;

extern "c" fn IOServiceMatching(name: [*:0]const u8) ?CFType;
extern "c" fn IOServiceGetMatchingServices(port: c_uint, matching: ?CFType, it: *c_uint) c_int;
extern "c" fn IOIteratorNext(it: c_uint) c_uint;
extern "c" fn IOObjectRelease(obj: c_uint) c_int;
extern "c" fn IORegistryEntryCreateCFProperty(entry: c_uint, key: CFType, allocator: ?*anyopaque, options: u32) ?CFType;
extern "c" fn CFDictionaryGetValue(dict: CFType, key: CFType) ?CFType;
extern "c" fn CFNumberGetValue(n: CFType, kind: c_int, out: *anyopaque) u8;
extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, s: [*:0]const u8, encoding: u32) ?CFType;
extern "c" fn CFStringGetCString(s: CFType, buf: [*]u8, size: c_long, encoding: u32) u8;
extern "c" fn CFGetTypeID(x: CFType) c_ulong;
extern "c" fn CFStringGetTypeID() c_ulong;
extern "c" fn CFRelease(x: CFType) void;

const utf8 = 0x08000100;
const sint64 = 4;

pub const Disk = struct { reads: u64 = 0, writes: u64 = 0, read_bytes: u64 = 0, written_bytes: u64 = 0 };
pub const Gpu = struct { device: f32 = 0, renderer: f32 = 0, tiler: f32 = 0, memory: u64 = 0 };

const names = [_][*:0]const u8{
    "Statistics",          "Operations (Read)",      "Operations (Write)",  "Bytes (Read)",
    "Bytes (Write)",       "PerformanceStatistics",  "Device Utilization %", "Renderer Utilization %",
    "Tiler Utilization %", "In use system memory",   "model",               "gpu-core-count",
};
const K = enum(usize) { stats, op_read, op_write, bytes_read, bytes_write, perf, device, renderer, tiler, gpu_memory, model, gpu_cores };

pub const Registry = struct {
    /// The keys asked for, made once.
    keys: ?[names.len]CFType = null,

    pub fn deinit(r: *Registry) void {
        const keys = r.keys orelse return;
        for (keys) |k| CFRelease(k);
        r.keys = null;
    }

    fn key(r: *Registry, k: K) ?CFType {
        if (r.keys == null) {
            var made: [names.len]CFType = undefined;
            for (names, 0..) |n, i| made[i] = CFStringCreateWithCString(null, n, utf8) orelse return null;
            r.keys = made;
        }
        return r.keys.?[@intFromEnum(k)];
    }

    pub fn disks(r: *Registry) Disk {
        var t: Disk = .{};
        const stats = r.key(.stats) orelse return t;
        var it: c_uint = 0;
        // The matching dictionary is consumed by the call.
        if (IOServiceGetMatchingServices(0, IOServiceMatching("IOBlockStorageDriver"), &it) != 0) return t;
        defer _ = IOObjectRelease(it);
        while (true) {
            const entry = IOIteratorNext(it);
            if (entry == 0) break;
            defer _ = IOObjectRelease(entry);
            const d = IORegistryEntryCreateCFProperty(entry, stats, null, 0) orelse continue;
            defer CFRelease(d);
            t.reads += number(d, r.key(.op_read).?);
            t.writes += number(d, r.key(.op_write).?);
            t.read_bytes += number(d, r.key(.bytes_read).?);
            t.written_bytes += number(d, r.key(.bytes_write).?);
        }
        return t;
    }

    /// The first GPU's use now.
    pub fn gpu(r: *Registry) Gpu {
        const entry = accelerator() orelse return .{};
        defer _ = IOObjectRelease(entry);
        const d = IORegistryEntryCreateCFProperty(entry, r.key(.perf) orelse return .{}, null, 0) orelse return .{};
        defer CFRelease(d);
        return .{
            .device = @floatFromInt(number(d, r.key(.device).?)),
            .renderer = @floatFromInt(number(d, r.key(.renderer).?)),
            .tiler = @floatFromInt(number(d, r.key(.tiler).?)),
            .memory = number(d, r.key(.gpu_memory).?),
        };
    }

    /// The first GPU's name (into `buf`) and its cores.
    pub fn gpuInfo(r: *Registry, buf: []u8) struct { name: []const u8, cores: u32 } {
        const entry = accelerator() orelse return .{ .name = "", .cores = 0 };
        defer _ = IOObjectRelease(entry);
        var name: []const u8 = "";
        if (IORegistryEntryCreateCFProperty(entry, r.key(.model) orelse return .{ .name = "", .cores = 0 }, null, 0)) |m| {
            defer CFRelease(m);
            if (CFGetTypeID(m) == CFStringGetTypeID() and CFStringGetCString(m, buf.ptr, @intCast(buf.len), utf8) != 0) name = std.mem.sliceTo(buf, 0);
        }
        var cores: u32 = 0;
        if (IORegistryEntryCreateCFProperty(entry, r.key(.gpu_cores).?, null, 0)) |n| {
            defer CFRelease(n);
            var v: i64 = 0;
            if (CFNumberGetValue(n, sint64, &v) != 0) cores = @intCast(@max(0, v));
        }
        return .{ .name = name, .cores = cores };
    }
};

fn accelerator() ?c_uint {
    var it: c_uint = 0;
    if (IOServiceGetMatchingServices(0, IOServiceMatching("IOAccelerator"), &it) != 0) return null;
    defer _ = IOObjectRelease(it);
    const entry = IOIteratorNext(it);
    return if (entry == 0) null else entry;
}

fn number(dict: CFType, k: CFType) u64 {
    const n = CFDictionaryGetValue(dict, k) orelse return 0;
    var v: i64 = 0;
    if (CFNumberGetValue(n, sint64, &v) == 0) return 0;
    return @intCast(@max(0, v));
}

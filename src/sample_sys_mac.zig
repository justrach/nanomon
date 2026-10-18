//! The rest of the machine on macOS, all public: what it is (sysctl: the
//! chip, its fast and frugal cores, the model, the system, the name; the
//! GPU from IOKit), and how it is doing: load averages, uptime, every task
//! and thread (the default processor set's load), how hot it runs
//! (NSProcessInfo's thermal state), the network (the routing socket's
//! 64-bit interface counters) and the GPU's use.
const std = @import("std");
const nanoui = @import("nanoui");
const sample = @import("sample.zig");
const iokit = @import("sample_iokit_mac.zig");
const Sampler = sample.Sampler;

extern "c" fn sysctlbyname(name: [*:0]const u8, old: ?*anyopaque, oldlen: ?*usize, new: ?*const anyopaque, newlen: usize) c_int;
extern "c" fn sysctl(name: [*]c_int, namelen: c_uint, old: ?*anyopaque, oldlen: *usize, new: ?*anyopaque, newlen: usize) c_int;
extern "c" fn getloadavg(avg: *[3]f64, n: c_int) c_int;
extern "c" fn time(t: ?*i64) i64;
extern "c" fn mach_host_self() c_uint;
extern "c" var mach_task_self_: c_uint;
extern "c" fn processor_set_default(host: c_uint, pset: *c_uint) c_int;
extern "c" fn processor_set_statistics(pset: c_uint, flavor: c_int, info: *[4]c_int, count: *c_uint) c_int;
extern "c" fn mach_port_deallocate(task: c_uint, name: c_uint) c_int;

/// The machine's names, kept for `Info`'s slices.
pub const Text = struct {
    chip: [128]u8 = undefined,
    model: [64]u8 = undefined,
    os: [64]u8 = undefined,
    host: [128]u8 = undefined,
    gpu: [128]u8 = undefined,
    fast: [32]u8 = undefined,
    frugal: [32]u8 = undefined,
};

fn string(name: [*:0]const u8, buf: []u8) []const u8 {
    var len: usize = buf.len;
    if (sysctlbyname(name, buf.ptr, &len, null, 0) != 0 or len == 0) return "";
    return std.mem.sliceTo(buf[0..len], 0);
}

fn int(name: [*:0]const u8) u32 {
    var v: c_int = 0;
    var len: usize = @sizeOf(c_int);
    if (sysctlbyname(name, &v, &len, null, 0) != 0) return 0;
    return @intCast(@max(0, v));
}

/// What the machine is: once.
pub fn machine(s: *Sampler, t: *Text, reg: *iokit.Registry) void {
    const i = &s.info;
    i.chip = string("machdep.cpu.brand_string", &t.chip);
    i.model = string("hw.model", &t.model);
    const ver = string("kern.osproductversion", &t.os);
    i.os = if (ver.len > 0) std.fmt.bufPrint(t.os[ver.len..], "macOS {s}", .{ver}) catch ver else "macOS";
    i.host = string("kern.hostname", &t.host);
    if (std.mem.endsWith(u8, i.host, ".local")) i.host = i.host[0 .. i.host.len - 6];
    // Two kinds of core where there are (Apple silicon), else one.
    if (int("hw.nperflevels") >= 2) {
        i.fast = int("hw.perflevel0.logicalcpu");
        i.frugal = int("hw.perflevel1.logicalcpu");
        const f = string("hw.perflevel0.name", &t.fast);
        const e = string("hw.perflevel1.name", &t.frugal);
        if (f.len > 0) i.fast_name = f;
        if (e.len > 0) i.frugal_name = e;
    } else i.fast = int("hw.logicalcpu");
    const g = reg.gpuInfo(&t.gpu);
    i.gpu = g.name;
    i.gpu_cores = g.cores;
}

/// How the machine is doing: each sample.
pub fn extras(s: *Sampler, t: *Text, reg: *iokit.Registry) void {
    const sy = &s.system;
    var avg: [3]f64 = @splat(0);
    if (getloadavg(&avg, 3) == 3) sy.load = .{ @floatCast(avg[0]), @floatCast(avg[1]), @floatCast(avg[2]) };
    var boot: [2]i64 = @splat(0);
    var len: usize = @sizeOf([2]i64);
    if (sysctlbyname("kern.boottime", &boot, &len, null, 0) == 0) sy.uptime_s = @intCast(@max(0, time(null) - boot[0]));
    // PROCESSOR_SET_LOAD_INFO: tasks, threads, load, mach factor.
    var pset: c_uint = 0;
    if (processor_set_default(mach_host_self(), &pset) == 0) {
        defer _ = mach_port_deallocate(mach_task_self_, pset);
        var load: [4]c_int = @splat(0);
        var count: c_uint = 4;
        if (processor_set_statistics(pset, 4, &load, &count) == 0) {
            sy.tasks = @intCast(@max(0, load[0]));
            sy.threads = @intCast(@max(0, load[1]));
        }
    }
    sy.thermal = thermal();
    network(s, t);
    const g = reg.gpu();
    sy.gpu = g.device;
    sy.gpu_renderer = g.renderer;
    sy.gpu_tiler = g.tiler;
    sy.gpu_memory = g.memory;
}

fn thermal() u8 {
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const info = objc.msg(objc.Object, objc.class("NSProcessInfo"), "processInfo", .{});
    return @intCast(std.math.clamp(objc.msg(objc.NSInteger, info, "thermalState", .{}), 0, 3));
}

/// Bytes in and out of every interface but loopback, since boot: each
/// interface's MIB data, whose counters are 64-bit (the routing socket's
/// are cut to 32 bits for anyone but root).
fn network(s: *Sampler, _: *Text) void {
    var count: c_int = 0;
    var len: usize = @sizeOf(c_int);
    var sys_mib = [5]c_int{ 4, 18, 0, 1, 1 }; // CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT
    if (sysctl(&sys_mib, 5, &count, &len, null, 0) != 0) return;
    var in: u64 = 0;
    var out: u64 = 0;
    var buf: [256]u8 = undefined;
    var i: c_int = 1;
    while (i <= count) : (i += 1) {
        // IFMIB_IFDATA, the interface, IFDATA_GENERAL: struct ifmibdata,
        // its name first, its flags at 20, and if_data64 (packed) at 52,
        // whose bytes in and out are 64 and 72 into it.
        var mib = [6]c_int{ 4, 18, 0, 2, i, 1 };
        len = buf.len;
        if (sysctl(&mib, 6, &buf, &len, null, 0) != 0 or len < 52 + 80) continue;
        const flags = std.mem.readInt(u32, buf[20..24], .little);
        if (flags & 0x8 != 0) continue; // IFF_LOOPBACK
        in += std.mem.readInt(u64, buf[116..124], .little);
        out += std.mem.readInt(u64, buf[124..132], .little);
    }
    s.system.net_in = in;
    s.system.net_out = out;
}

//! Processes and the system on macOS, through public interfaces (Activity
//! Monitor asks a private daemon, sysmond): libproc for every process's
//! name, parent, user and path, and the CPU time, memory footprint,
//! threads, wake ups and disk bytes of those it may read (the user's own,
//! most of them); `/bin/ps` (setuid, as top) now and then for the system's
//! others; Mach for the CPU's ticks and memory as Activity Monitor splits
//! it; sysctl for swap and memory pressure; IOKit for the disks and the
//! GPU (sample_iokit_mac.zig); the rest of the machine in sample_sys_mac.zig.
const std = @import("std");
const builtin = @import("builtin");
const sample = @import("sample.zig");
const model = @import("model.zig");
const ps_mod = @import("ps.zig");
const iokit = @import("sample_iokit_mac.zig");
const sys = @import("sample_sys_mac.zig");
const Sampler = sample.Sampler;

extern "c" fn proc_listallpids(buf: ?*anyopaque, size: c_int) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buf: *anyopaque, size: c_int) c_int;
extern "c" fn proc_pidpath(pid: c_int, buf: [*]u8, size: u32) c_int;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buf: *anyopaque) c_int;
extern "c" fn mach_timebase_info(info: *[2]u32) c_int;
extern "c" fn mach_host_self() c_uint;
extern "c" fn host_processor_info(host: c_uint, flavor: c_int, count: *c_uint, info: *?[*]c_int, info_count: *c_uint) c_int;
extern "c" fn host_statistics64(host: c_uint, flavor: c_int, info: *anyopaque, count: *c_uint) c_int;
extern "c" fn vm_deallocate(task: c_uint, addr: usize, size: usize) c_int;
extern "c" var mach_task_self_: c_uint;
extern "c" var vm_kernel_page_size: usize;
extern "c" fn sysctlbyname(name: [*:0]const u8, old: ?*anyopaque, oldlen: ?*usize, new: ?*const anyopaque, newlen: usize) c_int;

const PROC_PIDTBSDSHORTINFO = 13;
const PROC_PIDTASKINFO = 4;
const RUSAGE_INFO_V2 = 2;
const PROCESSOR_CPU_LOAD_INFO = 2;
const HOST_VM_INFO64 = 4;

const ShortInfo = extern struct { pid: u32, ppid: u32, pgid: u32, status: u32, comm: [16]u8, flags: u32, uid: u32, gid: u32, ruid: u32, rgid: u32, svuid: u32, svgid: u32, rfu: u32 };

const Rusage = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    pkg_idle_wkups: u64,
    interrupt_wkups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    phys_footprint: u64,
    proc_start_abstime: u64,
    proc_exit_abstime: u64,
    child_user_time: u64,
    child_system_time: u64,
    child_pkg_idle_wkups: u64,
    child_interrupt_wkups: u64,
    child_pageins: u64,
    child_elapsed_abstime: u64,
    diskio_bytesread: u64,
    diskio_byteswritten: u64,
};

const TaskInfo = extern struct {
    virtual_size: u64,
    resident_size: u64,
    total_user: u64,
    total_system: u64,
    threads_user: u64,
    threads_system: u64,
    policy: i32,
    faults: i32,
    pageins: i32,
    cow_faults: i32,
    messages_sent: i32,
    messages_received: i32,
    syscalls_mach: i32,
    syscalls_unix: i32,
    csw: i32,
    threadnum: i32,
    numrunning: i32,
    priority: i32,
};

const SwapUsage = extern struct { total: u64, avail: u64, used: u64, pagesize: u32, encrypted: bool };

const VmStats = extern struct {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u64,
    reactivations: u64,
    pageins: u64,
    pageouts: u64,
    faults: u64,
    cow_faults: u64,
    lookups: u64,
    hits: u64,
    purges: u64,
    purgeable_count: u32,
    speculative_count: u32,
    decompressions: u64,
    compressions: u64,
    swapins: u64,
    swapouts: u64,
    compressor_page_count: u32,
    throttled_count: u32,
    external_page_count: u32,
    internal_page_count: u32,
    total_uncompressed_pages_in_compressor: u64,
};

pub const State = struct {
    /// Mach time to nanoseconds.
    num: u64 = 0,
    den: u64 = 1,
    pids: []c_int = &.{},
    ps: ps_mod.Ps = .{},
    mem_total: u64 = 0,
    cores: u32 = 1,
    reg: iokit.Registry = .{},
    sensors: @import("sample_temp_mac.zig").Sensors = .{},
    text: sys.Text = .{},
    /// What the machine is has been read.
    known_machine: bool = false,
};

pub fn deinit(s: *Sampler) void {
    if (s.state.pids.len > 0) s.gpa.free(s.state.pids);
    s.state.ps.deinit(s.gpa);
    s.state.reg.deinit();
    s.state.sensors.deinit();
}

const Namer = struct {
    pid: i32,
    comm: []const u8,

    pub fn name(n: Namer, buf: []u8) []const u8 {
        const len = proc_pidpath(n.pid, buf.ptr, @intCast(buf.len));
        if (len > 0) return buf[0..@intCast(len)];
        return n.comm;
    }
};

/// What ps said last of `pid`, if it said.
pub fn known(s: *Sampler, pid: i32) ?ps_mod.Known {
    return s.state.ps.get(pid);
}

pub fn collect(s: *Sampler) sample.Ticks {
    const st = &s.state;
    if (st.num == 0) once(st);
    if (st.pids.len == 0) st.pids = s.gpa.alloc(c_int, 16384) catch return .{};
    const n_pids: usize = @intCast(@max(0, proc_listallpids(st.pids.ptr, @intCast(st.pids.len * @sizeOf(c_int)))));
    s.procs.ensureTotalCapacity(s.gpa, n_pids) catch return .{};
    var info: ShortInfo = undefined;
    var ru: Rusage = undefined;
    var ti: TaskInfo = undefined;
    for (st.pids[0..@min(n_pids, st.pids.len)]) |pid| {
        if (pid <= 0) continue;
        if (proc_pidinfo(pid, PROC_PIDTBSDSHORTINFO, 0, &info, @sizeOf(ShortInfo)) != @sizeOf(ShortInfo)) continue;
        const comm = std.mem.sliceTo(&info.comm, 0);
        const named = s.name(pid, Namer{ .pid = pid, .comm = comm });
        var p: model.Process = .{
            .pid = pid,
            .ppid = @intCast(info.ppid),
            .uid = info.uid,
            .name = named.name,
            .bundle = named.bundle,
            .user = s.user(info.uid),
        };
        if (proc_pid_rusage(pid, RUSAGE_INFO_V2, &ru) == 0) {
            p.cpu_time_ns = (ru.user_time + ru.system_time) * st.num / st.den;
            p.memory = ru.phys_footprint;
            // Package idle exits on Intel; on Apple silicon (where that
            // stays 0), interrupt wake ups, as Activity Monitor counts them.
            p.wakeups_total = if (comptime builtin.cpu.arch == .aarch64) ru.interrupt_wkups else ru.pkg_idle_wkups;
            p.disk_read = ru.diskio_bytesread;
            p.disk_written = ru.diskio_byteswritten;
            if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, @sizeOf(TaskInfo)) == @sizeOf(TaskInfo)) p.threads = @intCast(@max(0, ti.threadnum));
            p.known = true;
        } else if (st.ps.get(pid)) |said| {
            // Not ours to read: what ps (setuid) said last.
            p.cpu_time_ns = said.time_ns;
            p.memory = said.rss;
            p.known = true;
            p.from_ps = true;
        }
        s.procs.appendAssumeCapacity(p);
    }
    st.ps.notify = s.on_update;
    st.ps.refresh(s.gpa, s.samples);
    system(s);
    if (!st.known_machine) {
        st.known_machine = true;
        sys.machine(s, &st.text, &st.reg);
    }
    sys.extras(s, &st.text, &st.reg);
    const t = st.sensors.read();
    s.system.cpu_temp = t.cpu;
    s.system.cpu_temp_max = t.cpu_max;
    s.system.gpu_temp = t.gpu;
    s.system.soc_temp = t.soc;
    return ticks(s);
}

fn once(st: *State) void {
    var tb: [2]u32 = .{ 1, 1 };
    _ = mach_timebase_info(&tb);
    st.num = tb[0];
    st.den = @max(1, tb[1]);
    var len: usize = @sizeOf(u64);
    _ = sysctlbyname("hw.memsize", &st.mem_total, &len, null, 0);
    var cores: c_int = 1;
    len = @sizeOf(c_int);
    _ = sysctlbyname("hw.logicalcpu", &cores, &len, null, 0);
    st.cores = @intCast(@max(1, cores));
}

/// Memory as Activity Monitor splits it: app memory (anonymous pages not
/// purgeable), wired, compressed; cached files (file-backed and purgeable).
fn system(s: *Sampler) void {
    const st = &s.state;
    var vm: VmStats = undefined;
    var count: c_uint = @sizeOf(VmStats) / @sizeOf(c_int);
    s.system.mem_total = st.mem_total;
    s.system.cores = st.cores;
    var swap: SwapUsage = undefined;
    var len: usize = @sizeOf(SwapUsage);
    if (sysctlbyname("vm.swapusage", &swap, &len, null, 0) == 0) s.system.swap_used = swap.used;
    // The share of memory the kernel counts as available, as a percent.
    var level: c_int = 100;
    len = @sizeOf(c_int);
    if (sysctlbyname("kern.memorystatus_level", &level, &len, null, 0) == 0) s.system.pressure = @floatFromInt(std.math.clamp(100 - level, 0, 100));
    const io = st.reg.disks();
    s.system.reads = io.reads;
    s.system.writes = io.writes;
    s.system.read_bytes = io.read_bytes;
    s.system.written_bytes = io.written_bytes;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, &vm, &count) != 0) return;
    const page: u64 = vm_kernel_page_size;
    s.system.mem_app = (@as(u64, vm.internal_page_count) -| vm.purgeable_count) * page;
    s.system.mem_wired = @as(u64, vm.wire_count) * page;
    s.system.mem_compressed = @as(u64, vm.compressor_page_count) * page;
    s.system.mem_cached = (@as(u64, vm.external_page_count) + vm.purgeable_count) * page;
}

/// Every core's ticks since boot (kept for each core), summed: user (and
/// nice), system, idle.
fn ticks(s: *Sampler) sample.Ticks {
    var cpus: c_uint = 0;
    var info: ?[*]c_int = null;
    var count: c_uint = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) != 0) return .{};
    const data = info orelse return .{};
    defer _ = vm_deallocate(mach_task_self_, @intFromPtr(data), count * @sizeOf(c_int));
    var t: sample.Ticks = .{};
    for (0..cpus) |i| {
        // CPU_STATE_USER, SYSTEM, IDLE, NICE.
        const c = data[i * 4 ..][0..4];
        const core: sample.Ticks = .{
            .user = @as(u64, @as(u32, @bitCast(c[0]))) + @as(u32, @bitCast(c[3])),
            .system = @as(u32, @bitCast(c[1])),
            .idle = @as(u32, @bitCast(c[2])),
        };
        if (i < sample.max_cores) s.core_ticks[i] = core;
        t.user += core.user;
        t.system += core.system;
        t.idle += core.idle;
    }
    s.cores = @min(cpus, sample.max_cores);
    return t;
}

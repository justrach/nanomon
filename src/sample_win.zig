//! Processes and the system on Windows, from public interfaces:
//! NtQuerySystemInformation lists every process (its path, parent, CPU time,
//! threads, private working set and disk bytes), each processor's ticks, the
//! machine's I/O since boot and the system's memory; each process's owner
//! comes from its token. sample_sys_win.zig has what the machine is, its
//! network and its uptime.
const std = @import("std");
const sample = @import("sample.zig");
const model = @import("model.zig");
const sys = @import("sample_sys_win.zig");
const Sampler = sample.Sampler;
const HANDLE = std.os.windows.HANDLE;
const DWORD = u32;
const BOOL = i32;
const WCHAR = u16;

/// NtQuerySystemInformation's classes.
const system_performance_information = 2;
const system_process_information = 5;
const system_processor_performance_information = 8;

const status_info_length_mismatch: i32 = @bitCast(@as(u32, 0xC0000004));

const process_query_limited_information: DWORD = 0x1000;
const process_terminate: DWORD = 0x0001;
const token_query: DWORD = 0x0008;
const token_user = 1;
const gw_owner = 4;
const wm_close = 0x0010;

extern "ntdll" fn NtQuerySystemInformation(class: u32, info: [*]u8, len: u32, ret: ?*u32) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn GetActiveProcessorCount(group: u16) callconv(.winapi) u16;
extern "kernel32" fn QueryFullProcessImageNameW(process: HANDLE, flags: DWORD, name: [*]WCHAR, size: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn EnumWindows(cb: *const fn (HANDLE, isize) callconv(.winapi) BOOL, l: isize) callconv(.winapi) BOOL;
extern "kernel32" fn GetWindowThreadProcessId(w: HANDLE, pid: *DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetWindow(w: HANDLE, cmd: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn IsWindowVisible(w: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn PostMessageW(w: HANDLE, msg: u32, wp: usize, lp: isize) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalMemoryStatusEx(m: *MemoryStatus) callconv(.winapi) BOOL;
extern "kernel32" fn K32GetPerformanceInfo(info: *PerformanceInfo, cb: DWORD) callconv(.winapi) BOOL;
extern "advapi32" fn OpenProcessToken(p: HANDLE, access: DWORD, token: *HANDLE) callconv(.winapi) BOOL;
extern "advapi32" fn GetTokenInformation(token: HANDLE, class: DWORD, info: [*]u8, len: DWORD, ret: *DWORD) callconv(.winapi) BOOL;
extern "advapi32" fn LookupAccountSidW(system: ?[*:0]const u16, sid: [*]const u8, name: [*]WCHAR, name_len: *DWORD, domain: [*]WCHAR, domain_len: *DWORD, use: *DWORD) callconv(.winapi) BOOL;

/// UNICODE_STRING, as SYSTEM_PROCESS_INFORMATION holds it.
const UnicodeString = extern struct {
    Length: u16,
    MaximumLength: u16,
    Buffer: ?[*]WCHAR,
};

/// SYSTEM_PROCESS_INFORMATION, the 64-bit layout: what the kernel says of
/// one process. The threads follow it, and the next entry after them.
const ProcessInfo = extern struct {
    NextEntryOffset: u32,
    NumberOfThreads: u32,
    WorkingSetPrivateSize: i64,
    HardFaultCount: u32,
    NumberOfThreadsHighWatermark: u32,
    CycleTime: u64,
    CreateTime: i64,
    UserTime: i64,
    KernelTime: i64,
    ImageName: UnicodeString,
    BasePriority: i32,
    UniqueProcessId: usize,
    InheritedFromUniqueProcessId: usize,
    HandleCount: u32,
    SessionId: u32,
    UniqueProcessKey: usize,
    PeakVirtualSize: usize,
    VirtualSize: usize,
    PageFaultCount: u32,
    PeakWorkingSetSize: usize,
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
    PrivatePageCount: usize,
    ReadOperationCount: i64,
    WriteOperationCount: i64,
    OtherOperationCount: i64,
    ReadTransferCount: i64,
    WriteTransferCount: i64,
    OtherTransferCount: i64,
};

/// SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION: one processor's ticks, in
/// 100-nanosecond units; the kernel's include the idle time.
const ProcessorInfo = extern struct {
    IdleTime: i64,
    KernelTime: i64,
    UserTime: i64,
    DpcTime: i64,
    InterruptTime: i64,
    InterruptCount: u32,
};

/// The start of SYSTEM_PERFORMANCE_INFORMATION: the machine's I/O since
/// boot, and what memory holds.
const PerfInfo = extern struct {
    IdleProcessTime: i64,
    IoReadTransferCount: i64,
    IoWriteTransferCount: i64,
    IoOtherTransferCount: i64,
    IoReadOperationCount: DWORD,
    IoWriteOperationCount: DWORD,
    IoOtherOperationCount: DWORD,
    AvailablePages: DWORD,
    CommittedPages: DWORD,
    CommitLimit: DWORD,
    PeakCommitment: DWORD,
};

/// PERFORMANCE_INFORMATION, from psapi: memory by kind, tasks and threads.
const PerformanceInfo = extern struct {
    cb: DWORD,
    CommitTotal: usize,
    CommitLimit: usize,
    CommitPeak: usize,
    PhysicalTotal: usize,
    PhysicalAvailable: usize,
    SystemCache: usize,
    KernelTotal: usize,
    KernelPaged: usize,
    KernelNonpaged: usize,
    PageSize: usize,
    HandleCount: DWORD,
    ProcessCount: DWORD,
    ThreadCount: DWORD,
};

/// MEMORYSTATUSEX.
const MemoryStatus = extern struct {
    dwLength: DWORD,
    dwMemoryLoad: DWORD,
    ullTotalPhys: u64,
    ullAvailPhys: u64,
    ullTotalPageFile: u64,
    ullAvailPageFile: u64,
    ullTotalVirtual: u64,
    ullAvailVirtual: u64,
    ullAvailExtendedVirtual: u64,
};

/// TOKEN_USER: the SID follows it in the buffer.
const TokenUser = extern struct {
    Sid: ?*anyopaque,
    Attributes: DWORD,
};

comptime {
    // These layouts are the 64-bit ones; a 32-bit build reads nothing.
    if (@sizeOf(usize) == 8) {
        if (@sizeOf(ProcessInfo) != 256) @compileError("SYSTEM_PROCESS_INFORMATION's layout");
        if (@sizeOf(ProcessorInfo) != 48) @compileError("SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION's layout");
        if (@sizeOf(PerformanceInfo) != 104) @compileError("PERFORMANCE_INFORMATION's layout");
        if (@sizeOf(MemoryStatus) != 64) @compileError("MEMORYSTATUSEX's layout");
    }
}

/// The most pids whose owner is remembered.
const max_users = 65536;

pub const State = struct {
    /// The processes' buffer, grown as the list does.
    buf: []u8 = &.{},
    /// Each process's owner: the user's id (0 is nanomon's own).
    uids: std.AutoHashMapUnmanaged(i32, u32) = .empty,
    /// A SID's hash → the user's id, and the next id to give out.
    ids: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    next_user: u32 = 1,
    seeded: bool = false,
    /// When the last sample was, for the load's averages.
    last_ms: u64 = 0,
    have_load: bool = false,
    text: sys.Text = .{},
    known_machine: bool = false,
    /// The GPU's and the thermal zones' counters, kept open.
    pdh: sys.Pdh = .{},
};

pub fn deinit(s: *Sampler) void {
    const st = &s.state;
    if (st.buf.len > 0) s.gpa.free(st.buf);
    st.uids.deinit(s.gpa);
    st.ids.deinit(s.gpa);
    sys.deinit(s);
}

const Namer = struct {
    path: []const u8,

    pub fn name(n: Namer, _: []u8) []const u8 {
        return n.path;
    }
};

pub fn collect(s: *Sampler) sample.Ticks {
    if (comptime @sizeOf(usize) != 8) return .{};
    seed(s);
    processes(s);
    memory(s);
    disks(s);
    const all = ticks(s);
    if (!s.state.known_machine) {
        s.state.known_machine = true;
        sys.machine(s, &s.state.text);
    }
    sys.extras(s, &s.state.text);
    return all;
}

/// The user running nanomon is 0; everyone else comes in the order first
/// seen, so "My Processes" means the same here as it does elsewhere.
fn seed(s: *Sampler) void {
    const st = &s.state;
    if (st.seeded) return;
    st.seeded = true;
    // A process whose owner cannot be read (the system's own, mostly) keeps
    // no name, rather than being taken for the user's.
    const none = s.gpa.alloc(u8, 0) catch return;
    s.users.put(s.gpa, unknown_user, none) catch s.gpa.free(none);
    var buf: [256]u8 align(8) = undefined;
    const sid = tokenSid(GetCurrentProcess(), &buf) orelse return;
    const hash = std.hash.Wyhash.hash(0, sid.ptr[0..sid.len]);
    st.ids.put(s.gpa, hash, 0) catch return;
    nameUser(s, 0, sid);
}

fn processes(s: *Sampler) void {
    const st = &s.state;
    if (st.buf.len < 1 << 20) {
        st.buf = s.gpa.realloc(st.buf, 1 << 20) catch return;
    }
    var need: usize = st.buf.len;
    for (0..6) |_| {
        if (st.buf.len < need) {
            st.buf = s.gpa.realloc(st.buf, need) catch return;
        }
        var len: u32 = 0;
        const status = NtQuerySystemInformation(system_process_information, st.buf.ptr, @intCast(st.buf.len), &len);
        if (status == 0) {
            parse(s, len);
            if (st.uids.count() > max_users) st.uids.clearRetainingCapacity();
            return;
        }
        if (status != status_info_length_mismatch) return;
        need = @max(@as(usize, len) + (64 << 10), st.buf.len * 2);
    }
}

/// A process's program as a path: the kernel's image name is only the file's
/// name for many of them, so the process is asked, once (the answer is cached
/// with its name).
fn fullPath(pid: i32, name: []const u8, buf: []u8) []const u8 {
    if (std.mem.indexOfAny(u8, name, "\\/") != null) return name;
    const h = OpenProcess(process_query_limited_information, 0, @intCast(pid)) orelse return name;
    defer _ = CloseHandle(h);
    var wide: [1024]WCHAR = undefined;
    var size: DWORD = wide.len;
    if (QueryFullProcessImageNameW(h, 0, &wide, &size) == 0) return name;
    const n = std.unicode.utf16LeToUtf8(buf, wide[0..@min(size, wide.len)]) catch return name;
    return buf[0..n];
}

/// What the kernel said of each process, in its answer.
fn parse(s: *Sampler, len: u32) void {
    const st = &s.state;
    const end: usize = @min(st.buf.len, len);
    var at: usize = 0;
    while (at + @sizeOf(ProcessInfo) <= end) {
        const pi: *align(1) const ProcessInfo = @ptrCast(st.buf.ptr + at);
        const pid: i32 = @bitCast(@as(u32, @truncate(pi.UniqueProcessId)));
        // The idle "process" is the time nothing ran, not something that does.
        const next = pi.NextEntryOffset;
        if (pid != 0) {
            const ppid: i32 = @bitCast(@as(u32, @truncate(pi.InheritedFromUniqueProcessId)));
            const uid = userId(st, s, pid);
            var path_buf: [1024]u8 = undefined;
            const wide: []const u16 = if (pi.ImageName.Buffer) |b| b[0 .. pi.ImageName.Length / 2] else &.{};
            const n = std.unicode.utf16LeToUtf8(&path_buf, wide) catch 0;
            var full_buf: [1024]u8 = undefined;
            const path = fullPath(pid, path_buf[0..n], &full_buf);
            const named = if (path.len > 0) s.name(pid, Namer{ .path = path }) else null;
            var p: model.Process = .{
                .pid = pid,
                .ppid = ppid,
                .uid = uid,
                .name = if (named) |nm| nm.name else "System",
                // A program is its own app there: the path its processes share.
                .bundle = if (named) |nm| nm.bundle else "",
                .user = s.user(uid),
                .known = true,
                .threads = pi.NumberOfThreads,
            };
            const user: u64 = @intCast(@max(0, pi.UserTime));
            const kernel: u64 = @intCast(@max(0, pi.KernelTime));
            p.cpu_time_ns = (user + kernel) * 100;
            const private = @max(0, pi.WorkingSetPrivateSize);
            p.memory = if (private > 0) @intCast(private) else pi.WorkingSetSize;
            p.disk_read = @intCast(@max(0, pi.ReadTransferCount));
            p.disk_written = @intCast(@max(0, pi.WriteTransferCount));
            s.procs.append(s.gpa, p) catch return;
        }
        if (next == 0) return;
        at += next;
    }
}

fn ticks(s: *Sampler) sample.Ticks {
    var infos: [sample.max_cores]ProcessorInfo = undefined;
    var len: u32 = 0;
    const bytes: u32 = @intCast(@sizeOf(ProcessorInfo) * infos.len);
    if (NtQuerySystemInformation(system_processor_performance_information, @ptrCast(&infos), bytes, &len) != 0) {
        s.cores = 0;
        s.system.cores = 1;
        return .{};
    }
    var n: usize = len / @sizeOf(ProcessorInfo);
    if (n == 0) n = GetActiveProcessorCount(0xffff);
    n = @min(n, sample.max_cores);
    var total: sample.Ticks = .{};
    for (0..n) |i| {
        const idle: u64 = @intCast(@max(0, infos[i].IdleTime));
        const kernel: u64 = @intCast(@max(0, infos[i].KernelTime));
        const user: u64 = @intCast(@max(0, infos[i].UserTime));
        // The kernel's ticks include the idle ones.
        const these: sample.Ticks = .{ .user = user, .system = kernel -| idle, .idle = idle };
        s.core_ticks[i] = these;
        total.user += these.user;
        total.system += these.system;
        total.idle += these.idle;
    }
    s.cores = @intCast(@min(n, sample.max_cores));
    s.system.cores = @intCast(@max(1, n));
    return total;
}

/// Memory by kind, and every task and thread: as Activity Monitor splits it,
/// from the closest Windows has: the physical total and what is available,
/// the system cache and the kernel's own.
fn memory(s: *Sampler) void {
    const sy = &s.system;
    var m: MemoryStatus = .{ .dwLength = @sizeOf(MemoryStatus), .dwMemoryLoad = 0, .ullTotalPhys = 0, .ullAvailPhys = 0, .ullTotalPageFile = 0, .ullAvailPageFile = 0, .ullTotalVirtual = 0, .ullAvailVirtual = 0, .ullAvailExtendedVirtual = 0 };
    _ = GlobalMemoryStatusEx(&m);
    var perf: PerformanceInfo = .{ .cb = @sizeOf(PerformanceInfo), .CommitTotal = 0, .CommitLimit = 0, .CommitPeak = 0, .PhysicalTotal = 0, .PhysicalAvailable = 0, .SystemCache = 0, .KernelTotal = 0, .KernelPaged = 0, .KernelNonpaged = 0, .PageSize = 4096, .HandleCount = 0, .ProcessCount = 0, .ThreadCount = 0 };
    const ok = K32GetPerformanceInfo(&perf, perf.cb) != 0;
    const page: u64 = if (ok and perf.PageSize > 0) perf.PageSize else 4096;
    const total: u64 = if (m.ullTotalPhys > 0) m.ullTotalPhys else perf.PhysicalTotal * page;
    const avail: u64 = if (m.ullAvailPhys > 0) m.ullAvailPhys else perf.PhysicalAvailable * page;
    sy.mem_total = total;
    sy.mem_cached = @min(perf.SystemCache * page, total);
    // Wired is what cannot be paged out: the non-paged pool. The paged pool
    // and pageable driver code can go to disk, so they are not.
    sy.mem_wired = @min(perf.KernelNonpaged * page, total);
    // Windows compresses memory in a process of its own, and that process's
    // working set is what it holds (as Task Manager counts it).
    var compressed: u64 = 0;
    for (s.procs.items) |p| {
        if (std.mem.eql(u8, p.name, "Memory Compression")) compressed += p.memory;
    }
    sy.mem_compressed = @min(compressed, total);
    // Available memory already counts the cache (standby is free to give up),
    // so what is in use is what is not available.
    sy.mem_app = (total -| avail) -| sy.mem_wired -| sy.mem_compressed;
    // What is committed beyond what memory holds is in the page file.
    sy.swap_used = (perf.CommitTotal -| perf.PhysicalTotal) * page;
    sy.swap_total = perf.CommitLimit * page;
    if (total > 0) sy.pressure = @floatCast(100 - @as(f64, @floatFromInt(avail)) / @as(f64, @floatFromInt(total)) * 100);
    if (ok) {
        sy.tasks = perf.ProcessCount;
        sy.threads = perf.ThreadCount;
    }
}

/// The disks' reads and writes since boot, and their bytes.
fn disks(s: *Sampler) void {
    var buf: [512]u8 align(8) = undefined;
    var len: u32 = 0;
    if (NtQuerySystemInformation(system_performance_information, &buf, buf.len, &len) != 0) return;
    const p: *const PerfInfo = @ptrCast(&buf);
    const sy = &s.system;
    sy.reads = p.IoReadOperationCount;
    sy.writes = p.IoWriteOperationCount;
    sy.read_bytes = @intCast(@max(0, p.IoReadTransferCount));
    sy.written_bytes = @intCast(@max(0, p.IoWriteTransferCount));
}

// Users

const Sid = struct { ptr: [*]const u8, len: usize };

const unknown_user: u32 = std.math.maxInt(u32);

/// The SID of the token `h` holds, in `buf` (which must outlive the SID).
fn tokenSid(h: HANDLE, buf: []align(8) u8) ?Sid {
    var token: HANDLE = undefined;
    if (OpenProcessToken(h, token_query, &token) == 0) return null;
    defer _ = CloseHandle(token);
    var len: DWORD = @intCast(buf.len);
    if (GetTokenInformation(token, token_user, buf.ptr, @intCast(buf.len), &len) == 0) return null;
    if (len < @sizeOf(TokenUser)) return null;
    const tu: *const TokenUser = @ptrCast(buf.ptr);
    const sid = tu.Sid orelse return null;
    const bytes: [*]const u8 = @ptrCast(sid);
    // A SID: revision, how many sub-authorities follow (never many), the
    // authority, then four bytes each.
    const parts = bytes[1];
    if (parts > 15) return null;
    return .{ .ptr = bytes, .len = 8 + @as(usize, parts) * 4 };
}

fn userId(st: *State, s: *Sampler, pid: i32) u32 {
    if (st.uids.get(pid)) |id| return id;
    var buf: [256]u8 align(8) = undefined;
    var id: u32 = unknown_user;
    if (OpenProcess(process_query_limited_information, 0, @intCast(pid))) |h| {
        defer _ = CloseHandle(h);
        if (tokenSid(h, &buf)) |sid| id = idOf(st, s, sid);
    }
    st.uids.put(s.gpa, pid, id) catch {};
    return id;
}

fn idOf(st: *State, s: *Sampler, sid: Sid) u32 {
    const hash = std.hash.Wyhash.hash(0, sid.ptr[0..sid.len]);
    if (st.ids.get(hash)) |id| return id;
    const id = st.next_user;
    st.next_user +%= 1;
    st.ids.put(s.gpa, hash, id) catch return unknown_user;
    nameUser(s, id, sid);
    return id;
}

fn nameUser(s: *Sampler, id: u32, sid: Sid) void {
    var name: [128]WCHAR = undefined;
    var domain: [128]WCHAR = undefined;
    var name_len: DWORD = name.len;
    var domain_len: DWORD = domain.len;
    var use: DWORD = 0;
    var utf: [256]u8 = undefined;
    var n: usize = 0;
    if (LookupAccountSidW(null, sid.ptr, &name, &name_len, &domain, &domain_len, &use) != 0) {
        const all = name[0..@min(name_len, name.len)];
        const chars = all[0 .. std.mem.indexOfScalar(WCHAR, all, 0) orelse all.len];
        n = std.unicode.utf16LeToUtf8(&utf, chars) catch 0;
    }
    const owned = s.gpa.dupe(u8, utf[0..n]) catch return;
    s.users.put(s.gpa, id, owned) catch s.gpa.free(owned);
}

// Quitting

pub fn selfPid() i32 {
    return @bitCast(GetCurrentProcessId());
}

/// Asks process `pid` to close (15), or ends it (9). Asking posts WM_CLOSE to
/// its windows, as Task Manager's End Task does; a process with none is ended.
pub fn signal(pid: i32, sig: c_int) c_int {
    if (sig == 9 or pid <= 0) return terminate(pid);
    var ctx: Close = .{ .pid = @bitCast(pid) };
    _ = EnumWindows(closeWindow, @bitCast(@as(usize, @intFromPtr(&ctx))));
    if (ctx.posted) return 0;
    return terminate(pid);
}

const Close = struct { pid: DWORD, posted: bool = false };

fn closeWindow(w: HANDLE, l: isize) callconv(.winapi) BOOL {
    const ctx: *Close = @ptrFromInt(@as(usize, @bitCast(l)));
    var owner: DWORD = 0;
    _ = GetWindowThreadProcessId(w, &owner);
    if (owner != ctx.pid) return 1;
    // One of its own, top-level and shown: its window to close.
    if (IsWindowVisible(w) == 0 or GetWindow(w, gw_owner) != null) return 1;
    if (PostMessageW(w, wm_close, 0, 0) != 0) ctx.posted = true;
    return 1;
}

fn terminate(pid: i32) c_int {
    if (pid <= 4) return -1;
    const h = OpenProcess(process_terminate, 0, @intCast(pid)) orelse return -1;
    defer _ = CloseHandle(h);
    return if (TerminateProcess(h, 1) != 0) 0 else -1;
}

//! The rest of the machine on Windows: what it is (the registry: the
//! processor's name, the model, the system's name and version, the display
//! adapter; the computer's name), and how it is doing: uptime, the load (the
//! average number of busy cores over the last 1, 5 and 15 minutes), the
//! bytes through every hardware interface, and from performance counters the
//! GPU's use and memory and the thermal zones' temperatures.
const std = @import("std");
const sample = @import("sample.zig");
const Sampler = sample.Sampler;
const HANDLE = std.os.windows.HANDLE;
const DWORD = u32;
const WCHAR = u16;

const hkey_local_machine: HANDLE = @ptrFromInt(0x80000002);
const rrf_rt_reg_sz: DWORD = 0x00000002;
const if_type_software_loopback = 24;
const pdh_double: DWORD = 0x00000200;
const pdh_more_data: i32 = @bitCast(@as(u32, 0x800007D2));

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const three_d = L("engtype_3D");

extern "advapi32" fn RegGetValueW(key: HANDLE, sub: [*:0]const u16, value: [*:0]const u16, flags: DWORD, ty: ?*DWORD, data: ?*anyopaque, len: *DWORD) callconv(.winapi) i32;
extern "kernel32" fn GetComputerNameW(buf: [*]WCHAR, size: *DWORD) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "iphlpapi" fn GetIfTable2(table: *?*anyopaque) callconv(.winapi) DWORD;
extern "iphlpapi" fn FreeMibTable(mem: ?*anyopaque) callconv(.winapi) void;
extern "pdh" fn PdhOpenQueryW(source: ?[*:0]const u16, user: usize, query: *HANDLE) callconv(.winapi) i32;
extern "pdh" fn PdhAddEnglishCounterW(query: HANDLE, path: [*:0]const u16, user: usize, counter: *HANDLE) callconv(.winapi) i32;
extern "pdh" fn PdhCollectQueryData(query: HANDLE) callconv(.winapi) i32;
extern "pdh" fn PdhGetFormattedCounterArrayW(counter: HANDLE, format: DWORD, size: *DWORD, count: *DWORD, items: ?*anyopaque) callconv(.winapi) i32;
extern "pdh" fn PdhCloseQuery(query: HANDLE) callconv(.winapi) i32;

/// The machine's names, kept for `Info`'s slices.
pub const Text = struct {
    chip: [128]u8 = undefined,
    model: [128]u8 = undefined,
    os: [128]u8 = undefined,
    host: [128]u8 = undefined,
    gpu: [128]u8 = undefined,
};

const Guid = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

/// MIB_IF_ROW2: one interface's counters, as GetIfTable2 lays them out.
const IfRow = extern struct {
    InterfaceLuid: u64,
    InterfaceIndex: u32,
    InterfaceGuid: Guid,
    Alias: [257]WCHAR,
    Description: [257]WCHAR,
    PhysicalAddressLength: u32,
    PhysicalAddress: [32]u8,
    PermanentPhysicalAddress: [32]u8,
    Mtu: u32,
    Type: u32,
    TunnelType: u32,
    MediaType: u32,
    PhysicalMediumType: u32,
    AccessType: u32,
    DirectionType: u32,
    InterfaceAndOperStatusFlags: u8,
    OperStatus: u32,
    AdminStatus: u32,
    MediaConnectState: u32,
    NetworkGuid: Guid,
    ConnectionType: u32,
    TransmitLinkSpeed: u64,
    ReceiveLinkSpeed: u64,
    InOctets: u64,
    InUcastPkts: u64,
    InNUcastPkts: u64,
    InDiscards: u64,
    InErrors: u64,
    InUnknownProtos: u64,
    InUcastOctets: u64,
    InMulticastOctets: u64,
    InBroadcastOctets: u64,
    OutOctets: u64,
    OutUcastPkts: u64,
    OutNUcastPkts: u64,
    OutDiscards: u64,
    OutErrors: u64,
    OutUcastOctets: u64,
    OutMulticastOctets: u64,
    OutBroadcastOctets: u64,
    OutQLen: u64,
};

/// MIB_IF_TABLE2's start: how many rows follow it.
const IfTable = extern struct {
    NumEntries: u32,
    Table: [1]IfRow,
};

/// PDH_FMT_COUNTERVALUE_ITEM_W: a counter's name and its value.
const Item = extern struct {
    szName: ?[*:0]WCHAR,
    CStatus: DWORD,
    _pad: DWORD,
    doubleValue: f64,
};

/// The performance-counter query nanomon keeps open, and its counters.
pub const Pdh = struct {
    opened: bool = false,
    query: ?HANDLE = null,
    engine: ?HANDLE = null,
    memory: ?HANDLE = null,
    thermal: ?HANDLE = null,
    pages_in: ?HANDLE = null,
    pages_out: ?HANDLE = null,
    /// Where an array of counter values is read.
    buf: []u8 = &.{},
};

comptime {
    if (@sizeOf(usize) == 8) {
        if (@sizeOf(IfRow) != 1352) @compileError("MIB_IF_ROW2's layout");
        if (@sizeOf(Item) != 24) @compileError("PDH_FMT_COUNTERVALUE_ITEM_W's layout");
    }
}

/// A registry value as text, into `dst`.
fn reg(key: [*:0]const u16, value: [*:0]const u16, dst: []u8) []const u8 {
    var wide: [256]WCHAR = undefined;
    var len: DWORD = @intCast(@sizeOf(@TypeOf(wide)));
    if (RegGetValueW(hkey_local_machine, key, value, rrf_rt_reg_sz, null, &wide, &len) != 0) return "";
    const all = wide[0..@min(len / 2, wide.len)];
    const chars = all[0 .. std.mem.indexOfScalar(WCHAR, all, 0) orelse all.len];
    const n = std.unicode.utf16LeToUtf8(dst, chars) catch return "";
    return dst[0..n];
}

/// What the machine is: once.
pub fn machine(s: *Sampler, t: *Text) void {
    const i = &s.info;
    // The registry pads what it keeps; the names are trimmed.
    i.chip = std.mem.trim(u8, reg(L("HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0"), L("ProcessorNameString"), &t.chip), " \t");
    i.model = std.mem.trim(u8, reg(L("HARDWARE\\DESCRIPTION\\System\\BIOS"), L("SystemProductName"), &t.model), " \t");
    i.gpu = reg(L("SYSTEM\\CurrentControlSet\\Control\\Class\\{4D36E968-E325-11CE-BFC1-08002BE10318}\\0000"), L("DriverDesc"), &t.gpu);
    const version_key = L("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion");
    var product_buf: [96]u8 = undefined;
    var version_buf: [48]u8 = undefined;
    var build_buf: [16]u8 = undefined;
    const product = reg(version_key, L("ProductName"), &product_buf);
    const version = reg(version_key, L("DisplayVersion"), &version_buf);
    const build = reg(version_key, L("CurrentBuildNumber"), &build_buf);
    const build_no = std.fmt.parseInt(u32, build, 10) catch 0;
    // Windows 11 still calls itself Windows 10 there.
    const name = if (build_no >= 22000 and std.mem.startsWith(u8, product, "Windows 10")) "Windows 11" else product;
    i.os = if (name.len > 0)
        std.fmt.bufPrint(&t.os, "{s} {s} · build {s}", .{ name, version, build }) catch name
    else
        "Windows";
    var host: [64]WCHAR = undefined;
    var host_len: DWORD = host.len;
    if (GetComputerNameW(&host, &host_len) != 0) {
        const n = std.unicode.utf16LeToUtf8(&t.host, host[0..@min(host_len, host.len)]) catch 0;
        i.host = t.host[0..n];
    }
    i.fast = s.cores;
    i.fast_name = "Cores";
}

pub fn deinit(s: *Sampler) void {
    const p = &s.state.pdh;
    if (p.query) |q| _ = PdhCloseQuery(q);
    if (p.buf.len > 0) s.gpa.free(p.buf);
}

/// How the machine is doing: each sample.
pub fn extras(s: *Sampler, _: *Text) void {
    const sy = &s.system;
    const st = &s.state;
    const now = GetTickCount64();
    sy.uptime_s = now / 1000;
    const dt: f32 = if (st.last_ms == 0) 0 else @floatFromInt(now - st.last_ms);
    st.last_ms = now;
    // Windows has no load average; this is the same figure by another name:
    // the average number of cores busy, over a minute, five and fifteen. The
    // ticks are this sample's and the last one's (sample.zig turns them into
    // percentages after this returns).
    var busy: f32 = 0;
    for (0..@min(s.cores, sample.max_cores)) |i| {
        const now_t = s.core_ticks[i];
        const was = s.prev_core_ticks[i];
        const b = (now_t.user + now_t.system) -| (was.user + was.system);
        const all = b + (now_t.idle -| was.idle);
        if (all > 0) busy += @as(f32, @floatFromInt(b)) / @as(f32, @floatFromInt(all));
    }
    if (st.have_load and dt > 0 and dt < 60_000) {
        const secs = dt / 1000;
        for ([_]f32{ 60, 300, 900 }, 0..) |tau, k| {
            sy.load[k] += (busy - sy.load[k]) * (1 - @exp(-secs / tau));
        }
    } else {
        sy.load = .{ busy, busy, busy };
        st.have_load = true;
    }
    network(s);
    counters(s);
}

/// Bytes in and out of every hardware interface, since boot.
fn network(s: *Sampler) void {
    var table: ?*anyopaque = null;
    if (GetIfTable2(&table) != 0) return;
    defer FreeMibTable(table);
    // The table is the API's own allocation, aligned for what it holds, but
    // read unaligned rather than trust it.
    const raw: *align(1) const IfTable = @ptrCast(table.?);
    const rows: [*]align(1) const IfRow = @ptrCast(&raw.Table);
    var in: u64 = 0;
    var out: u64 = 0;
    for (rows[0..@min(raw.NumEntries, 1024)]) |r| {
        // Every filter miniport stacked over a card (WFP, QoS, a vendor's)
        // is an interface of its own, carrying that card's counters: only
        // the hardware interfaces are counted, or the same bytes come many
        // times over.
        if (r.InterfaceAndOperStatusFlags & 1 == 0) continue;
        if (r.Type == if_type_software_loopback) continue;
        in +%= r.InOctets;
        out +%= r.OutOctets;
    }
    s.system.net_in = in;
    s.system.net_out = out;
}

// Performance counters: the GPU, and how hot the machine runs

/// One counter's readings across its instances.
const Readings = struct {
    max: f64 = 0,
    sum: f64 = 0,
    max3d: f64 = 0,
    n: usize = 0,
    any: bool = false,
};

fn open(s: *Sampler) ?HANDLE {
    const p = &s.state.pdh;
    if (p.opened) return p.query;
    p.opened = true;
    var query: HANDLE = undefined;
    if (PdhOpenQueryW(null, 0, &query) != 0) return null;
    p.query = query;
    var c: HANDLE = undefined;
    if (PdhAddEnglishCounterW(query, L("\\GPU Engine(*)\\Utilization Percentage"), 0, &c) == 0) p.engine = c;
    if (PdhAddEnglishCounterW(query, L("\\GPU Adapter Memory(*)\\Dedicated Usage"), 0, &c) == 0) p.memory = c;
    if (PdhAddEnglishCounterW(query, L("\\Thermal Zone Information(*)\\Temperature"), 0, &c) == 0) p.thermal = c;
    if (PdhAddEnglishCounterW(query, L("\\Memory\\Pages Input/sec"), 0, &c) == 0) p.pages_in = c;
    if (PdhAddEnglishCounterW(query, L("\\Memory\\Pages Output/sec"), 0, &c) == 0) p.pages_out = c;
    return query;
}

/// Every instance of `counter`, read as a double.
fn read(s: *Sampler, counter: HANDLE) Readings {
    var out: Readings = .{};
    const p = &s.state.pdh;
    var size: DWORD = 0;
    var count: DWORD = 0;
    const asked = PdhGetFormattedCounterArrayW(counter, pdh_double, &size, &count, null);
    if (asked != pdh_more_data or size == 0 or count == 0) return out;
    if (p.buf.len < size) p.buf = s.gpa.realloc(p.buf, size) catch return out;
    size = @intCast(p.buf.len);
    if (PdhGetFormattedCounterArrayW(counter, pdh_double, &size, &count, @ptrCast(p.buf.ptr)) != 0) return out;
    var i: usize = 0;
    while (i < @min(count, p.buf.len / @sizeOf(Item))) : (i += 1) {
        // Items are laid end to end, as the API wrote them.
        const item: *align(1) const Item = @ptrCast(p.buf.ptr + i * @sizeOf(Item));
        // PDH_CSTATUS_VALID_DATA, or PDH_CSTATUS_NEW_DATA.
        if (item.CStatus != 0 and item.CStatus != 1) continue;
        const v = item.doubleValue;
        if (!std.math.isFinite(v)) continue;
        out.any = true;
        out.n += 1;
        out.sum += v;
        out.max = @max(out.max, v);
        const name = item.szName orelse continue;
        if (contains(std.mem.sliceTo(name, 0), three_d[0..three_d.len])) out.max3d = @max(out.max3d, v);
    }
    return out;
}

fn contains(hay: []const WCHAR, needle: []const WCHAR) bool {
    if (needle.len > hay.len) return false;
    for (0..hay.len - needle.len + 1) |i| {
        if (std.mem.eql(WCHAR, hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// The GPU's use and the memory it holds: the busiest engine, and the 3D
/// ones apart, as Task Manager reads them.
fn gpu(s: *Sampler) void {
    const p = &s.state.pdh;
    const sy = &s.system;
    if (p.engine) |c| {
        const r = read(s, c);
        if (r.any) {
            sy.gpu = @floatCast(std.math.clamp(r.max, 0, 100));
            sy.gpu_renderer = @floatCast(std.math.clamp(r.max3d, 0, 100));
            sy.gpu_tiler = 0;
        }
    }
    if (p.memory) |c| {
        const r = read(s, c);
        if (r.any) sy.gpu_memory = @intFromFloat(@min(r.sum, 1e13));
    }
}

/// The thermal zones' temperatures, in tenths of a kelvin; the machine's
/// state follows the hottest.
fn thermal(s: *Sampler) void {
    const p = &s.state.pdh;
    const sy = &s.system;
    const c = p.thermal orelse return;
    const r = read(s, c);
    if (!r.any or r.n == 0 or r.max <= 0) return;
    const hottest: f32 = @floatCast(r.max / 10 - 273.15);
    const mean: f32 = @floatCast(r.sum / @as(f64, @floatFromInt(r.n)) / 10 - 273.15);
    if (hottest <= 0) return;
    sy.cpu_temp = std.math.clamp(mean, 0, 200);
    sy.cpu_temp_max = std.math.clamp(hottest, 0, 200);
    sy.thermal = if (hottest >= 95) 3 else if (hottest >= 85) 2 else if (hottest >= 70) 1 else 0;
}

/// One collect, then what the counters say.
fn counters(s: *Sampler) void {
    const p = &s.state.pdh;
    const query = open(s) orelse return;
    _ = PdhCollectQueryData(query);
    gpu(s);
    thermal(s);
    // The counters count pages; the page shows bytes, as Activity Monitor's.
    const bytes_per_page: f32 = @floatFromInt(s.state.page_size);
    if (p.pages_in) |c| {
        const r = read(s, c);
        if (r.any) {
            const pages: f32 = @floatCast(@max(0, r.max));
            s.system.page_ins_sec = pages * bytes_per_page;
        }
    }
    if (p.pages_out) |c| {
        const r = read(s, c);
        if (r.any) {
            const pages: f32 = @floatCast(@max(0, r.max));
            s.system.page_outs_sec = pages * bytes_per_page;
        }
    }
}

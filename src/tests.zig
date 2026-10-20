//! nanomon's tests: the model, ps's answers, the table's order, the window
//! through the Tester (tabs, sorting, the View menu, the inspector, the
//! quit sheet, the keyboard), and real samples on the systems that have
//! them. Pictures of each tab go to the temporary directory.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const view = @import("view.zig");
const theme = @import("theme.zig");
const sample = @import("sample.zig");

test {
    _ = @import("model.zig");
    _ = @import("sample.zig");
    _ = @import("app.zig");
    if (builtin.os.tag == .macos) _ = @import("ps.zig");
    if (builtin.os.tag == .macos) _ = @import("sample_temp_mac.zig");
    _ = @import("graff.zig");
    _ = @import("tests_select.zig");
    _ = @import("tests_menubar.zig");
}

extern "c" fn getpid() c_int;

/// Pids no process has (beyond the kernel's limit), so nothing is ever
/// sent to a real one.
pub fn fake(a: *App) !void {
    a.live = false;
    a.dark = false;
    a.uid = 501;
    const s = &a.sampler;
    s.system = .{ .cores = 10, .cpu_user = 54, .cpu_system = 21, .mem_total = 16 << 30, .mem_app = 6 << 30, .mem_wired = 2 << 30, .mem_compressed = 1 << 30, .mem_cached = 4 << 30, .swap_used = 512 << 20, .pressure = 34, .reads = 1234567, .writes = 765432, .read_bytes = 300 << 30, .written_bytes = 500 << 30, .read_sec = 4 << 20, .written_sec = 1 << 20, .net_in = 90 << 30, .net_out = 20 << 30, .net_in_sec = 300 << 10, .net_out_sec = 40 << 10, .gpu = 59, .gpu_renderer = 52, .gpu_tiler = 18, .gpu_memory = 2 << 30, .load = .{ 12.5, 9.1, 6.0 }, .uptime_s = 27 * 86400 + 20 * 3600, .tasks = 4, .threads = 12288 };
    s.info = .{ .chip = "Apple M5", .model = "Mac17,1", .os = "macOS 27.0", .host = "Studio", .gpu = "Apple M5", .gpu_cores = 10, .fast = 4, .frugal = 6, .fast_name = "Super", .frugal_name = "Efficiency" };
    s.cores = 10;
    for (0..10) |i| s.core_load[i] = @floatFromInt((i * 37) % 100);
    for (0..300) |i| {
        const f: f32 = @floatFromInt(i);
        const v = 40 + 30 * @sin(f / 9);
        s.user_history.push(v * 0.6);
        s.system_history.push(v * 0.4);
        s.app_history.push(37 + 3 * @sin(f / 20));
        s.wired_history.push(12);
        s.compressed_history.push(6 + @sin(f / 7));
        s.pressure_history.push(34);
        s.gpu_history.push(50 + 40 * @sin(f / 13));
        s.read_history.push((2 + @sin(f / 5)) * (1 << 20));
        s.write_history.push((1 + @cos(f / 6)) * (1 << 20));
        s.in_history.push((200 + 100 * @sin(f / 4)) * 1024);
        s.out_history.push(40 * 1024);
    }
    try s.procs.appendSlice(s.gpa, &.{
        .{ .pid = 990001, .ppid = 1, .uid = 0, .name = "kernel_task", .user = "root", .cpu = 4.2, .cpu_time_ns = 3_600_000_000_000, .memory = 3 << 30, .known = true, .from_ps = true },
        .{ .pid = 990002, .ppid = 1, .uid = 501, .name = "Safari", .user = "me", .bundle = "/Applications/Safari.app", .cpu = 38.5, .cpu_time_ns = 90_000_000_000, .memory = 900 << 20, .known = true, .threads = 31, .wakeups = 120, .disk_read = 80 << 20, .disk_written = 12 << 20 },
        .{ .pid = 990005, .ppid = 990002, .uid = 501, .name = "Safari Web Content", .user = "me", .bundle = "/Applications/Safari.app/Contents/XPCServices/WebContent.app", .cpu = 11.5, .memory = 600 << 20, .known = true, .threads = 12 },
        .{ .pid = 990003, .ppid = 990002, .uid = 501, .name = "Mail", .user = "me", .bundle = "/Applications/Mail.app", .cpu = 1.1, .cpu_time_ns = 5_000_000_000, .memory = 200 << 20, .known = true, .threads = 9, .wakeups = 4, .disk_read = 3 << 20, .disk_written = 40 << 20 },
        .{ .pid = 990004, .ppid = 1, .uid = 0, .name = "secretd", .user = "root" },
    });
}

pub fn below(t: *ui.Tester, upper: []const u8, lower: []const u8) bool {
    const u = t.findText(upper) orelse return false;
    const l = t.findText(lower) orelse return false;
    return u.y < l.y;
}

pub fn open(t: *ui.Tester, name: []const u8) !void {
    try t.clickText(name);
    t.settle(1);
}

test "the pages: overview, CPU, memory, GPU, disk, network, apps, this Mac" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try fake(&a);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(2);
    try std.testing.expect(t.hasText("Overview") and t.hasText("Busiest Now") and t.hasText("This Mac"));
    try t.screenshot("/tmp/nanomon-overview.png");
    try open(&t, "CPU");
    try std.testing.expect(t.hasText("Processor Load") and t.hasText("Super Cores") and t.hasText("Efficiency Cores"));
    try std.testing.expect(t.hasText("12.50 · Saturated") and t.hasText("12,288") and t.hasText("27d 20h"));
    try t.screenshot("/tmp/nanomon-cpu.png");
    // The graph reads out the column under the pointer.
    const now = t.findText("Now").?;
    t.moveTo(now.x + 400, now.y + 140);
    t.settle(1);
    try std.testing.expect(a.hovers.get(.cpu) != null);
    try std.testing.expect(t.containsText("s   System ") and t.containsText(" · User "));
    try t.screenshot("/tmp/nanomon-cpu-hover.png");
    // Another range: the averages and marks follow.
    try open(&t, "5m");
    try std.testing.expect(a.range == .m5 and t.hasText("over 5m") and t.hasText("−4m"));
    try open(&t, "Memory");
    try std.testing.expect(t.hasText("Memory Usage") and t.hasText("Largest Processes") and t.hasText("Normal"));
    try t.screenshot("/tmp/nanomon-memory.png");
    try open(&t, "GPU");
    try std.testing.expect(t.hasText("GPU Load") and t.hasText("Renderer"));
    try open(&t, "Disk");
    try std.testing.expect(t.hasText("Disk Activity") and t.hasText("Most Written"));
    try std.testing.expect(below(&t, "Mail", "Safari"));
    try t.screenshot("/tmp/nanomon-disk.png");
    try open(&t, "Network");
    try std.testing.expect(t.hasText("Network Activity") and t.hasText("90.00 GB"));
    // Apps: Safari and its web content together.
    try open(&t, "Apps");
    try std.testing.expect(t.hasText("2 apps · 3 processes"));
    try std.testing.expect(below(&t, "Safari", "Mail"));
    try t.screenshot("/tmp/nanomon-apps.png");
    try open(&t, "About This Mac");
    try std.testing.expect(t.hasText("10 (4 Super, 6 Efficiency)") and t.hasText("Apple M5, 10 cores"));
    try t.screenshot("/tmp/nanomon-about.png");
    // Pausing holds the graphs still.
    try open(&t, "CPU");
    const pause = t.findText("1h").?;
    t.click(pause.x + pause.w + 26, pause.y + pause.h / 2);
    t.settle(1);
    try std.testing.expect(a.paused and t.hasText("Paused"));
}

test "the processes page: sorting, the filter, the inspector and the quit sheet" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try fake(&a);
    a.dark = true;
    a.page = .processes;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(true) });
    defer t.deinit();
    t.settle(2);
    // Busiest first; what nobody could read, last.
    try std.testing.expect(below(&t, "Safari", "Mail"));
    try std.testing.expect(below(&t, "kernel_task", "secretd"));
    try t.screenshot("/tmp/nanomon-processes.png");
    try open(&t, "Process Name");
    try std.testing.expect(below(&t, "Mail", "Safari"));
    // The filter: only the user's processes.
    try open(&t, "All Processes");
    try open(&t, "My Processes");
    try std.testing.expect(!t.hasText("kernel_task") and t.hasText("Safari"));
    try open(&t, "My Processes");
    try open(&t, "All Processes");
    // A double click inspects; the inspector names the parent.
    const mail = t.findText("Mail").?;
    t.doubleClick(mail.x + 4, mail.y + mail.h / 2);
    t.settle(1);
    try std.testing.expectEqual(@as(?i32, 990003), a.inspect);
    try std.testing.expect(t.hasText("Safari (990002)"));
    // Quit… asks first; Cancel leaves it be.
    try open(&t, "Quit…");
    try std.testing.expect(t.hasText("Are you sure you want to quit this process?"));
    try t.screenshot("/tmp/nanomon-quit.png");
    try open(&t, "Cancel");
    try std.testing.expect(a.confirm == null);
    a.inspect = null;
    a.query.set("mai");
    a.dirty = true;
    t.settle(1);
    try std.testing.expectEqual(@as(usize, 1), a.rows.items.len);
}

test "the keyboard: pages, the selection, Escape" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try fake(&a);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(1);
    t.ctx.input.shortcut = .{ .key = '2', .cmd = true };
    t.frame();
    try std.testing.expectEqual(app_mod.Page.processes, a.page);
    t.ctx.input.shortcut = .{ .key = ui.Shortcut.down };
    t.frame();
    try std.testing.expectEqual(@as(?i32, 990002), a.selected);
    t.ctx.input.shortcut = .{ .key = 'i', .cmd = true };
    t.frame();
    try std.testing.expectEqual(@as(?i32, 990002), a.inspect);
    t.ctx.input.shortcut = .{ .key = ui.Shortcut.escape };
    t.frame();
    try std.testing.expect(a.inspect == null);
    t.ctx.input.shortcut = .{ .key = ui.Shortcut.escape };
    t.frame();
    try std.testing.expect(a.selected == null);
}

test "a real sample finds this process, its CPU time and memory" {
    if (!@hasDecl(sample.os, "collect") or (builtin.os.tag != .macos and builtin.os.tag != .linux)) return error.SkipZigTest;
    var a: App = .init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    _ = a.tick(0);
    // Some work between the samples.
    var x: u64 = 0;
    for (0..20_000_000) |i| x +%= i *% i;
    std.mem.doNotOptimizeAway(x);
    _ = a.tick(2.0);
    const me = a.find(getpid()) orelse return error.NotFound;
    try std.testing.expect(me.known and me.detailed());
    try std.testing.expect(me.memory > 0);
    try std.testing.expect(me.cpu_time_ns > 0);
    try std.testing.expect(me.threads >= 1);
    try std.testing.expect(a.sampler.procs.items.len >= 2);
    try std.testing.expect(a.sampler.system.mem_total > 0);
    try std.testing.expect(a.sampler.system.cores >= 1);
}

test "real samples: ps fills in the system's processes, and the window shows them" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    a.listen(null);
    _ = a.tick(0);
    // ps answers while the loop runs; the next sample comes soon after.
    var waited: f64 = 0;
    while (!a.fresh and waited < 5) : (waited += 0.05) nanoui.runFor(0.05);
    try std.testing.expect(a.fresh);
    nanoui.runFor(0.6);
    _ = a.tick(0.6 + waited);
    // launchd is root's: only ps could say.
    const launchd = a.find(1) orelse return error.NotFound;
    try std.testing.expect(launchd.known and launchd.from_ps and launchd.memory > 0);
    // The disks have been read since boot.
    try std.testing.expect(a.sampler.system.read_bytes > 0);
    a.live = false;
    for ([_]bool{ false, true }, [_]app_mod.Page{ .overview, .cpu }) |dark, pg| {
        a.dark = dark;
        a.page = pg;
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(dark) });
        defer t.deinit();
        // Icons come a few a frame.
        t.settle(2);
        t.advance(0.5);
        try t.screenshot(if (dark) "/tmp/nanomon-real-cpu-dark.png" else "/tmp/nanomon-real-overview.png");
    }
}

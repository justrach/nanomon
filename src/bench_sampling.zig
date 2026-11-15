//! Opt-in live sampler timing, independently of rendering. Reads native monitor
//! counters only; never emits identities, opens windows or controls processes.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const trace = @import("bench_trace.zig");
const app = @import("app.zig");

pub fn run(init: std.process.Init, asynchronous: bool) !void {
    var a: app.App = .init(init.gpa, init.io);
    defer a.deinit();
    a.listen(null);
    a.sampler.async_temperature = asynchronous;
    var phases: @import("sample_profile.zig").Timings = .{};
    a.sampler.collection_timings = &phases;
    for (0..10) |i| {
        const filtered = true;
        a.sampler.state.sensors.filter_events = filtered;
        // Permit the existing asynchronous ps reader to deliver its answer.
        // No GUI app/window is created. No synchronous ps fallback is enabled.
        nanoui.runFor(0.01);
        const now = ui.clock.now();
        const usage_before = trace.Usage.read();
        const begin = ui.clock.now();
        a.sampler.sample(now);
        const collected = ui.clock.now();
        if (a.fresh) {
            a.fresh = false;
            a.sampler.refill(now);
        }
        a.order();
        const end = ui.clock.now();
        const usage = trace.Usage.delta(trace.Usage.read(), usage_before);
        const sensors = if (asynchronous)
            (if (a.sampler.state.sensor_worker.latest) |snapshot| snapshot.stats else @import("sample_temp_mac.zig").Stats{})
        else
            a.sampler.state.sensors.last_read;
        const sy = a.sampler.system;
        const age_ms = if (sy.temperature_sampled_at) |at|
            @max(0, @as(f64, @floatFromInt(std.Io.Clock.awake.now(init.io).nanoseconds)) / 1e9 - at) * 1000
        else
            -1;
        const sensor_ms = if (asynchronous)
            (if (a.sampler.state.sensor_worker.latest) |snapshot| snapshot.collection_ms else 0)
        else
            phases.temperature;
        std.debug.print("{{\"kind\":\"native_sample\",\"sample\":{d},\"cold\":{},\"processes\":{d},\"sample_ms\":{d:.4},\"order_refill_ms\":{d:.4},\"wall_ms\":{d:.4},\"process_cpu_ms\":{d:.4},\"minor_faults\":{d},\"major_faults\":{d},\"processes_ms\":{d:.4},\"system_ms\":{d:.4},\"machine_ms\":{d:.4},\"extras_ms\":{d:.4},\"temperature_ms\":{d:.4},\"ticks_ms\":{d:.4},\"filtered\":{},\"async_temperature\":{},\"notification\":\"{s}\",\"sensor_services\":{d},\"sensor_events\":{d},\"temperature_available\":{},\"temperature_pending\":{},\"temperature_snapshot_age_ms\":{d:.4},\"sensor_read_ms\":{d:.4}}}\n", .{
            i,                                                     i == 0,                                             a.sampler.procs.items.len, (collected - begin) * 1000,
            (end - collected) * 1000,                              (end - begin) * 1000,                               usage.cpu_ms,              usage.minor_faults,
            usage.major_faults,                                    phases.processes,                                   phases.system,             phases.machine,
            phases.extras,                                         phases.temperature,                                 phases.ticks,              filtered,
            asynchronous,                                          if (asynchronous) "dispatch_id" else "synchronous", sensors.services,          sensors.events,
            sy.cpu_temp > 0 or sy.gpu_temp > 0 or sy.soc_temp > 0, sy.temperature_pending,                             age_ms,                    sensor_ms,
        });
        // Handle completion events between samples, as the GUI does. No polls.
        if (i != 9) nanoui.runFor(2);
    }
}

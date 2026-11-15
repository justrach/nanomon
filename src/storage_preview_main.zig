//! Standalone native feature previews; synthetic data, no real scanning.
const std = @import("std");
const App = @import("app.zig").App;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedOutputDirectory;
    var a: App = .init(init.gpa, init.io);
    defer a.deinit();
    try @import("video_data.zig").fill(&a);
    a.sampler.async_temperature = false;
    a.sampler.samples = 400;
    a.sampler.system.available = .{ .cpu = true, .memory = true, .disk = true, .network = true, .gpu = true };
    a.sampler.system.rate_available = a.sampler.system.available;
    a.sampler.system.cpu_temp = 54;
    a.sampler.system.cpu_temp_max = 61;
    a.sampler.system.gpu_temp = 49;
    for (a.sampler.procs.items) |*p| {
        p.cpu_known = true;
        p.bundle = "";
    }
    a.order();
    try @import("storage_preview.zig").run(&a, init, args[1]);
}

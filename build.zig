const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    // Portable self-replacement is for explicitly packaged release builds,
    // never a developer's zig-out binary or a test build.
    const update_version = b.option([]const u8, "update-version", "Enable portable updates for this release version") orelse "";
    if (update_version.len > 0 and !std.mem.eql(u8, update_version, @import("build.zig.zon").version))
        @panic("update-version must match build.zig.zon's version");
    options.addOption([]const u8, "update_version", update_version);
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    mod.addOptions("nanomon_options", options);
    // The disks' counters come from IOKit.
    const mac = target.result.os.tag == .macos;
    if (mac) mod.linkFramework("IOKit", .{});
    const exe = b.addExecutable(.{ .name = "nanomon", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run nanomon").dependOn(&run.step);

    // A real updater verification against temporary signed bundle copies.
    // It has no windows and never relaunches an app.
    const update_check = b.addExecutable(.{ .name = "nanomon-update-check", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/check-update.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    b.step("update-check-bin", "Build the headless update verifier").dependOn(&b.addInstallArtifact(update_check, .{}).step);

    // A video of nanoui, rendered offscreen (src/video.zig).
    const video = b.addExecutable(.{ .name = "nanomon-video", .root_module = b.createModule(.{
        .root_source_file = b.path("src/video.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    if (mac) video.root_module.linkFramework("IOKit", .{});
    b.step("video", "Build zig-out/bin/nanomon-video").dependOn(&b.addInstallArtifact(video, .{}).step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    tests.root_module.addOptions("nanomon_options", options);
    if (mac) tests.root_module.linkFramework("IOKit", .{});
    b.step("test", "Run nanomon tests").dependOn(&b.addRunArtifact(tests).step);
    // The tests as a program, for another machine (Linux in a container).
    b.step("test-bin", "Install the tests as zig-out/bin/nanomon-tests").dependOn(&b.addInstallArtifact(tests, .{ .dest_sub_path = "nanomon-tests" }).step);
}

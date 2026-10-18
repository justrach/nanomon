const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    // The disks' counters come from IOKit.
    const mac = target.result.os.tag == .macos;
    if (mac) mod.linkFramework("IOKit", .{});
    const exe = b.addExecutable(.{ .name = "nanomon", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run nanomon").dependOn(&run.step);

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
    if (mac) tests.root_module.linkFramework("IOKit", .{});
    b.step("test", "Run nanomon tests").dependOn(&b.addRunArtifact(tests).step);
    // The tests as a program, for another machine (Linux in a container).
    b.step("test-bin", "Install the tests as zig-out/bin/nanomon-tests").dependOn(&b.addInstallArtifact(tests, .{ .dest_sub_path = "nanomon-tests" }).step);
}

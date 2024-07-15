const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    _ = b.addModule("dtb", .{
        .root_source_file = b.path("src/dtb.zig"),
        .optimize = optimize,
        .target = target,
    });

    const test_step = b.step("test", "Run the tests");

    test_step.dependOn(&b.addTest(.{
        .root_source_file = b.path("src/dtb.zig"),
    }).step);
}

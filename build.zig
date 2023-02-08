const std = @import("std");

pub fn build(b: *std.Build) void {
    b.addModule(.{
        .name = "dtb",
        .source_file = .{ .path = "src/dtb.zig" },
    });

    const test_step = b.step("test", "Run the tests");

    test_step.dependOn(&b.addTest(.{
        .root_source_file = .{ .path = "src/dtb.zig" },
    }).step);
}

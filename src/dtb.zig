const std = @import("std");
const testing = std.testing;
const parser = @import("parser.zig");

pub const Node = struct {
    name: []const u8,
    props: []Prop,
    children: []Node,

    pub fn propAt(start: Node, path: []const []const u8, comptime prop_tag: std.meta.Tag(Prop)) ?std.meta.TagPayload(Prop, prop_tag) {
        var node: Node = start;
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            node = node.child(path[i]) orelse return null;
        }
        return node.prop(prop_tag);
    }

    pub fn child(node: Node, child_name: []const u8) ?Node {
        for (node.children) |c| {
            if (std.mem.eql(u8, child_name, c.name)) {
                return c;
            }
        }
        return null;
    }

    pub fn prop(node: Node, comptime prop_tag: std.meta.Tag(Prop)) ?std.meta.TagPayload(Prop, prop_tag) {
        for (node.props) |p| {
            if (p == prop_tag) {
                return @field(p, @tagName(prop_tag));
            }
        }
        return null;
    }

    pub fn deinit(node: Node, allocator: *std.mem.Allocator) void {
        for (node.props) |p| {
            p.deinit(allocator);
        }
        allocator.free(node.props);
        for (node.children) |c| {
            c.deinit(allocator);
        }
        allocator.free(node.children);
    }

    pub fn format(node: Node, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try node.formatNode(writer, 0);
    }

    fn formatNode(node: Node, writer: anytype, depth: usize) std.os.WriteError!void {
        try indent(writer, depth);
        try std.fmt.format(writer, "Node <{s}> ({} props, {} children)\n", .{ node.name, node.props.len, node.children.len });
        for (node.props) |prop| {
            try indent(writer, depth);
            try std.fmt.format(writer, " {}\n", .{prop});
        }
        for (node.children) |child| {
            try child.formatNode(writer, depth + 1);
        }
    }

    fn indent(writer: anytype, depth: usize) !void {
        var i: usize = 0;
        while (i < depth) : (i += 1) {
            try writer.writeAll("  ");
        }
    }
};

pub const PropStatus = enum {
    Okay,
    Disabled,
    Fail,

    pub fn format(status: PropStatus, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        switch (status) {
            .Okay => try writer.writeAll("okay"),
            .Disabled => try writer.writeAll("disabled"),
            .Fail => try writer.writeAll("fail"),
        }
    }
};

pub const Prop = union(enum) {
    AddressCells: u32,
    SizeCells: u32,
    RegShift: u32,
    PHandle: u32,
    Reg: [][2]u64,
    Compatible: [][]const u8,
    Status: PropStatus,
    Unknown: PropUnknown,

    pub fn format(prop: Prop, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        switch (prop) {
            .AddressCells => |v| try std.fmt.format(writer, "#address-cells: 0x{x:0>8}", .{v}),
            .SizeCells => |v| try std.fmt.format(writer, "#size-cells: 0x{x:0>8}", .{v}),
            .RegShift => |v| try std.fmt.format(writer, "reg-shift: 0x{x:0>2}", .{v}),
            .Reg => |v| {
                try writer.writeAll("reg: <");
                for (v) |pair, i| {
                    if (i != 0) {
                        try writer.writeByte(' ');
                    }
                    try std.fmt.format(writer, "0x{x} 0x{x}", .{ pair[0], pair[1] });
                }
                try writer.writeByte('>');
            },
            .Compatible => |v| {
                // Same format as dtc -O dts.
                try writer.writeAll("\"");
                for (v) |s, i| {
                    if (i != 0) {
                        try writer.writeAll("\\0");
                    }
                    try writer.writeAll(s);
                }
                try writer.writeAll("\"");
            },
            .Status => |v| try std.fmt.format(writer, "status: \"{s}\"", .{v}),
            .Unknown => |v| try std.fmt.format(writer, "{s}: {}", .{ v.name, v.value }),
        }
    }

    pub fn deinit(prop: Prop, allocator: *std.mem.Allocator) void {
        switch (prop) {
            .Reg => |v| allocator.free(v),
            .Compatible => |v| allocator.free(v),
            else => {},
        }
    }
};

pub const PropUnknown = struct {
    name: []const u8,
    value: []const u8,
};

pub const parse = parser.parse;
pub const Error = parser.Error;

const qemu_dtb = @embedFile("../qemu.dtb");
const rockpro64_dtb = @embedFile("../rk3399-rockpro64.dtb");

test "parse" {
    var qemu = try parse(std.testing.allocator, qemu_dtb);
    defer qemu.deinit(std.testing.allocator);

    // This QEMU DTB places 512MiB of memory at 1GiB.
    testing.expectEqualSlices(
        [2]u64,
        &[_][2]u64{.{ 1024 * 1024 * 1024, 512 * 1024 * 1024 }},
        qemu.propAt(&.{"memory@40000000"}, .Reg).?,
    );

    // It has an A53-compatible CPU.
    const compatible = qemu.propAt(&.{ "cpus", "cpu@0" }, .Compatible).?;
    testing.expectEqual(@as(usize, 1), compatible.len);
    testing.expectEqualStrings("arm,cortex-a53", compatible[0]);

    var rockpro64 = try parse(std.testing.allocator, rockpro64_dtb);
    defer rockpro64.deinit(std.testing.allocator);
}

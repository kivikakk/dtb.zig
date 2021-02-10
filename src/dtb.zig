const std = @import("std");
const testing = std.testing;
const parser = @import("parser.zig");

pub const Node = struct {
    name: []const u8,
    props: []Prop,
    children: []Node,

    pub fn deinit(node: Node, allocator: *std.mem.Allocator) void {
        for (node.props) |prop| {
            prop.deinit(allocator);
        }
        allocator.free(node.props);
        for (node.children) |child| {
            child.deinit(allocator);
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

pub const Prop = union(enum) {
    AddressCells: u32,
    SizeCells: u32,
    Reg: [][2]u64,
    Unknown: PropUnknown,

    pub fn format(prop: Prop, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        switch (prop) {
            .AddressCells => |v| try std.fmt.format(writer, "#address-cells: 0x{x:0>8}", .{v}),
            .SizeCells => |v| try std.fmt.format(writer, "#size-cells: 0x{x:0>8}", .{v}),
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
            .Unknown => |v| try std.fmt.format(writer, "{s}: {}", .{ v.name, v.value }),
        }
    }

    pub fn deinit(prop: Prop, allocator: *std.mem.Allocator) void {
        switch (prop) {
            .Reg => |v| allocator.free(v),
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
    var dtb = try parse(std.testing.allocator, qemu_dtb);
    std.debug.print("====\nqemu\n====\n{}\n\n", .{dtb});
    dtb.deinit(std.testing.allocator);

    dtb = try parse(std.testing.allocator, rockpro64_dtb);
    std.debug.print("=========\nrockpro64\n=========\n{}\n\n", .{dtb});
    dtb.deinit(std.testing.allocator);
    // QEMU places memory at 1GiB.
    // testing.expectEqual(@as(u64, 0x40000000), try parseAndGetMemoryOffset(qemu_dtb));
    // Rockpro64 at ?
    // testing.expectEqual(@as(u64, 123), try parseAndGetMemoryOffset(rockpro64_dtb));
}

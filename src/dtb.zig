const std = @import("std");
const testing = std.testing;
const parser = @import("parser.zig");

pub const Node = struct {
    name: []const u8,
    props: []Prop,
    root: *Node,
    parent: ?*Node,
    children: []*Node,

    pub fn propAt(start: *const Node, path: []const []const u8, comptime prop_tag: std.meta.Tag(Prop)) ?std.meta.TagPayload(Prop, prop_tag) {
        var node: *const Node = start;
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            node = node.child(path[i]) orelse return null;
        }
        return node.prop(prop_tag);
    }

    pub fn child(node: *const Node, child_name: []const u8) ?*Node {
        for (node.children) |c| {
            if (std.mem.eql(u8, child_name, c.name)) {
                return c;
            }
        }
        return null;
    }

    pub fn prop(node: *const Node, comptime prop_tag: std.meta.Tag(Prop)) ?std.meta.TagPayload(Prop, prop_tag) {
        for (node.props) |p| {
            if (p == prop_tag) {
                return @field(p, @tagName(prop_tag));
            }
        }
        return null;
    }

    pub fn interruptCells(node: *Node) ?u32 {
        if (node.prop(.InterruptCells)) |ic| {
            return ic;
        }
        if (node.interruptParent()) |ip| {
            return ip.interruptCells();
        }
        return null;
    }

    pub fn interruptParent(node: *Node) ?*Node {
        if (node.prop(.InterruptParent)) |ip| {
            return node.root.findPHandle(ip);
        }
        return node.parent;
    }

    pub fn findPHandle(node: *Node, phandle: u32) ?*Node {
        if (node.prop(.PHandle)) |v| {
            if (v == phandle) {
                return node;
            }
        }
        for (node.children) |c| {
            if (c.findPHandle(phandle)) |n| {
                return n;
            }
        }
        return null;
    }

    pub fn deinit(node: *Node, allocator: *std.mem.Allocator) void {
        for (node.props) |p| {
            p.deinit(allocator);
        }
        allocator.free(node.props);
        for (node.children) |c| {
            c.deinit(allocator);
        }
        allocator.free(node.children);
        allocator.destroy(node);
    }

    pub fn format(node: Node, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try node.formatNode(writer, 0);
    }

    fn formatNode(node: Node, writer: anytype, depth: usize) std.os.WriteError!void {
        try indent(writer, depth);
        try std.fmt.format(writer, "Node <{s}>\n", .{std.zig.fmtEscapes(node.name)});
        for (node.props) |p| {
            try indent(writer, depth + 1);
            try std.fmt.format(writer, "{}\n", .{p});
        }
        for (node.children) |c| {
            try c.formatNode(writer, depth + 1);
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
    InterruptCells: u32,
    ClockCells: u32,
    RegShift: u32,
    PHandle: u32,
    InterruptParent: u32,
    Reg: [][2]u64,
    Compatible: [][]const u8,
    Status: PropStatus,
    Interrupts: [][]u32,
    Unresolved: PropUnresolved,
    Unknown: PropUnknown,

    pub fn format(prop: Prop, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        switch (prop) {
            .AddressCells => |v| try std.fmt.format(writer, "#address-cells: 0x{x:0>2}", .{v}),
            .SizeCells => |v| try std.fmt.format(writer, "#size-cells: 0x{x:0>2}", .{v}),
            .InterruptCells => |v| try std.fmt.format(writer, "#interrupt-cells: 0x{x:0>2}", .{v}),
            .ClockCells => |v| try std.fmt.format(writer, "#clock-cells: 0x{x:0>2}", .{v}),
            .RegShift => |v| try std.fmt.format(writer, "reg-shift: 0x{x:0>2}", .{v}),
            .Reg => |v| {
                try writer.writeAll("reg: <");
                for (v) |pair, i| {
                    if (i != 0) {
                        try writer.writeByte(' ');
                    }
                    try std.fmt.format(writer, "0x{x:0>2} 0x{x:0>2}", .{ pair[0], pair[1] });
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
            .PHandle => |v| try std.fmt.format(writer, "phandle: <0x{x:0>2}>", .{v}),
            .InterruptParent => |v| try std.fmt.format(writer, "interrupt-parent: <0x{x:0>2}>", .{v}),
            .Interrupts => |groups| {
                try writer.writeAll("interrupts: <");
                for (groups) |group, i| {
                    if (i != 0) {
                        try writer.writeAll(" ");
                    }
                    for (group) |item, j| {
                        if (j != 0) {
                            try writer.writeAll(" ");
                        }
                        try std.fmt.format(writer, "0x{x:0>2}", .{item});
                    }
                }
                try writer.writeAll(">");
            },
            .Unresolved => |v| try writer.writeAll("UNRESOLVED"),
            .Unknown => |v| try std.fmt.format(writer, "{s}: (unk {} bytes) <{}>", .{ std.zig.fmtEscapes(v.name), v.value.len, std.zig.fmtEscapes(v.value) }),
        }
    }

    pub fn deinit(prop: Prop, allocator: *std.mem.Allocator) void {
        switch (prop) {
            .Reg => |v| allocator.free(v),
            .Compatible => |v| allocator.free(v),
            .Interrupts => |groups| {
                for (groups) |group| {
                    allocator.free(group);
                }
                allocator.free(groups);
            },
            else => {},
        }
    }
};

pub const PropUnresolved = union(enum) {
    Interrupts: []const u8,
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
    {
        var qemu = try parse(std.testing.allocator, qemu_dtb);
        defer qemu.deinit(std.testing.allocator);

        // This QEMU DTB places 512MiB of memory at 1GiB.
        testing.expectEqualSlices(
            [2]u64,
            &.{.{ 1024 * 1024 * 1024, 512 * 1024 * 1024 }},
            qemu.propAt(&.{"memory@40000000"}, .Reg).?,
        );

        // It has an A53-compatible CPU.
        const compatible = qemu.propAt(&.{ "cpus", "cpu@0" }, .Compatible).?;
        testing.expectEqual(@as(usize, 1), compatible.len);
        testing.expectEqualStrings("arm,cortex-a53", compatible[0]);

        // Its pl011 UART controller has interrupts defined by <0x00 0x01 0x04>.
        // This tests the #interrupt-cells lookup.  Its interrupt domain
        // is defined ahead of it in the file.
        // This defines one SPI-type interrupt, IRQ 1, active high
        // level-sensitive. See https://git.io/JtKJk.
        const pl011 = qemu.child("pl011@9000000").?;
        const interrupts = pl011.prop(.Interrupts).?;
        testing.expectEqual(@as(usize, 1), interrupts.len);
        testing.expectEqualSlices(u32, &.{ 0x0, 0x01, 0x04 }, interrupts[0]);

        // Test we refer to the apb-pclk's clock cells (0) correctly.
        testing.expectEqual(@as(u32, 0), qemu.propAt(&.{"apb-pclk"}, .ClockCells).?);
        testing.expectEqual(@as(usize, 2), clock_names.len);
        testing.expectEqualSlices(u8, "uartclk", clock_names[0]);
        testing.expectEqualSlices(u8, "apb_pclk", clock_names[1]);
        const clocks = pl011.prop(.Clocks).?;
        testing.expectEqual(@as(usize, 2), clocks.len);
        testing.expectEqualSlices(u32, &.{0x8000}, clocks[0]);
        testing.expectEqualSlices(u32, &.{0x8000}, clocks[0]);

        // Make sure this works (and that the code gets compiled).
        std.debug.print("{}\n", .{qemu});
    }

    {
        var rockpro64 = try parse(std.testing.allocator, rockpro64_dtb);
        defer rockpro64.deinit(std.testing.allocator);

        // This ROCKPro64 DTB has a serial at 0xff180000.
        const serial = rockpro64.child("serial@ff180000").?;
        testing.expectEqualSlices([2]u64, &.{.{ 0xff180000, 0x100 }}, serial.prop(.Reg).?);
        testing.expectEqual(PropStatus.Okay, serial.prop(.Status).?);
        testing.expectEqual(@as(u32, 2), serial.prop(.RegShift).?);
        testing.expectEqual(@as(u32, 0x2c), serial.prop(.PHandle).?);

        const compatible = serial.prop(.Compatible).?;
        testing.expectEqual(@as(usize, 2), compatible.len);
        testing.expectEqualStrings("rockchip,rk3399-uart", compatible[0]);
        testing.expectEqualStrings("snps,dw-apb-uart", compatible[1]);

        const interrupts = serial.prop(.Interrupts).?;
        testing.expectEqual(@as(usize, 1), interrupts.len);
        // GICv3 specifies 4 interrupt cells. This defines an SPI-type
        // interrupt, IRQ 99, level triggered. The last field must be zero
        // for SPI interrupts.
        testing.expectEqualSlices(u32, &.{ 0x0, 0x63, 0x04, 0x00 }, interrupts[0]);

        // Test that we refer to the clock controller's clock cells (1) correctly.
        testing.expectEqual(@as(u32, 1), rockpro64.propAt(&.{"clock-controller@ff760000"}, .ClockCells).?);
        const clock_names = serial.prop(.ClockNames).?;
        testing.expectEqual(@as(usize, 2), clock_names.len);
        testing.expectEqualSlices(u8, "baudclk", clock_names[0]);
        testing.expectEqualSlices(u8, "apb_pclk", clock_names[1]);
        const clocks = serial.prop(.Clocks).?;
        testing.expectEqual(@as(usize, 2), clocks.len);
        testing.expectEqualSlices(u32, &.{ 0x85, 0x51 }, clocks[0]);
        testing.expectEqualSlices(u32, &.{ 0x85, 0x6001 }, clocks[1]);

        // Node <serial@ff180000>
        // "rockchip,rk3399-uart\0snps,dw-apb-uart"
        // reg: <0xff180000 0x100>
        // clocks: (unk 16 bytes) <\x00\x00\x00\x85\x00\x00\x00Q\x00\x00\x00\x85\x00\x00\x01`>
        // clock-names: (unk 17 bytes) <baudclk\x00apb_pclk\x00>
        // interrupts: <0x00 0x63 0x04 0x00>
        // reg-shift: 0x02
        // reg-io-width: (unk 4 bytes) <\x00\x00\x00\x04>
        // pinctrl-names: (unk 8 bytes) <default\x00>
        // pinctrl-0: (unk 12 bytes) <\x00\x00\x01\x1b\x00\x00\x01\x1c\x00\x00\x01\x1d>
        // status: "okay"
        // phandle: <0x2c>
        // Node <bluetooth>
        //     "brcm,bcm43438-bt"
        //     clocks: (unk 8 bytes) <\x00\x00\x00^\x00\x00\x00\x01>
        //     clock-names: (unk 4 bytes) <lpo\x00>
        //     device-wakeup-gpios: (unk 12 bytes) <\x00\x00\x00\xc5\x00\x00\x00\x1b\x00\x00\x00\x00>
        //     host-wakeup-gpios: (unk 12 bytes) <\x00\x00\x00\xc3\x00\x00\x00\x04\x00\x00\x00\x00>
        //     shutdown-gpios: (unk 12 bytes) <\x00\x00\x00\xc3\x00\x00\x00\t\x00\x00\x00\x00>
        //     pinctrl-names: (unk 8 bytes) <default\x00>
        //     pinctrl-0: (unk 12 bytes) <\x00\x00\x018\x00\x00\x019\x00\x00\x017>
        //     vbat-supply: (unk 4 bytes) <\x00\x00\x01Q>
        //     vddio-supply: (unk 4 bytes) <\x00\x00\x00b>

        // Print it out.
        std.debug.print("{}\n", .{rockpro64});
    }
}

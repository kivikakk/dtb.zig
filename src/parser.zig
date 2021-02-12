const std = @import("std");
const dtb = @import("dtb.zig");

const FDTHeader = packed struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

const FDTReserveEntry = packed struct {
    address: u64,
    size: u64,
};

const FDTToken = packed enum(u32) {
    BeginNode = 0x00000001,
    EndNode = 0x00000002,
    Prop = 0x00000003,
    Nop = 0x00000004,
    End = 0x00000009,
};

const FDTProp = packed struct {
    len: u32,
    nameoff: u32,
};

// ---

fn structBigToNative(comptime T: type, s: T) T {
    var r = s;
    inline for (std.meta.fields(T)) |field| {
        @field(r, field.name) = std.mem.bigToNative(field.field_type, @field(r, field.name));
    }
    return r;
}

// ---

pub const Error = std.mem.Allocator.Error || error{
    Truncated,
    BadMagic,
    UnsupportedVersion,
    BadStructure,
    MissingCells,
    UnsupportedCells,
    BadValue,
};

pub fn parse(allocator: *std.mem.Allocator, fdt: []const u8) Error!*dtb.Node {
    if (fdt.len < @sizeOf(FDTHeader)) {
        return error.Truncated;
    }
    const header = structBigToNative(FDTHeader, @ptrCast(*const FDTHeader, fdt.ptr).*);
    if (header.magic != 0xd00dfeed) {
        return error.BadMagic;
    }
    if (fdt.len < header.totalsize) {
        return error.Truncated;
    }
    if (header.version != 17) {
        return error.UnsupportedVersion;
    }

    var parser = Parser{ .fdt = fdt, .header = header, .offset = header.off_dt_struct };
    if (parser.token() != .BeginNode) {
        return error.BadStructure;
    }

    var root = try parseBeginNode(allocator, &parser, null, null);
    errdefer root.deinit(allocator);

    if (parser.token() != .End) {
        return error.BadStructure;
    }
    if (parser.offset != header.off_dt_struct + header.size_dt_struct) {
        return error.BadStructure;
    }

    try resolve(allocator, root, root);

    return root;
}

/// ---
const Parser = struct {
    fdt: []const u8,
    header: FDTHeader,
    offset: usize,

    fn aligned(parser: *@This(), comptime T: type) T {
        const size = @sizeOf(T);
        const value = @ptrCast(*const T, @alignCast(@alignOf(T), parser.fdt[parser.offset .. parser.offset + size])).*;
        parser.offset += size;
        return value;
    }

    fn buffer(parser: *@This(), length: usize) []const u8 {
        const value = parser.fdt[parser.offset .. parser.offset + length];
        parser.offset += length;
        return value;
    }

    fn token(parser: *@This()) FDTToken {
        return @intToEnum(FDTToken, std.mem.bigToNative(u32, parser.aligned(u32)));
    }

    fn object(parser: *@This(), comptime T: type) T {
        return structBigToNative(T, parser.aligned(T));
    }

    fn cstring(parser: *@This()) []const u8 {
        const length = std.mem.lenZ(@ptrCast([*c]const u8, parser.fdt[parser.offset..]));
        const value = parser.fdt[parser.offset .. parser.offset + length];
        parser.offset += length + 1;
        return value;
    }

    fn cstringFromSectionOffset(parser: @This(), offset: usize) []const u8 {
        const length = std.mem.lenZ(@ptrCast([*c]const u8, parser.fdt[parser.header.off_dt_strings + offset ..]));
        return parser.fdt[parser.header.off_dt_strings + offset ..][0..length];
    }

    fn alignTo(parser: *@This(), comptime T: type) void {
        parser.offset += @sizeOf(T) - 1;
        parser.offset &= ~@as(usize, @sizeOf(T) - 1);
    }
};

fn parseBeginNode(allocator: *std.mem.Allocator, parser: *Parser, root: ?*dtb.Node, parent: ?*dtb.Node) Error!*dtb.Node {
    const node_name = parser.cstring();
    parser.alignTo(u32);

    var props = std.ArrayList(dtb.Prop).init(allocator);
    var children = std.ArrayList(*dtb.Node).init(allocator);

    errdefer {
        for (props.items) |p| {
            p.deinit(allocator);
        }
        props.deinit();
        for (children.items) |c| {
            c.deinit(allocator);
        }
        children.deinit();
    }

    var node = try allocator.create(dtb.Node);
    errdefer allocator.destroy(node);

    var context = NodeContext{
        .allocator = allocator,
    };

    while (true) {
        switch (parser.token()) {
            .BeginNode => {
                var subnode = try parseBeginNode(allocator, parser, root orelse node, node);
                try children.append(subnode);
            },
            .EndNode => {
                break;
            },
            .Prop => {
                const prop = parser.object(FDTProp);
                const prop_name = parser.cstringFromSectionOffset(prop.nameoff);
                const prop_value = parser.buffer(prop.len);
                try props.append(try context.prop(prop_name, prop_value));
                parser.alignTo(u32);
            },
            .Nop => {},
            .End => {
                return error.BadStructure;
            },
        }
    }

    node.* = .{
        .name = node_name,
        .props = props.toOwnedSlice(),
        .root = root orelse node,
        .parent = parent,
        .children = children.toOwnedSlice(),
    };
    return node;
}

const NodeContext = struct {
    allocator: *std.mem.Allocator,

    fn prop(context: *@This(), name: []const u8, value: []const u8) Error!dtb.Prop {
        if (std.mem.eql(u8, name, "#address-cells")) {
            return dtb.Prop{ .AddressCells = try integer(u32, value) };
        } else if (std.mem.eql(u8, name, "#size-cells")) {
            return dtb.Prop{ .SizeCells = try integer(u32, value) };
        } else if (std.mem.eql(u8, name, "#interrupt-cells")) {
            return dtb.Prop{ .InterruptCells = try integer(u32, value) };
        } else if (std.mem.eql(u8, name, "#clock-cells")) {
            return dtb.Prop{ .ClockCells = try integer(u32, value) };
        } else if (std.mem.eql(u8, name, "reg-shift")) {
            return dtb.Prop{ .RegShift = try integer(u32, value) };
        } else if (std.mem.eql(u8, name, "status")) {
            return dtb.Prop{ .Status = try status(value) };
        } else if (std.mem.eql(u8, name, "phandle")) {
            return dtb.Prop{ .PHandle = try integer(u32, value) };
        } else if (std.mem.eql(u8, name, "interrupt-parent")) {
            return dtb.Prop{ .InterruptParent = try integer(u32, value) };
        } else if (std.mem.eql(u8, name, "compatible")) {
            return dtb.Prop{ .Compatible = try context.stringList(value) };
        } else if (std.mem.eql(u8, name, "clock-names")) {
            return dtb.Prop{ .ClockNames = try context.stringList(value) };
        } else if (std.mem.eql(u8, name, "clock-output-names")) {
            return dtb.Prop{ .ClockOutputNames = try context.stringList(value) };
        } else if (std.mem.eql(u8, name, "interrupt-names")) {
            return dtb.Prop{ .InterruptNames = try context.stringList(value) };
        } else if (std.mem.eql(u8, name, "clock-frequency")) {
            return dtb.Prop{ .ClockFrequency = try u32OrU64(value) };
        } else if (std.mem.eql(u8, name, "reg-io-width")) {
            return dtb.Prop{ .RegIoWidth = try u32OrU64(value) };
        } else if (std.mem.eql(u8, name, "pinctrl-names")) {
            return dtb.Prop{ .PinctrlNames = try context.stringList(value) };
        } else if (std.mem.eql(u8, name, "pinctrl-0")) {
            return dtb.Prop{ .Pinctrl0 = try context.integerList(u32, value) };
        } else if (std.mem.eql(u8, name, "pinctrl-1")) {
            return dtb.Prop{ .Pinctrl1 = try context.integerList(u32, value) };
        } else if (std.mem.eql(u8, name, "pinctrl-2")) {
            return dtb.Prop{ .Pinctrl2 = try context.integerList(u32, value) };
        } else if (std.mem.eql(u8, name, "assigned-clock-rates")) {
            return dtb.Prop{ .AssignedClockRates = try context.integerList(u32, value) };
        } else if (std.mem.eql(u8, name, "reg")) {
            return dtb.Prop{ .Unresolved = .{ .Reg = value } };
        } else if (std.mem.eql(u8, name, "ranges")) {
            return dtb.Prop{ .Unresolved = .{ .Ranges = value } };
        } else if (std.mem.eql(u8, name, "interrupts")) {
            return dtb.Prop{ .Unresolved = .{ .Interrupts = value } };
        } else if (std.mem.eql(u8, name, "clocks")) {
            return dtb.Prop{ .Unresolved = .{ .Clocks = value } };
        } else if (std.mem.eql(u8, name, "assigned-clocks")) {
            return dtb.Prop{ .Unresolved = .{ .AssignedClocks = value } };
        } else {
            return dtb.Prop{ .Unknown = .{ .name = name, .value = value } };
        }
    }

    fn integer(comptime T: type, value: []const u8) !T {
        if (value.len != @sizeOf(T)) return error.BadStructure;
        return std.mem.bigToNative(T, @ptrCast(*const T, @alignCast(@alignOf(T), value.ptr)).*);
    }

    fn integerList(context: @This(), comptime T: type, value: []const u8) ![]T {
        if (value.len % @sizeOf(T) != 0) return error.BadStructure;
        var list = try context.allocator.alloc(T, value.len / @sizeOf(T));
        var i: usize = 0;
        while (i < list.len) : (i += 1) {
            list[i] = std.mem.bigToNative(T, @ptrCast(*const T, @alignCast(@alignOf(T), value[i * @sizeOf(T) ..].ptr)).*);
        }
        return list;
    }

    fn u32OrU64(value: []const u8) !u64 {
        return switch (value.len) {
            @sizeOf(u32) => @as(u64, try integer(u32, value)),
            @sizeOf(u64) => try integer(u64, value),
            else => error.BadStructure,
        };
    }

    fn stringList(context: @This(), value: []const u8) Error![][]const u8 {
        const count = std.mem.count(u8, value, "\x00");
        var strings = try context.allocator.alloc([]const u8, count);
        errdefer context.allocator.free(strings);
        var offset: usize = 0;
        var strings_i: usize = 0;
        while (offset < value.len) : (strings_i += 1) {
            const len = std.mem.lenZ(@ptrCast([*c]const u8, value[offset..]));
            strings[strings_i] = value[offset .. offset + len];
            offset += len + 1;
        }
        return strings;
    }

    fn status(value: []const u8) Error!dtb.PropStatus {
        if (std.mem.eql(u8, value, "okay\x00")) {
            return dtb.PropStatus.Okay;
        } else if (std.mem.eql(u8, value, "disabled\x00")) {
            return dtb.PropStatus.Disabled;
        } else if (std.mem.eql(u8, value, "fail\x00")) {
            return dtb.PropStatus.Fail;
        }
        return error.BadValue;
    }
};

// ---

fn resolve(allocator: *std.mem.Allocator, root: *dtb.Node, current: *dtb.Node) Error!void {
    for (current.*.props) |*prop| {
        switch (prop.*) {
            .Unresolved => |unres| {
                prop.* = try resolveProp(allocator, root, current, unres);
            },
            else => {},
        }
    }

    for (current.*.children) |child| {
        try resolve(allocator, root, child);
    }
}

fn resolveProp(allocator: *std.mem.Allocator, root: *dtb.Node, current: *dtb.Node, unres: dtb.PropUnresolved) !dtb.Prop {
    switch (unres) {
        .Reg => |v| {
            const address_cells = (current.parent orelse return error.BadStructure).addressCells() orelse return error.MissingCells;
            const size_cells = (current.parent orelse return error.BadStructure).sizeCells() orelse return error.MissingCells;
            return dtb.Prop{ .Reg = try readArray(allocator, v, 2, [2]u32{ address_cells, size_cells }) };
        },
        .Ranges => |v| {
            const address_cells = current.addressCells() orelse return error.MissingCells;
            const parent_address_cells = (current.parent orelse return error.BadStructure).addressCells() orelse return error.MissingCells;
            const size_cells = current.sizeCells() orelse return error.MissingCells;
            return dtb.Prop{ .Ranges = try readArray(allocator, v, 3, [3]u32{ address_cells, parent_address_cells, size_cells }) };
        },
        .Interrupts => |v| {
            const interrupt_cells = current.interruptCells() orelse return error.MissingCells;
            const big_endian_cells = try cellsBigEndian(v);
            if (big_endian_cells.len % interrupt_cells != 0) {
                return error.BadStructure;
            }

            const group_count = big_endian_cells.len / interrupt_cells;
            var groups = try std.ArrayList([]u32).initCapacity(allocator, group_count);
            errdefer {
                for (groups.items) |group| allocator.free(group);
                groups.deinit();
            }

            var group_i: usize = 0;
            while (group_i < group_count) : (group_i += 1) {
                var group = try allocator.alloc(u32, interrupt_cells);
                var item_i: usize = 0;
                while (item_i < interrupt_cells) : (item_i += 1) {
                    group[item_i] = std.mem.bigToNative(u32, big_endian_cells[group_i * interrupt_cells + item_i]);
                }
                groups.appendAssumeCapacity(group);
            }

            return dtb.Prop{ .Interrupts = groups.toOwnedSlice() };
        },
        .Clocks,
        .AssignedClocks,
        => |v| {
            const big_endian_cells = try cellsBigEndian(v);
            var groups = std.ArrayList([]u32).init(allocator);
            errdefer {
                for (groups.items) |group| allocator.free(group);
                groups.deinit();
            }

            var cell_i: usize = 0;
            while (cell_i < big_endian_cells.len) {
                const phandle = std.mem.bigToNative(u32, big_endian_cells[cell_i]);
                cell_i += 1;
                const target = root.findPHandle(phandle) orelse return error.MissingCells;
                const clock_cells = target.prop(.ClockCells) orelse return error.MissingCells;
                var group = try allocator.alloc(u32, 1 + clock_cells);
                errdefer allocator.free(group);
                group[0] = phandle;
                var item_i: usize = 0;
                while (item_i < clock_cells) : (item_i += 1) {
                    group[item_i + 1] = std.mem.bigToNative(u32, big_endian_cells[cell_i]);
                    cell_i += 1;
                }
                try groups.append(group);
            }

            return switch (unres) {
                .Clocks => dtb.Prop{ .Clocks = groups.toOwnedSlice() },
                .AssignedClocks => dtb.Prop{ .AssignedClocks = groups.toOwnedSlice() },
                else => unreachable,
            };
        },
    }
}

// ---
const READ_ARRAY_RETURN = u128;

fn readArray(allocator: *std.mem.Allocator, value: []const u8, comptime elem_count: usize, elems: [elem_count]u32) Error![][elem_count]READ_ARRAY_RETURN {
    const big_endian_cells = try cellsBigEndian(value);
    var elems_sum: usize = 0;
    for (elems) |elem| {
        if (elem > (@sizeOf(READ_ARRAY_RETURN) / @sizeOf(u32))) {
            return error.UnsupportedCells;
        }
        elems_sum += elem;
    }

    if (big_endian_cells.len % elems_sum != 0) {
        return error.BadStructure;
    }

    var tuples: [][elem_count]READ_ARRAY_RETURN = try allocator.alloc([elem_count]READ_ARRAY_RETURN, big_endian_cells.len / elems_sum);
    errdefer allocator.free(tuples);
    var tuple_i: usize = 0;

    var cell_i: usize = 0;
    while (cell_i < big_endian_cells.len) : (tuple_i += 1) {
        var elem_i: usize = 0;
        while (elem_i < elem_count) : (elem_i += 1) {
            var j: usize = undefined;
            tuples[tuple_i][elem_i] = 0;
            j = 0;
            while (j < elems[elem_i]) : (j += 1) {
                tuples[tuple_i][elem_i] = (tuples[tuple_i][elem_i] << 32) | std.mem.bigToNative(u32, big_endian_cells[cell_i]);
                cell_i += 1;
            }
        }
    }
    return tuples;
}

fn cellsBigEndian(value: []const u8) ![]const u32 {
    if (value.len % @sizeOf(u32) != 0) return error.BadStructure;
    return @ptrCast([*]const u32, @alignCast(@alignOf(u32), value))[0 .. value.len / @sizeOf(u32)];
}

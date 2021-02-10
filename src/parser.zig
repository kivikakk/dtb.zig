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

const PropertyTypeMapping = struct {
    property_name: []const u8,
    property_type: type,
};
const PROPERTY_TYPE_MAPPINGS: [2]PropertyTypeMapping = .{
    .{ .property_name = "#address-cells", .property_type = u32 },
    .{ .property_name = "#size-cells", .property_type = u32 },
};

fn PropertyType(comptime property_name: []const u8) type {
    inline for (PROPERTY_TYPE_MAPPINGS) |mapping| {
        if (comptime std.mem.eql(u8, property_name, mapping.property_name)) {
            return mapping.property_type;
        }
    }
    @compileError("unknown property \"" ++ property_name ++ "\"");
}

fn propertyValue(comptime property_name: []const u8, value: []const u8) PropertyType(property_name) {
    const t = PropertyType(property_name);
    return @ptrCast(*const t, @alignCast(@alignOf(t), value.ptr)).*;
}

fn bigToNative(comptime T: type, s: T) T {
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
};

pub fn parse(allocator: *std.mem.Allocator, fdt: []const u8) Error!dtb.Node {
    if (fdt.len < @sizeOf(FDTHeader)) {
        return error.Truncated;
    }
    const header = bigToNative(FDTHeader, @ptrCast(*const FDTHeader, fdt.ptr).*);
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

    if (parser.token() != .End) {
        return error.BadStructure;
    }
    if (parser.offset != header.off_dt_struct + header.size_dt_struct) {
        return error.BadStructure;
    }

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
        return bigToNative(T, parser.aligned(T));
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

fn parseBeginNode(allocator: *std.mem.Allocator, parser: *Parser, address_cells: ?u32, size_cells: ?u32) Error!dtb.Node {
    const node_name = parser.cstring();
    parser.alignTo(u32);

    var props = std.ArrayList(dtb.Prop).init(allocator);
    var children = std.ArrayList(dtb.Node).init(allocator);

    // Node inherts #address/#size-cells from parent, but its own props may override those for
    // its children (and other props?).
    var context = NodeContext{
        .allocator = allocator,
        .address_cells = address_cells,
        .size_cells = size_cells,
    };

    while (true) {
        switch (parser.token()) {
            .BeginNode => {
                var subnode = try parseBeginNode(allocator, parser, context.address_cells, context.size_cells);
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

    return dtb.Node{
        .name = node_name,
        .props = props.toOwnedSlice(),
        .children = children.toOwnedSlice(),
    };
}

const NodeContext = struct {
    allocator: *std.mem.Allocator,
    address_cells: ?u32,
    size_cells: ?u32,

    fn prop(context: *@This(), name: []const u8, value: []const u8) Error!dtb.Prop {
        if (std.mem.eql(u8, name, "#address-cells")) {
            context.address_cells = std.mem.bigToNative(u32, propertyValue("#address-cells", value));
            return dtb.Prop{ .AddressCells = context.address_cells.? };
        } else if (std.mem.eql(u8, name, "#size-cells")) {
            context.size_cells = std.mem.bigToNative(u32, propertyValue("#size-cells", value));
            return dtb.Prop{ .SizeCells = context.size_cells.? };
        } else if (std.mem.eql(u8, name, "reg")) {
            if (context.address_cells == null or context.size_cells == null) {
                return error.MissingCells;
            }
            // Limit each to u64.
            if (context.address_cells.? > 2 or context.size_cells.? > 2) {
                return error.UnsupportedCells;
            }
            const pair_size = (context.address_cells.? + context.size_cells.?) * @sizeOf(u32);
            if (value.len % pair_size != 0) {
                return error.BadStructure;
            }

            var cells = @ptrCast([*]const u32, @alignCast(@alignOf(u32), value))[0 .. value.len / @sizeOf(u32)];

            var pairs: [][2]u64 = try context.allocator.alloc([2]u64, value.len / pair_size);
            var pair_i: usize = 0;

            var cell_i: usize = 0;
            while (cell_i < cells.len) : (pair_i += 1) {
                var j: usize = undefined;

                pairs[pair_i][0] = 0;
                j = 0;
                while (j < context.address_cells.?) : (j += 1) {
                    pairs[pair_i][0] = (pairs[pair_i][0] << 32) | std.mem.bigToNative(u32, cells[cell_i]);
                    cell_i += 1;
                }

                pairs[pair_i][1] = 0;
                j = 0;
                while (j < context.size_cells.?) : (j += 1) {
                    pairs[pair_i][1] = (pairs[pair_i][1] << 32) | std.mem.bigToNative(u32, cells[cell_i]);
                    cell_i += 1;
                }
            }

            return dtb.Prop{ .Reg = pairs };
        } else {
            return dtb.Prop{ .Unknown = .{ .name = name, .value = value } };
        }
    }
};

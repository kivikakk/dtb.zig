const std = @import("std");
const util = @import("util.zig");
const fdt = @import("fdt.zig");

pub const Error = error{
    Truncated,
    BadMagic,
    UnsupportedVersion,
    BadStructure,
    EOF,
    Internal,
};

pub const Event = union(enum) {
    BeginNode: []const u8,
    EndNode,
    Prop: Prop,
    End,
};

pub const State = union(enum) {
    Init,
    Depth: usize,
    AtEnd,
    Ended,
};

pub const Prop = struct {
    name: []const u8,
    value: []const u8,
};

pub const Traverser = struct {
    const Self = @This();

    blob: []const u8,
    header: fdt.FDTHeader,
    offset: usize,
    state: State,

    pub fn init(self: *Self, blob: []const u8) Error!void {
        if (blob.len < @sizeOf(fdt.FDTHeader)) {
            return error.Truncated;
        }

        self.blob = blob;

        const header = util.structBigToNative(fdt.FDTHeader, @ptrCast(*align(1) const fdt.FDTHeader, blob.ptr).*);
        if (header.magic != fdt.FDTMagic) {
            return error.BadMagic;
        }
        if (blob.len < header.totalsize) {
            return error.Truncated;
        }
        if (header.version != 17) {
            return error.UnsupportedVersion;
        }

        self.header = header;
        self.offset = header.off_dt_struct;
        self.state = .Init;

        switch (self.token()) {
            .BeginNode => {},
            else => return error.BadStructure,
        }
    }

    pub fn event(self: *Self) Error!Event {
        switch (self.state) {
            .Init => {
                const node_name = self.cstring();
                self.alignTo(u32);
                self.state = .{ .Depth = 0 };
                return .{ .BeginNode = node_name };
            },
            .Depth => |depth| {
                while (true) {
                    switch (self.token()) {
                        .BeginNode => {
                            const node_name = self.cstring();
                            self.alignTo(u32);
                            self.state = .{ .Depth = depth + 1 };
                            return .{ .BeginNode = node_name };
                        },
                        .EndNode => {
                            if (depth > 0) {
                                self.state = .{ .Depth = depth - 1 };
                            } else {
                                self.state = .AtEnd;
                            }
                            return .EndNode;
                        },
                        .Prop => {
                            const prop = self.object(fdt.FDTProp);
                            const prop_name = self.cstringFromSectionOffset(prop.nameoff);
                            const prop_value = self.buffer(prop.len);
                            self.alignTo(u32);
                            return .{
                                .Prop = .{
                                    .name = prop_name,
                                    .value = prop_value,
                                },
                            };
                        },
                        .Nop => {},
                        .End => {
                            return error.BadStructure;
                        },
                    }
                }
            },
            .AtEnd => {
                if (self.token() != .End) {
                    return error.BadStructure;
                }

                if (self.offset != self.header.off_dt_struct + self.header.size_dt_struct) {
                    return error.BadStructure;
                }

                self.state = .Ended;
                return .End;
            },
            .Ended => return error.EOF,
        }
    }

    fn aligned(self: *Self, comptime T: type) T {
        const size = @sizeOf(T);
        // XXX: Choosing to work out neater solutions to this later.
        const value = @ptrCast(*align(1) const T, self.blob[self.offset .. self.offset + size]).*;
        self.offset += size;
        return value;
    }

    fn token(self: *Self) fdt.FDTToken {
        return @intToEnum(fdt.FDTToken, std.mem.bigToNative(u32, self.aligned(u32)));
    }

    fn buffer(self: *Self, length: usize) []const u8 {
        const value = self.blob[self.offset .. self.offset + length];
        self.offset += length;
        return value;
    }

    fn object(self: *Self, comptime T: type) T {
        return util.structBigToNative(T, self.aligned(T));
    }

    fn cstring(self: *Self) []const u8 {
        const length = std.mem.len(@ptrCast([*c]const u8, self.blob[self.offset..]));
        const value = self.blob[self.offset .. self.offset + length];
        self.offset += length + 1;
        return value;
    }

    fn cstringFromSectionOffset(self: Self, offset: usize) []const u8 {
        const length = std.mem.len(@ptrCast([*c]const u8, self.blob[self.header.off_dt_strings + offset ..]));
        return self.blob[self.header.off_dt_strings + offset ..][0..length];
    }

    fn alignTo(self: *Self, comptime T: type) void {
        // std.mem.alignForward(&self.offset, @sizeOf(T));
        self.offset += @sizeOf(T) - 1;
        self.offset &= ~@as(usize, @sizeOf(T) - 1);
    }
};

/// Try to carefully extract the total size of an FDT at this address.
pub fn totalSize(blob: *anyopaque) Error!u32 {
    const header_ptr = @ptrCast(*align(1) const fdt.FDTHeader, blob);

    if (std.mem.bigToNative(u32, header_ptr.magic) != fdt.FDTMagic) {
        return error.BadMagic;
    }

    return std.mem.bigToNative(u32, header_ptr.totalsize);
}

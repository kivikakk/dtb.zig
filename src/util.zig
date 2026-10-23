const std = @import("std");

pub fn structBigToNative(comptime T: type, s: T) T {
    var r = s;
    const type_info = @typeInfo(T).@"struct";
    inline for (0..type_info.field_types.len) |i| {
        const field_name = type_info.field_names[i];
        const field_type = type_info.field_types[i];
        @field(r, field_name) = std.mem.bigToNative(field_type, @field(r, field_name));
    }
    return r;
}

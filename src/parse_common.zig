const std = @import("std");
pub fn parseStruct(comptime T: type, endian: std.builtin.Endian, r: anytype) !T {
    const info = @typeInfo(T);
    switch (info) {
        .@"enum" => |e| {
            //const int = try parseStruct(e.tag_type, endian, r);
            const int = try r.readInt(e.tag_type, endian);
            return std.meta.intToEnum(T, int);
        },
        .@"struct" => |s| {
            var ret: T = undefined;
            inline for (s.fields) |f| {
                @field(ret, f.name) = try parseStruct(f.type, endian, r);
            }
            return ret;
        },
        .float => {
            switch (T) {
                f32 => {
                    const int = try r.readInt(u32, endian);
                    return @bitCast(int);
                },
                f64 => {
                    const int = try r.readInt(u64, endian);
                    return @bitCast(int);
                },
                else => @compileError("bad float"),
            }
        },
        .int => {
            return try r.readInt(T, endian);
        },
        .array => |a| {
            var ret: T = undefined;
            for (0..a.len) |i| {
                ret[i] = try parseStruct(a.child, endian, r);
            }
            return ret;
        },
        else => @compileError("not supported"),
    }
}

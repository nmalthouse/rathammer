//Ensure this gets updated with build.zig.zon version
const version_private = "0.0.5-pre";

const std = @import("std");

pub const version = blk: {
    const parsed = parseSemver(version_private) catch @compileError("Invalid sem ver: " ++ version_private);
    _ = parsed;
    break :blk version_private;
};

pub fn parseSemver(string: []const u8) ![3]u32 {
    var tkz = std.mem.tokenizeAny(u8, string, ".-");
    const maj = tkz.next() orelse return error.invalidSemVer;
    const min = tkz.next() orelse return error.invalidSemVer;
    const rev = tkz.next() orelse return error.invalidSemVer;

    return [3]u32{
        std.fmt.parseInt(u32, maj, 10) catch return error.invalidSemVer,
        std.fmt.parseInt(u32, min, 10) catch return error.invalidSemVer,
        std.fmt.parseInt(u32, rev, 10) catch return error.invalidSemVer,
    };
}

test "parse semantic version" {
    const ex = std.testing.expectEqual;
    try ex(parseSemver("1.2.3"), [3]u32{ 1, 2, 3 });
    try ex(parseSemver("1.2.3-pre"), [3]u32{ 1, 2, 3 });
}

pub fn gtSemver(a: [3]u32, b: [3]u32) bool {
    const al: u128 = @as(u128, @intCast(a[0])) << 64 | @as(u128, @intCast(a[1])) << 32 | a[2];
    const bl: u128 = @as(u128, @intCast(b[0])) << 64 | @as(u128, @intCast(b[1])) << 32 | b[2];
    return al > bl;
}

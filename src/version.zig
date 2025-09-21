//Ensure this gets updated with build.zig.zon version
const version_private = "0.1.0";
const builtin = @import("builtin");

const std = @import("std");

const sp = " ";
pub const version_string = @tagName(builtin.mode) ++ sp ++
    @tagName(builtin.target.os.tag) ++ sp ++
    @tagName(builtin.target.cpu.arch) ++ sp ++ version_private;
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

test "gt" {
    const ex = std.testing.expectEqual;
    const p = parseSemver;
    try ex(true, gtSemver(try p("1.1.2"), try p("1.1.1")));
    try ex(true, gtSemver(try p("0.0.1"), try p("0.0.0")));
    try ex(true, gtSemver(try p("1.0.3"), try p("1.0.0-letters")));
}

pub fn gtSemver(a: [3]u32, b: [3]u32) bool {
    const al: u128 = @as(u128, @intCast(a[0])) << 64 | @as(u128, @intCast(a[1])) << 32 | a[2];
    const bl: u128 = @as(u128, @intCast(b[0])) << 64 | @as(u128, @intCast(b[1])) << 32 | b[2];
    return al > bl;
}

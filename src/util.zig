const std = @import("std");
//Contains random things

threadlocal var real_path_buffer: [1024]u8 = undefined;
pub fn openFileFatal(
    dir: std.fs.Dir,
    sub_path: []const u8,
    flags: std.fs.File.OpenFlags,
    message: []const u8,
) std.fs.File {
    return dir.openFile(sub_path, flags) catch |err| {
        const rp = dir.realpath(".", &real_path_buffer) catch "error.realpathFailed";

        std.debug.print("Failed to open file {s} in directory: {s}  with error: {}\n", .{ sub_path, rp, err });
        std.debug.print("{s}\n", .{message});
        std.process.exit(1);
    };
}

pub fn openDirFatal(
    dir: std.fs.Dir,
    sub_path: []const u8,
    flags: std.fs.Dir.OpenDirOptions,
    message: []const u8,
) std.fs.Dir {
    return dir.openDir(sub_path, flags) catch |err| {
        const rp = dir.realpath(".", &real_path_buffer) catch "error.realpathFailed";

        std.debug.print("Failed to open directory {s} in {s} with error: {}\n", .{ sub_path, rp, err });
        std.debug.print("{s}\n", .{message});
        std.process.exit(1);
    };
}

//Perform a linear search for closest match, returning index
pub fn nearest(comptime T: type, items: []const T, context: anytype, comptime distanceFn: fn (@TypeOf(context), item: T, key: T) f32, key: T) ?usize {
    var nearest_i: ?usize = null;
    var dist: f32 = std.math.floatMax(f32);
    for (items, 0..) |item, i| {
        const d = distanceFn(context, item, key);
        if (d < dist) {
            nearest_i = i;
            dist = d;
        }
    }
    return nearest_i;
}

pub fn ensurePathRelative(string: []const u8, should_bitch: bool) []const u8 {
    if (string.len == 0) return string;

    if (string[0] == '/' or string[0] == '\\') {
        if (should_bitch)
            std.debug.print("RELATIVE PATH IS SPECIFIED AS ABSOLUTE. PLEASE FIX {s} \n", .{string});
        return string[1..];
    }
    return string;
}

pub fn getFileFromTar(alloc: std.mem.Allocator, fileo: std.fs.File, filename: []const u8) ![]const u8 {
    var fname_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var lname_buffer: [std.fs.max_path_bytes]u8 = undefined;

    var tar_it = std.tar.iterator(fileo.reader(), .{
        .file_name_buffer = &fname_buffer,
        .link_name_buffer = &lname_buffer,
    });
    while (tar_it.next() catch null) |file| {
        if (std.mem.eql(u8, file.name, filename)) {
            return try file.reader().readAllAlloc(alloc, std.math.maxInt(usize));
        }
    }
    return error.notFound;
}

pub const LoadCtxDummy = struct {
    const Self = @This();

    pub fn printCb(self: *Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        _ = fmt;
        _ = args;
    }

    pub fn cb(_: *Self, _: []const u8) void {}

    pub fn addExpected(_: *Self, _: usize) void {}
};

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

pub fn fatalPrintFilePath(dir: std.fs.Dir, path: []const u8, err: anyerror, message: []const u8) noreturn {
    const rp = dir.realpath(".", &real_path_buffer) catch "error.realpathFailed";

    std.debug.print("Failed to open file {s} in directory: {s}  with error: {}\n", .{ path, rp, err });
    std.debug.print("{s}\n", .{message});
    std.process.exit(1);
}

pub fn openDirFatal(
    dir: std.fs.Dir,
    sub_path: []const u8,
    flags: std.fs.Dir.OpenOptions,
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

    var read_buf: [4096]u8 = undefined;
    var read = fileo.reader(&read_buf);
    var tar_it = std.tar.Iterator{
        .reader = &read.interface,
        .file_name_buffer = &fname_buffer,
        .link_name_buffer = &lname_buffer,
    };
    while (tar_it.next() catch null) |file| {
        if (std.mem.eql(u8, file.name, filename)) {
            var aw: std.io.Writer.Allocating = .init(alloc);
            const wr = &aw.writer;
            try tar_it.streamRemaining(file, wr);
            return try aw.toOwnedSlice();
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

/// Split a path to map file into a path component and a base component with map extension stripped
pub fn pathToMapName(map_path: []const u8) !struct { []const u8, []const u8 } {
    const path = std.fs.path.dirname(map_path) orelse "";
    const base = std.fs.path.basename(map_path);
    const ext = std.fs.path.extension(base);
    const allowed_exts = [_][]const u8{
        ".json",
        ".tar",
        ".ratmap",
        ".vmf",
    };

    var found = false;
    for (allowed_exts) |allowed| {
        if (std.mem.eql(u8, allowed, ext))
            found = true;
    }
    if (!found)
        std.debug.print("unknown map file extension {s}\n", .{ext});

    if (ext.len >= base.len)
        return error.invalidMapName;

    const base_no_ext = base[0 .. base.len - ext.len];
    return .{
        path,
        base_no_ext,
    };
}

test "map path" {
    const ex = std.testing.expectEqualDeep;
    try ex(.{ "/tmp/0.0.0", "p" }, try pathToMapName("/tmp/0.0.0/p.json"));
    try ex(.{ "", "p" }, try pathToMapName("p"));
    try ex(.{ "", ".json" }, try pathToMapName(".json"));
    try ex(.{ "hello/world", "0.0.0" }, try pathToMapName("hello/world/0.0.0.ratmap"));
}

pub fn readFile(alloc: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8) ![]const u8 {
    var buffer: [4096]u8 = undefined;

    var in = try dir.openFile(filename, .{});
    defer in.close();

    var reader = in.reader(&buffer);

    return try reader.interface.allocRemaining(alloc, .unlimited);
}

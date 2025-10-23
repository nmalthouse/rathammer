const std = @import("std");
const graph = @import("graph");
const util = @import("util.zig");

pub fn splitPath(path: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |index| {
        return .{ path[0..index], path[index + 1 ..] };
    }

    return .{ ".", path };
}

pub fn printString(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    var vec = std.ArrayList(u8){};

    try vec.print(alloc, fmt, args);
    return vec.items;
}

pub fn stripExtension(str: []const u8) []const u8 {
    return str[0 .. std.mem.lastIndexOfScalar(u8, str, '.') orelse str.len];
}

pub fn catString(alloc: std.mem.Allocator, strings: []const []const u8) ![]const u8 {
    var total_len: usize = 0;
    for (strings) |str|
        total_len += str.len;
    const slice = try alloc.alloc(u8, total_len);
    var index: usize = 0;
    for (strings) |str| {
        @memcpy(slice[index .. index + str.len], str);
        index += str.len;
    }
    return slice;
}

fn die() noreturn {
    std.debug.print("Something horrible happened. Absolutely, fatal\n", .{});
    std.process.exit(1);
}

const builtin = @import("builtin");
const DO_WINE = builtin.target.os.tag != .windows;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var arg_it = try std.process.argsWithAllocator(alloc);
    defer arg_it.deinit();
    const Arg = graph.ArgGen.Arg;
    const args = try graph.ArgGen.parseArgs(&.{
        Arg("vmf", .string, "vmf to load"),
        Arg("exedir", .string, "directory of vbsp etc"),
        Arg("gamedir", .string, "directory to game, 'Half-Life 2'"),
        Arg("gamename", .string, "name of game 'hl2_complete'"),
        Arg("outputdir", .string, "dir relative to gamedir where bsp is put, 'hl2/maps'"),
        Arg("tmpdir", .string, "directory for map artifacts, default is /tmp/mapcompile"),
    }, &arg_it);
    try buildmap(alloc, .{
        .cwd = std.fs.cwd(),
        .exedir_pre = args.exedir orelse "Half-Life 2/bin",
        .gamename = args.gamename orelse "hl2_complete",
        .gamedir_pre = args.gamedir orelse "Half-Life 2",
        .tmpdir = args.tmpdir orelse "/tmp/mapcompile",
        .outputdir = args.outputdir orelse "hl2/maps",
        .vmf = args.vmf orelse {
            std.debug.print("Please specify vmf name with --vmf\n", .{});
            return;
        },
    });
}
pub const Paths = struct {
    cwd: std.fs.Dir,
    gamename: []const u8,
    gamedir_pre: []const u8,
    exedir_pre: []const u8,
    tmpdir: []const u8,
    outputdir: []const u8,
    vmf: []const u8,
};
const log = std.log.scoped(.map_builder);

//Does not keep track of memory
pub fn buildmap(alloc: std.mem.Allocator, args: Paths) !void {
    const game_cwd = args.cwd;

    const gamedir = game_cwd.realpathAlloc(alloc, args.gamedir_pre) catch |err| {
        log.err("realpath failed of {s} {t}", .{ args.gamedir_pre, err });
        return err;
    };
    std.debug.print("found gamedir: {s}\n", .{gamedir});

    const exedir = game_cwd.realpathAlloc(alloc, args.exedir_pre) catch |err| {
        log.err("realpath failed of {s} {t}", .{ args.exedir_pre, err });
        return err;
    };

    const working_dir = args.tmpdir;
    const outputdir = try catString(alloc, &.{ gamedir, "/", args.outputdir });

    const mapname = args.vmf;

    const stripped = splitPath(mapname);
    const map_no_extension = stripExtension(stripped[1]);
    const working = game_cwd.makeOpenPath(working_dir, .{}) catch |err| {
        log.err("working dir failed {s} {t}", .{ working_dir, err });
        return err;
    };
    const working_abs = game_cwd.realpathAlloc(alloc, working_dir) catch |err| {
        log.err("unable to realpath workingdir {s} {t}", .{ working_dir, err });
        return err;
    };

    std.fs.cwd().copyFile(mapname, working, stripped[1], .{}) catch |err| {
        log.err("failed to copy vmf {s} {t}", .{ mapname, err });
        return err;
    };

    const output_dir = game_cwd.openDir(outputdir, .{}) catch |err| {
        log.err("failed to open output dir {s}, with {t}", .{ outputdir, err });
        return err;
    };

    const game_path = try catString(alloc, &.{ gamedir, "/", args.gamename });
    const start_i = if (DO_WINE) 0 else 1;
    const vbsp = [_][]const u8{ "wine", try catString(alloc, &.{ exedir, "/vbsp.exe" }), "-game", game_path, "-novconfig", map_no_extension };
    const vvis = [_][]const u8{ "wine", try catString(alloc, &.{ exedir, "/vvis.exe" }), "-game", game_path, "-novconfig", "-fast", map_no_extension };
    const vrad = [_][]const u8{ "wine", try catString(alloc, &.{ exedir, "/vrad.exe" }), "-game", game_path, "-novconfig", "-fast", map_no_extension };
    try runCommand(alloc, vbsp[start_i..], working_abs);
    try runCommand(alloc, vvis[start_i..], working_abs);
    try runCommand(alloc, vrad[start_i..], working_abs);

    const bsp_name = try printString(alloc, "{s}.bsp", .{map_no_extension});
    try working.copyFile(bsp_name, output_dir, bsp_name, .{});
}

fn runCommand(alloc: std.mem.Allocator, argv: []const []const u8, working_dir: []const u8) !void {
    std.debug.print("Running command in: {s} ", .{working_dir});
    for (argv) |arg|
        std.debug.print("{s} ", .{arg});
    std.debug.print("\n", .{});
    var child = std.process.Child.init(argv, alloc);
    child.cwd = working_dir;
    child.stdout_behavior = .Pipe;
    child.stdin_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    {
        std.debug.assert(child.stdout_behavior == .Pipe);
        std.debug.assert(child.stderr_behavior == .Pipe);

        //FUCK IT, fix this later
        //var poller = std.io.poll(alloc, enum { stdout, stderr }, .{
        //    .stdout = child.stdout.?,
        //    .stderr = child.stderr.?,
        //});
        //defer poller.deinit();

        //var stdout_buf: [128]u8 = undefined;

        //while (try poller.poll()) {
        //    std.Thread.sleep(std.time.ns_per_ms * 16);
        //    var count = poller.fifo(.stdout).read(&stdout_buf);
        //    std.debug.print("{s}", .{stdout_buf[0..count]});
        //    count = poller.fifo(.stderr).read(&stdout_buf);
        //    std.debug.print("{s}", .{stdout_buf[0..count]});
        //}
    }
    //try getAllTheStuff(child.stderr);

    switch (try child.wait()) {
        .Exited => |e| {
            if (e == 0)
                return;
        },
        else => {},
    }
    return error.broken;
}

pub fn getAllTheStuff(fileo: anytype) !void {
    if (fileo) |file| {
        var line_buf: [512]u8 = undefined;
        const r = file.reader();
        while (true) {
            const line = r.readUntilDelimiter(&line_buf, '\n') catch |err| switch (err) {
                error.StreamTooLong => continue,
                error.EndOfStream => break,
                else => break,
            };
            std.debug.print("{s}\n", .{line});
        }
    }
}

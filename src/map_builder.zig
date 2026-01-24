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

pub fn main(arg_it: *std.process.ArgIterator, alloc: std.mem.Allocator, stdout: *std.io.Writer) !void {
    _ = stdout;
    const Arg = graph.ArgGen.Arg;
    const args = try graph.ArgGen.parseArgs(&.{
        Arg("vmf", .string, "vmf to load"),
        Arg("exedir", .string, "directory of vbsp etc"),
        Arg("gamedir", .string, "directory to game, 'Half-Life 2'"),
        Arg("gamename", .string, "name of game 'hl2_complete'"),
        Arg("outputdir", .string, "dir relative to gamedir where bsp is put, 'hl2/maps'"),
        Arg("tmpdir", .string, "directory for map artifacts, default is /tmp/mapcompile"),
    }, arg_it);
    try buildmap(alloc, .{
        .cwd_path = try std.process.getCwdAlloc(alloc),
        .exedir_pre = args.exedir orelse "Half-Life 2/bin",
        .gamename = args.gamename orelse "hl2_complete",
        .gamedir_pre = args.gamedir orelse "Half-Life 2",
        .tmpdir = args.tmpdir orelse "/tmp/mapcompile",
        .outputdir = args.outputdir orelse "hl2/maps",
        .user_cmd = "",
        .vmf = args.vmf orelse {
            std.debug.print("Please specify vmf name with --vmf\n", .{});
            return;
        },
    });
}
pub const Paths = struct {
    cwd_path: []const u8,
    gamename: []const u8,
    gamedir_pre: []const u8,
    exedir_pre: []const u8,
    tmpdir: []const u8,
    outputdir: []const u8,
    vmf: []const u8,
    user_cmd: []const u8,
};
const log = std.log.scoped(.map_builder);

pub fn runUserBuildCommand(alloc: std.mem.Allocator, args: Paths) !void {
    const cwd = std.fs.cwd();

    const working_dir = args.tmpdir;

    const working = cwd.makeOpenPath(working_dir, .{}) catch |err| {
        log.err("working dir failed {s} {t}", .{ working_dir, err });
        return err;
    };
    const gamedir = try std.fs.path.resolve(alloc, &.{ args.cwd_path, args.gamedir_pre });

    const exedir = try std.fs.path.resolve(alloc, &.{ args.cwd_path, args.exedir_pre });
    const outputdir = try std.fs.path.resolve(alloc, &.{ gamedir, args.outputdir });

    var env = std.process.EnvMap.init(alloc);
    try env.put("rh_cwd_path", args.cwd_path);
    try env.put("rh_gamename", args.gamename);
    try env.put("rh_gamedir", gamedir);
    try env.put("rh_exedir", exedir);
    try env.put("rh_outputdir", outputdir);
    try env.put("rh_vmf", args.vmf);

    std.fs.cwd().copyFile(args.vmf, working, std.fs.path.basename(args.vmf), .{}) catch |err| {
        log.err("failed to copy vmf {s} {t}", .{ args.vmf, err });
        return err;
    };

    try runCommand(alloc, &.{args.user_cmd}, working_dir, &env);
}

//Does not keep track of memory
pub fn buildmap(alloc: std.mem.Allocator, args: Paths) !void {
    const cwd = std.fs.cwd();

    const gamedir = try std.fs.path.resolve(alloc, &.{ args.cwd_path, args.gamedir_pre });
    std.debug.print("found gamedir: {s}\n", .{gamedir});

    const exedir = try std.fs.path.resolve(alloc, &.{ args.cwd_path, args.exedir_pre });

    const working_dir = args.tmpdir;
    const outputdir = try std.fs.path.resolve(alloc, &.{ gamedir, args.outputdir });

    const mapname = args.vmf;

    const stripped = splitPath(mapname);
    const map_no_extension = stripExtension(stripped[1]);
    const working = cwd.makeOpenPath(working_dir, .{}) catch |err| {
        log.err("working dir failed {s} {t}", .{ working_dir, err });
        return err;
    };

    std.fs.cwd().copyFile(mapname, working, stripped[1], .{}) catch |err| {
        log.err("failed to copy vmf {s} {t}", .{ mapname, err });
        return err;
    };

    const output_dir = cwd.openDir(outputdir, .{}) catch |err| {
        log.err("failed to open output dir {s}, with {t}", .{ outputdir, err });
        return err;
    };

    const game_path = try catString(alloc, &.{ gamedir, "/", args.gamename });
    const start_i = if (DO_WINE) 0 else 1;
    const vbsp = [_][]const u8{ "wine", try catString(alloc, &.{ exedir, "/vbsp.exe" }), "-game", game_path, "-novconfig", map_no_extension };
    const vvis = [_][]const u8{ "wine", try catString(alloc, &.{ exedir, "/vvis.exe" }), "-game", game_path, "-novconfig", "-fast", map_no_extension };
    const vrad = [_][]const u8{ "wine", try catString(alloc, &.{ exedir, "/vrad.exe" }), "-game", game_path, "-novconfig", "-fast", map_no_extension };
    try runCommand(alloc, vbsp[start_i..], working_dir, null);
    try runCommand(alloc, vvis[start_i..], working_dir, null);
    try runCommand(alloc, vrad[start_i..], working_dir, null);

    const bsp_name = try printString(alloc, "{s}.bsp", .{map_no_extension});
    try working.copyFile(bsp_name, output_dir, bsp_name, .{});
}

fn runCommand(alloc: std.mem.Allocator, argv: []const []const u8, working_dir: []const u8, env: ?*std.process.EnvMap) !void {
    std.debug.print("Running command  {s} ", .{working_dir});
    for (argv) |arg|
        std.debug.print("{s} ", .{arg});
    std.debug.print("\n", .{});

    var child = std.process.Child.init(argv, alloc);
    child.env_map = env;
    child.cwd = working_dir;
    child.stdout_behavior = .Pipe;
    child.stdin_behavior = .Ignore;
    //child.stderr_behavior = .Pipe;
    try child.spawn();

    const enable_stdout = true;

    if (enable_stdout) {
        std.debug.assert(child.stdout_behavior == .Pipe);

        var poller = std.Io.poll(alloc, enum {
            stdout,
            //, stderr
        }, .{
            .stdout = child.stdout.?,
            //.stderr = child.stderr.?,
        });
        defer poller.deinit();

        //TODO this seems fishy...
        // std.io.poll is not documented, inits all readers as failing. Does not specify if user is allowed to override these readers.
        // It calls free() on each of the buffers
        poller.readers[0] = .fixed(try alloc.alloc(u8, 128));
        var out_r = poller.reader(.stdout);

        var stdout_buf: [256]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        const stdout = &stdout_writer.interface;

        while (try poller.poll()) {
            std.Thread.sleep(std.time.ns_per_ms * 16);

            _ = try out_r.streamRemaining(stdout);
            try stdout.flush();
        }
        try stdout.flush();
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

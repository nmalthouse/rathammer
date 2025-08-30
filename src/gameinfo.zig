const std = @import("std");
const vdf = @import("vdf.zig");
const VpkCtx = @import("vpk.zig").Context;
const Dir = std.fs.Dir;
const log = std.log.scoped(.gameinfo);

//TODO gameinfo.txt is so fucked I would rather permaban it. If you try to load a gameinfo.txt ratammer deletes your harddrive.
//Specify a new format that actuallyfuckingworks. and have users write that instead.
//half life 2 does not tell you if it is omitting a path or why.
//If I delete all paths from hl2_complete/gameinfo.txt, the game still launches

fn readFromFile(alloc: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8) ![]const u8 {
    const inf = try dir.openFile(filename, .{});
    defer inf.close();
    const slice = try inf.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    return slice;
}

pub fn loadGameinfo(alloc: std.mem.Allocator, base_dir: Dir, game_dir: Dir, vpkctx: *VpkCtx, loadctx: anytype, filename: []const u8) !void {
    const sl = readFromFile(alloc, game_dir, filename) catch |err| {
        var out_path_buf: [512]u8 = undefined;
        const rp = game_dir.realpath(".", &out_path_buf) catch return err;
        log.err("Failed to find gameinfo \"{s}\" in {s}", .{ filename, rp });
        return err;
    };
    defer alloc.free(sl);

    var obj = try vdf.parse(alloc, sl, null, .{});
    defer obj.deinit();

    var aa = std.heap.ArenaAllocator.init(alloc);
    defer aa.deinit();
    const gameinfo = try vdf.fromValue(struct {
        gameinfo: struct {
            game: []const u8 = "",
            title: []const u8 = "",
            type: []const u8 = "",
        } = .{},
    }, &obj, &.{ .obj = &obj.value }, aa.allocator(), null);
    log.info("Loading gameinfo {s} {s}", .{ gameinfo.gameinfo.game, gameinfo.gameinfo.title });

    const fs = try obj.value.recursiveGetFirst(&obj, &.{ "gameinfo", "filesystem", "searchpaths" });
    if (fs != .obj)
        return error.invalidGameInfo;
    //vdf.printObj(fs.obj.*, 0);
    const startsWith = std.mem.startsWith;
    for (fs.obj.list.items) |entry| {
        const en = obj.stringFromId(entry.key) orelse "";
        if (!shouldAdd(en)) {
            log.info("IGNORING gameinfo searchpath with key: {s}", .{en});
            continue;
        }
        if (entry.val != .literal)
            return error.invalidGameInfo;
        const l = entry.val.literal;
        var path = l;
        const dir = blk: {
            if (startsWith(u8, l, "|")) {
                const end = std.mem.indexOfScalar(u8, l[1..], '|') orelse return error.invalidGameInfo;
                const special = l[1..end];
                path = l[end + 2 ..];
                if (std.mem.eql(u8, special, "all_source_engine_paths"))
                    break :blk base_dir;
                if (std.mem.eql(u8, special, "gameinfo_path"))
                    break :blk game_dir;
            }
            break :blk base_dir;
        };

        if (std.mem.endsWith(u8, path, ".vpk")) {
            loadctx.printCb("mounting: {s}", .{path});
            if ((std.mem.indexOfPos(u8, path, 0, "sound") == null)) {
                vpkctx.addDir(dir, path, loadctx) catch |err| {
                    log.err("Failed to mount vpk {s} with error {}", .{ path, err });
                };
            }
        } else {
            if (std.mem.endsWith(u8, path, "/*")) {
                std.debug.print("Wildcard not supported yet! oops\n", .{});
                continue;
            }
            log.info("Mounting loose dir: {s}", .{path});
            vpkctx.addLooseDir(dir, path) catch |err| {
                log.err("Failed to mount loose dir: {s} {!}", .{ path, err });
            };
        }
    }
    //TODO this is temp
    try vpkctx.slowIndexOfLooseDirSubPath("materials");
}

fn shouldAdd(gameinfo_key: []const u8) bool {
    const supported = [_][]const u8{ "game", "platform", "mod", "root_mod" };
    var tk = std.mem.tokenizeScalar(u8, gameinfo_key, '+');
    while (tk.next()) |t| {
        for (supported) |sup| {
            if (std.mem.eql(u8, sup, t))
                return true;
        }
    }
    return false;
}

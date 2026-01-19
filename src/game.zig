pub const Game = struct {
    name: []const u8,

    good: bool,
    reason: []const u8,
};

pub const GameList = struct {
    const Self = @This();
    alloc: std.mem.Allocator,
    list: std.StringArrayHashMapUnmanaged(Game),

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .alloc = alloc,
            .list = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.list.values()) |v| {
            self.alloc.free(v.name);
            self.alloc.free(v.reason);
        }
        self.list.deinit(self.alloc);
    }

    // clobbers existing list
    pub fn createGameList(self: *Self, game_map: *std.StringHashMapUnmanaged(Conf.GameEntry), games_dir: fsutil.WrappedDir) !void {
        self.deinit();
        self.* = .init(self.alloc);

        var it = game_map.iterator();
        while (it.next()) |item| {
            var summary: std.io.Writer.Allocating = .init(self.alloc);
            const wr = &summary.writer;
            const en = item.value_ptr;
            try wr.print("\n", .{});
            var failed = false;
            games_dir.doesFileExistInDir(en.fgd_dir, en.fgd) catch |err| {
                failed = true;
                try wr.print("    fgd: {t}\n", .{err});
                try wr.print("        fgd_dir: {s}\n", .{en.fgd_dir});
                try wr.print("        fgd    : {s}\n", .{en.fgd});
            };
            for (en.gameinfo.items, 0..) |ginfo, i| {
                const name = if (ginfo.gameinfo_name.len > 0) ginfo.gameinfo_name else "gameinfo.txt";

                games_dir.doesFileExistInDir(ginfo.game_dir, name) catch |err| {
                    failed = true;

                    try wr.print("    gameinfo {d}: {t}\n", .{ i, err });
                    try wr.print("        game_dir: {s}\n", .{ginfo.game_dir});
                    try wr.print("        gameinfo: {s}\n", .{name});
                    if (ginfo.gameinfo_name.len > 0) {
                        try wr.print("        NOTE this is a custom gameinfo. You may have to copy it from rathammer/extra!\n", .{});
                    }
                };
            }
            { //map builder

                const gdir = games_dir.doesDirExist(en.mapbuilder.game_dir);
                const edir = games_dir.doesDirExist(en.mapbuilder.exe_dir);
                if (!gdir or !edir) {
                    try wr.print("    mapbuilder: \n", .{});
                    if (!gdir)
                        try wr.print("        game_dir: error.fileNotFound\n", .{});
                    if (!edir)
                        try wr.print("        exe_dir : error.fileNotFound\n", .{});
                }
            }

            const new = Game{
                .good = !failed,
                .name = try self.alloc.dupe(u8, item.key_ptr.*),
                .reason = try summary.toOwnedSlice(),
            };
            try self.list.put(self.alloc, new.name, new);
        }
    }

    pub fn id(self: *Self, game_name: []const u8) ?usize {
        return self.list.getIndex(game_name);
    }

    pub fn getName(self: *Self, id_: usize) ?[]const u8 {
        if (id_ >= self.list.values().len) return null;
        return self.list.values()[id_].name;
    }

    pub fn get(self: *Self, id_: usize) ?Game {
        if (id_ >= self.list.values().len) return null;
        return self.list.values()[id_];
    }
};

const std = @import("std");
const Conf = @import("config.zig");
const fsutil = @import("fs.zig");
const StringStorage = @import("string.zig").StringStorage;

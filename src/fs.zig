const std = @import("std");
const builtin = @import("builtin");

const graph = @import("graph");
const log = std.log.scoped(.path_guess);
const util = @import("util.zig");

pub const WrappedDir = struct {
    dir: std.fs.Dir,
    path: []const u8,

    /// User must call .close on returned
    pub fn openDir(self: @This(), sub_path: []const u8, flags: std.fs.Dir.OpenOptions, alloc: std.mem.Allocator) !@This() {
        return .{
            .dir = try self.dir.openDir(sub_path, flags),
            .path = try std.fs.path.resolve(alloc, &.{ self.path, sub_path }),
        };
    }

    pub fn makeOpenPath(self: @This(), sub_path: []const u8, flags: std.fs.Dir.OpenOptions, alloc: std.mem.Allocator) !@This() {
        return .{
            .dir = try self.dir.makeOpenPath(sub_path, flags),
            .path = try std.fs.path.resolve(alloc, &.{ self.path, sub_path }),
        };
    }

    pub fn close(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        self.dir.close();
    }

    pub fn cwd(alloc: std.mem.Allocator) !@This() {
        const cwd_string = try std.process.getCwdAlloc(alloc);
        return .{ .dir = std.fs.cwd(), .path = cwd_string };
    }

    pub fn free(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }

    pub fn absolute(abs_path: []const u8, flags: std.fs.Dir.OpenOptions, alloc: std.mem.Allocator) !@This() {
        return .{
            .path = try alloc.dupe(u8, abs_path),
            .dir = try std.fs.cwd().openDir(abs_path, flags),
        };
    }

    pub fn doesFileExist(self: @This(), path: []const u8) bool {
        if (self.dir.openFile(path, .{})) |file| {
            file.close();
            return true;
        } else |_| {
            return false;
        }
    }

    pub fn doesDirExist(self: @This(), path: []const u8) bool {
        if (self.dir.openDir(path, .{})) |di| {
            var d = di;
            d.close();
            return true;
        } else |_| {
            return false;
        }
    }

    /// Returns null if it exists, otherwise an error message
    pub fn doesFileExistInDir(self: @This(), sub_path: []const u8, filename: []const u8) !void {
        if (self.dir.openDir(sub_path, .{})) |dir| {
            var d = dir;
            defer d.close();
            if (dir.openFile(filename, .{})) |file| {
                file.close();
                return;
            } else |_| {
                return error.fileNotFound;
            }
        } else |_| {
            return error.dirNotFound;
        }
    }
};

pub const Dirs = struct {
    const Dir = std.fs.Dir;
    games_dir: WrappedDir,
    app_cwd: WrappedDir,
    config: WrappedDir,
    fgd: Dir,
    pref: Dir,
    autosave: Dir,

    pub fn open(
        alloc: std.mem.Allocator,
        cwd: WrappedDir,
        param: struct {
            config_dir: WrappedDir,
            app_cwd: WrappedDir,
            override_games_dir: ?[]const u8,
            config_steam_dir: []const u8,

            override_fgd_dir: ?[]const u8,
            config_fgd_dir: []const u8,
        },
        env: *std.process.EnvMap,
    ) !Dirs {
        const games_dir = try openGameDir(alloc, cwd, param.override_games_dir, param.config_steam_dir, env);
        std.debug.print("Games dir  : {s}\n", .{games_dir.path});
        const fgd_dir = util.openDirFatal(games_dir.dir, param.override_fgd_dir orelse param.config_fgd_dir, .{}, "");

        const ORG = "rathammer";
        const APP = "";
        const path = graph.c.SDL_GetPrefPath(ORG, APP);
        if (path == null) {
            log.err("Unable to make pref path", .{});
        }
        const pref = try std.fs.cwd().makeOpenPath(std.mem.span(path), .{});
        const autosave = try pref.makeOpenPath("autosave", .{});

        return .{
            .games_dir = games_dir,
            .fgd = fgd_dir,
            .pref = pref,
            .autosave = autosave,
            .app_cwd = param.app_cwd,
            .config = param.config_dir,
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.games_dir.close(alloc);
    }
};

pub fn guessSteamPath(env: *std.process.EnvMap, alloc: std.mem.Allocator) !?WrappedDir {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    const os = builtin.target.os.tag;
    switch (os) {
        .windows => try buf.appendSlice(alloc, "/Program Files (x86)/Steam/steamapps/common"),
        .linux => {
            const HOME = env.get("HOME") orelse return null;
            try buf.appendSlice(alloc, HOME);
            try buf.appendSlice(alloc, "/.local/share/Steam/steamapps/common");
        },
        else => return null,
    }

    defer log.info("Guessed steam path {s}", .{buf.items});
    return WrappedDir.absolute(buf.items, .{}, alloc) catch |err| {
        log.warn("Guessed steam path: '{s}' but failed to open", .{buf.items});
        log.warn("Error: {t}", .{err});
        return null;
    };
}

pub fn openXdgDir(alloc: std.mem.Allocator, cwd: WrappedDir, app_cwd: WrappedDir, arg_override: ?[]const u8, env: *std.process.EnvMap, xdg_dir_name: []const u8) !WrappedDir {
    if (arg_override != null)
        return try cwd.openDir(".", .{}, alloc);

    const xdg_config_dir = (env.get(xdg_dir_name));
    var config_path: std.ArrayList(u8) = .{};
    defer config_path.deinit(alloc);
    if (xdg_config_dir) |x| {
        try config_path.print(alloc, "{s}/rathammer", .{x});
    } else {
        switch (builtin.target.os.tag) {
            // Workaround to weird ntdll segfault.
            // Sometimes an invalidStatus error with openFile(recent_maps) -> STATUS_OBJECT_TYPE_MISMATCH   0xC0000024
            // Sometimes it segfaults on INVALID_STATUS
            // Seems to be involve a race condition
            // app_cwd and config_dir are never closed so this makes no sense.
            .windows => return try app_cwd.openDir(".", .{}, alloc),
            else => {
                if (env.get("HOME")) |home| {
                    try config_path.print(alloc, "{s}/.config/rathammer", .{home});
                } else {
                    log.info("{s} and $HOME not defined, using app dir", .{xdg_dir_name});
                    return try app_cwd.openDir(".", .{}, alloc);
                }
            },
        }
    }
    return app_cwd.makeOpenPath(config_path.items, .{}, alloc) catch {
        log.info("failed to open {s} defaulting to app cwd", .{config_path.items});
        return try app_cwd.openDir(".", .{}, alloc);
    };
}

/// Precedence:
/// ? cli flag
/// ? config path
/// ? default steam path on platform
/// program cwd
pub fn openGameDir(alloc: std.mem.Allocator, cwd: WrappedDir, arg_override: ?[]const u8, config_steam_dir: []const u8, env: *std.process.EnvMap) !WrappedDir {
    if (arg_override) |cc| {
        return cwd.openDir(cc, .{}, alloc) catch |err| {
            log.err("Failed to open custom cwd {s} with {t}", .{ cc, err });
            return err;
        };
    } else {
        if (config_steam_dir.len > 0) {
            if (cwd.openDir(config_steam_dir, .{}, alloc)) |steam_dir| {
                log.info("Opened config.paths.steam_dir: {s}", .{config_steam_dir});
                return steam_dir;
            } else |err| {
                log.err("Failed to open config.paths.steam_dir: {s} with {t}", .{ config_steam_dir, err });
            }
        }
        return try guessSteamPath(env, alloc) orelse {
            log.info("Failed to guess steam path, defaulting to exe cwd ", .{});
            return try cwd.openDir(".", .{}, alloc);
        };
    }
}

pub fn openAppCwd(env: *std.process.EnvMap, cwd: WrappedDir, alloc: std.mem.Allocator) !WrappedDir {
    //TODO we don't distribute appimages

    switch (builtin.target.os.tag) {
        .linux => if (env.get("APPDIR")) |appdir| { //For appimage
            return cwd.openDir(appdir, .{}, alloc) catch {
                log.err("Unable to open $APPDIR {s}", .{appdir});
                return try cwd.openDir(".", .{}, alloc);
            };
        },
        else => {},
    }
    return try cwd.openDir(".", .{}, alloc);
}

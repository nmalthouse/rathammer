const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.path_guess);

//TODO rename this file to filesystem and move other filesystem specific stuff in here

pub fn guessSteamPath(env: *std.process.EnvMap, alloc: std.mem.Allocator) !?std.fs.Dir {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    const os = builtin.target.os.tag;
    switch (os) {
        .windows => try buf.appendSlice("/Program Files (x86)/Steam/steamapps/common"),
        .linux => {
            const HOME = env.get("HOME") orelse return null;
            try buf.appendSlice(HOME);
            try buf.appendSlice("/.local/share/Steam/steamapps/common");
        },
        else => return null,
    }

    defer log.info("Guessed steam path {s}", .{buf.items});
    return std.fs.cwd().openDir(buf.items, .{}) catch |err| {
        log.warn("Guessed steam path: '{s}' but failed to open", .{buf.items});
        log.warn("Error: {!}", .{err});
        return null;
    };
}

pub fn openConfigDir(alloc: std.mem.Allocator, cwd: std.fs.Dir, app_cwd: std.fs.Dir, arg_override: ?[]const u8, env: *std.process.EnvMap) !std.fs.Dir {
    if (arg_override != null)
        return cwd;

    const xdg_config_dir = (env.get("XDG_CONFIG_DIR"));
    var config_path = std.ArrayList(u8).init(alloc);
    defer config_path.deinit();
    if (xdg_config_dir) |x| {
        try config_path.writer().print("{s}/rathammer", .{x});
    } else {
        switch (builtin.target.os.tag) {
            // Workaround to weird ntdll segfault.
            // Sometimes an invalidStatus error with openFile(recent_maps) -> STATUS_OBJECT_TYPE_MISMATCH   0xC0000024
            // Sometimes it segfaults on INVALID_STATUS
            // Seems to be involve a race condition
            // app_cwd and config_dir are never closed so this makes no sense.
            .windows => return try app_cwd.openDir(".", .{}),
            else => {
                if (env.get("HOME")) |home| {
                    try config_path.writer().print("{s}/.config/rathammer", .{home});
                } else {
                    log.info("XDG_CONFIG_HOME and $HOME not defined, using config in app dir", .{});
                    return app_cwd;
                }
            },
        }
    }
    return app_cwd.makeOpenPath(config_path.items, .{}) catch {
        log.info("failed to open {s} defaulting to app cwd", .{config_path.items});
        return app_cwd;
    };
}

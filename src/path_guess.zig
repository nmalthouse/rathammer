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

const builtin = @import("builtin");
const zon_version = @import("version"); // contains build.zig.zon.version
const version_private = zon_version.version;

const std = @import("std");

pub const help_url = "https://git.sr.ht/~niklasm/rathammer/tree/master/doc/start.md";
//pub const help_url = "https://github.com/nmalthouse/rathammer/blob/master/doc/start.md";
pub const project_url = "https://git.sr.ht/~niklasm/rathammer";

const sp = " ";
pub const version_string = @tagName(builtin.mode) ++ sp ++
    @tagName(builtin.target.os.tag) ++ sp ++
    @tagName(builtin.target.cpu.arch) ++ sp ++ version_private;
pub const version = blk: {
    const parsed = std.SemanticVersion.parse(version_private) catch @compileError("Invalid sem ver: " ++ version_private);
    _ = parsed;
    break :blk version_private;
};

pub const version_short = version_private;

const std = @import("std");
//pub const bsp = @import("bsp.zig");
pub const clip_solid = @import("clip_solid.zig");
pub const prim_gen = @import("primitive_gen.zig");
pub const autosave = @import("autosave.zig");
pub const vdf = @import("vdf.zig");
pub const string = @import("string.zig");

pub const editor = @import("tests/editor.zig");
pub const vdf_s = @import("tests/vdf.zig");
pub const vpk = @import("tests/vpk.zig");
pub const jm = @import("tests/json_map.zig");
pub const av = @import("tests/autovis.zig");
pub const app = @import("app.zig");

//TODO tests for
//clip_solid
//fgd
//gameinfo
//grid
//classtrack
//config - with errors
//app behavior test
//json to vmf??
//jsonmap
//layer system
//mdl loading - get animations working
//primitive generation
//selection is important

test {
    std.testing.refAllDecls(@This());
}

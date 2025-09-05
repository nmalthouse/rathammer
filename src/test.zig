const std = @import("std");
pub const clip_solid = @import("clip_solid.zig");
pub const prim_gen = @import("primitive_gen.zig");
pub const autosave = @import("autosave.zig");
pub const vdf = @import("vdf.zig");
pub const editor = @import("tests/editor.zig");

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
//seletion is important

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
pub const clip_solid = @import("clip_solid.zig");
pub const prim_gen = @import("primitive_gen.zig");
pub const autosave = @import("autosave.zig");
pub const vdf = @import("vdf.zig");

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

//How do we test the editor?
//We need to replace sdl input with manual input
//

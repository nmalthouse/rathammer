const std = @import("std");
pub const clip_solid = @import("clip_solid.zig");
pub const prim_gen = @import("primitive_gen.zig");
pub const vdf = @import("vdf.zig");

//TODO tests for
//clip_solid
//fgd
//gameinfo
//grid

test {
    std.testing.refAllDecls(@This());
}

//How do we test the editor?
//We need to replace sdl input with manual input
//

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

test "editor init" {
    const edit = @import("editor.zig");
    const Conf = @import("config.zig");
    const Editor = edit.Context;
    const graph = @import("graph");
    const app = @import("app.zig");
    const IS_DEBUG = false;

    const alloc = std.testing.allocator;

    var conf = try Conf.loadConfig(alloc, @embedFile("default_config.vdf"));
    defer conf.deinit();
    const config = conf.config;

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();

    const app_cwd = std.fs.cwd();
    const config_dir = std.fs.cwd();

    var win = try graph.SDL.Window.createWindow("Rat Hammer", .{
        .window_size = .{ .x = config.window.width_px, .y = config.window.height_px },
        .frame_sync = .adaptive_vsync,
        .gl_major_version = 4,
        .gl_minor_version = 2,
        .enable_debug = IS_DEBUG,
        .gl_flags = if (IS_DEBUG) &[_]u32{graph.c.SDL_GL_CONTEXT_DEBUG_FLAG} else &[_]u32{},
    });
    defer win.destroyWindow();

    var arg_it = std.mem.tokenizeScalar(u8, "rathammer", ' ');
    const args = try graph.ArgGen.parseArgs(&app.Args, &arg_it);

    var loadctx = edit.LoadCtx{};
    var editor = try Editor.init(alloc, if (args.nthread) |nt| @intFromFloat(nt) else null, config, args, &win, &loadctx, &env, app_cwd, config_dir);
    defer editor.deinit();
}

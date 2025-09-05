const std = @import("std");
const edit = @import("../editor.zig");
const Editor = edit.Context;
const vpk = @import("../vpk.zig");
const ecs = @import("../ecs.zig");

test "editor init" {
    const Conf = @import("../config.zig");
    const graph = @import("graph");
    const app = @import("../app.zig");
    const actions = @import("../actions.zig");
    const Vec3 = graph.za.Vec3;
    const IS_DEBUG = false;

    const alloc = std.testing.allocator;

    var conf = try Conf.loadConfig(alloc, @embedFile("../default_config.vdf"));
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
    win.pumpEvents(.poll);

    try editor.setMapName("testmap");

    try editor.initNewMap("");

    try editor.update(&win);
    const a = actions;
    const tid = 0;

    const cube1 = try actions.createCube(editor, Vec3.new(0, 0, 0), Vec3.new(1, 1, 1), 0, false);
    try expectMeshMapContains(editor, 0, cube1); //Cube is drawn

    {
        //hide delete unhide -> should still exist
        const cube2 = try actions.createCube(editor, Vec3.new(1, 1, 1), Vec3.new(1, 1, 1), 0, false);
        try expectMeshMapContains(editor, 0, cube2);
        try a.selectId(editor, cube2);
        try a.hideSelected(editor);
        try a.deleteSelected(editor);
        try a.unhideAll(editor);

        try expectMeshMapContains(editor, 0, cube2);
        if (try editor.ecs.hasComponent(cube2, .deleted)) return error.deletion;
    }

    { //Bug 5: unhide causing deleted entities to reenter meshmap
        const cu = try actions.createCube(editor, Vec3.new(1, 1, 1), Vec3.new(1, 1, 1), tid, false);
        try a.selectId(editor, cu);
        try a.deleteSelected(editor);
        try a.unhideAll(editor);
        if (expectMeshMapContains(editor, tid, cu)) {
            return error.deletedUnhidden;
        } else |_| {}
    }

    { //BUG -> grouped entity marquee selection, even odd selection

        a.clearSelection(editor);
        editor.selection.setToMulti();
        const cu1 = try actions.createCube(editor, Vec3.new(1, 1, 1), Vec3.new(1, 1, 1), tid, false);
        const cu2 = try actions.createCube(editor, Vec3.new(3, 1, 1), Vec3.new(1, 1, 1), tid, false);
        try a.selectId(editor, cu1);
        try a.selectId(editor, cu2);

        try std.testing.expectEqual(2, editor.selection.getSlice().len);
        try a.groupSelection(editor);
        a.clearSelection(editor);
        editor.selection.mode = .one;

        if (!try editor.ecs.hasComponent(cu1, .group)) return error.noGroup;
        if (!try editor.ecs.hasComponent(cu2, .group)) return error.noGroup;

        _ = try editor.selection.put(cu1, editor);
        const sl = editor.selection.getSlice();

        try std.testing.expectEqual(2, sl.len);
        for (sl) |item|
            if (item != cu1 and item != cu2) return error.invalidSelection;
    }
}

fn expectMeshMapContains(ed: *Editor, id: vpk.VpkResId, ent_id: ecs.EcsT.Id) !void {
    const mb = ed.meshmap.get(id) orelse return error.noMeshMap;
    _ = mb.contains.get(ent_id) orelse return error.meshMapDoesNotContain;
}

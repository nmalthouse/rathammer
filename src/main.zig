const std = @import("std");
const builtin = @import("builtin");
const IS_DEBUG = builtin.mode == .Debug;
const util = @import("util.zig");
const colors = @import("colors.zig").colors;
const app = @import("app.zig");

const graph = @import("graph");
const Rec = graph.Rec;
const Vec2f = graph.Vec2f;
const V3f = graph.za.Vec3;
const vpk = @import("vpk.zig");
const edit = @import("editor.zig");
const Editor = @import("editor.zig").Context;
const Vec3 = V3f;
const Gui = graph.Gui;
const editor_view = @import("editor_views.zig");
const G = graph.RGui;
const ConfigCheckWindow = @import("windows/config_check.zig").ConfigCheck;
const NagWindow = @import("windows/savenag.zig").NagWindow;
const PauseWindow = @import("windows/pause.zig").PauseWindow;
const ConsoleWindow = @import("windows/console.zig").Console;
const InspectorWindow = @import("windows/inspector.zig").InspectorWindow;
const AssetBrowser = @import("windows/asset.zig");
const MenuBar = @import("windows/menubar.zig").MenuBar;
const Ctx2dView = @import("view_2d.zig").Ctx2dView;
const json_map = @import("json_map.zig");
const fs = @import("fs.zig");
const profile = @import("profile.zig").BasicProfiler;
const async = @import("async.zig");

const build_config = @import("config");
const Conf = @import("config.zig");
const version = @import("version.zig");

const log = std.log.scoped(.app);
pub fn wrappedMain(alloc: std.mem.Allocator, args: anytype) !void {
    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();

    var cwd = try fs.WrappedDir.cwd(alloc);
    defer cwd.free(alloc);
    var app_cwd = try fs.openAppCwd(&env, cwd, alloc);
    defer app_cwd.close(alloc);

    const config_dir = try fs.openXdgDir(alloc, cwd, app_cwd, args.config, &env, "XDG_CONFIG_DIR");
    defer config_dir.free(alloc);
    // if user has specified a config, don't copy
    const copy_default_config = args.config == null;
    const config_name = args.config orelse "config.json";
    if (config_dir.dir.openFile(config_name, .{})) |f| {
        f.close();
    } else |_| {
        if (copy_default_config) {
            log.info("config.json not found in config dir, copying default", .{});
            { //write out default json
                var out = try config_dir.dir.createFile("config.json", .{});
                defer out.close();
                var out_buf: [1024]u8 = undefined;
                var out_wr = out.writer(&out_buf);
                defer out_wr.interface.flush() catch {};
                try std.json.Stringify.value(Conf.Config{}, .{ .whitespace = .indent_2 }, &out_wr.interface);
            }

            const games_config_dir = try config_dir.dir.makeOpenPath("games", .{});

            const default_games_config = try app_cwd.dir.openDir("games", .{ .iterate = true });
            var walker = try default_games_config.walk(alloc);
            defer walker.deinit();

            //TODO if games contains sub dirs, files are flattened
            while (try walker.next()) |item| {
                switch (item.kind) {
                    else => {},
                    .file => {
                        try item.dir.copyFile(item.basename, games_config_dir, item.basename, .{});
                    },
                }
            }
        } else {
            log.err("Failed to open custom config {s}", .{config_name});
            return error.failedConfig;
        }
    }

    if (config_dir.dir.openDir("games", .{ .iterate = true })) |game_dir| {
        _ = game_dir;
    } else |_| {}

    const load_timer = try std.time.Timer.start();
    var loaded_config = Conf.loadConfigFromFile(alloc, config_dir.dir, config_name) catch |err| {
        log.err("User config failed to load with error {t}", .{err});
        return error.failedConfig;
    };
    defer loaded_config.deinit();
    loaded_config.loadLooseGameConfigs(config_dir.dir, "games") catch |err| {
        switch (err) {
            else => return err,
            error.FileNotFound => {},
        }
    };
    const config = loaded_config.config;

    if (config.default_game.len == 0) {
        std.debug.print("config.vdf must specify a default_game!\n", .{});
        return error.incompleteConfig;
    }
    const game_name = args.game orelse config.default_game;
    const game_conf = loaded_config.games.get(game_name) orelse {
        std.debug.print("{s} is not defined in the \"games\" section\n", .{game_name});
        return error.gameConfigNotFound;
    };

    var stdout_buf: [128]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const default_game = args.game orelse config.default_game;
    if (args.games != null or args.checkhealth != null) {
        const sep = "------\n";

        const default_string = "default -> ";
        const default_pad = " " ** default_string.len;

        {
            try stdout.print("Available game configs: \n", .{});
            var it = loaded_config.games.iterator();
            while (it.next()) |item| {
                try stdout.print("{s}{s}\n", .{
                    if (std.mem.eql(u8, item.key_ptr.*, default_game)) default_string else default_pad,
                    item.key_ptr.*,
                });
            }
        }
        if (!loaded_config.games.contains(default_game)) try stdout.print("{s} is not a defined game", .{default_game});
        try stdout.writeAll(sep);
        try stdout.print("App dir    : {s}\n", .{app_cwd.path});
        try stdout.print("Config dir : {s}\n", .{config_dir.path});
    }

    var dirs = try fs.Dirs.open(alloc, cwd, .{
        .config_dir = config_dir,
        .app_cwd = app_cwd,
        .override_games_dir = args.custom_cwd,
        .config_steam_dir = config.paths.steam_dir,
        .override_fgd_dir = args.fgddir,
        .config_fgd_dir = game_conf.fgd_dir, //TODO
    }, &env);
    defer dirs.deinit(alloc);

    var gapp = try G.app.GuiApp.initDefault(alloc, .{
        .window_title = "Rat Hammer",
        .window_opts = .{
            .window_size = .{ .x = config.window.width_px, .y = config.window.height_px },
            .frame_sync = if (args.novsync != null) .immediate else .adaptive_vsync,
            .gl_major_version = 4,
            .gl_minor_version = 5,
            .enable_debug = IS_DEBUG,
            .gl_flags = if (IS_DEBUG) &[_]u32{graph.c.SDL_GL_CONTEXT_DEBUG_FLAG} else &[_]u32{},
        },
        .display_scale = args.display_scale orelse if (config.window.display_scale > 0) config.window.display_scale else null,
        .item_height = args.gui_item_height,
        .font_size = args.gui_font_size,
        .gui_scale = args.gui_scale,
    });
    defer gapp.deinit();

    loaded_config.binds = try Conf.registerBindIds(Conf.Keys, &gapp.main_window.bindreg, config.keys);

    if (!graph.SDL.Window.glHasExtension("GL_EXT_texture_compression_s3tc")) return error.glMissingExt;
    var basic_prof = profile.init();
    basic_prof.start();
    const splash = graph.Texture.initFromImgFile(alloc, app_cwd.dir, "ratasset/small.png", .{}) catch edit.missingTexture();

    var loadctx = edit.LoadCtx{ .opt = .{
        .draw = &gapp.drawctx,
        .font = &gapp.font.font,
        .win = &gapp.main_window,
        .splash = splash,
        .timer = try std.time.Timer.start(),
        .gtimer = load_timer,
        .expected_cb = 100,
    } };
    basic_prof.end();
    basic_prof.log("draw init");

    var edit_prof = profile.init();
    edit_prof.start();

    var editor = try Editor.init(
        alloc,
        if (args.nthread) |nt| @intFromFloat(nt) else null,
        loaded_config,
        args,
        &loadctx,
        dirs,
        gapp,
    );
    defer editor.deinit();
    edit_prof.end();
    edit_prof.log("edit init");

    try gapp.registerUpdateVt(&editor.app_update);

    loadctx.cb("Loading gui");
    var gui_prof = profile.init();
    gui_prof.start();
    const gui = &gapp.gui;
    //gui.dstate.nstyle.color = G.DarkColorscheme;
    const default_rect = Rec(0, 0, 1000, 1000);
    const inspector_win = InspectorWindow.create(gui, editor);
    const pause_win = try PauseWindow.create(gui, editor, app_cwd.dir);
    const pause_win_id = try gui.addWindow(&pause_win.vt, default_rect, .{});

    const console_win = try ConsoleWindow.create(gui, editor, &editor.shell.iconsole);
    const console_id = try gui.addWindow(&console_win.vt, default_rect, .{});
    if (builtin.target.os.tag == .linux) {
        try console_win.printLine("On linux, you have to install the game with proton first and copy the bin folder to BIN\ncd Half-Life 2; cp -r bin BIN\n", .{});
    }
    try console_win.printLine("steam_path {s}\nconfig_path {s}\n", .{
        dirs.games_dir.path,
        config_dir.path,
    });
    for (editor.games.list.values()) |game| {
        if (game.good) continue;
        try console_win.printLine("{s}: {s}\n", .{ game.name, game.reason });
    }

    const inspector_pane = try gui.addWindow(&inspector_win.vt, default_rect, .{});
    const model_browse = try AssetBrowser.ModelBrowser.create(gui, editor);
    const asset_win = try AssetBrowser.AssetBrowser.create(gui, editor, model_browse);
    const asset_pane = try gui.addWindow(&asset_win.vt, default_rect, .{});
    const model_win = try gui.addWindow(&model_browse.vt, default_rect, .{});
    const model_prev_win = try AssetBrowser.ModelPreview.create(editor, gui, &gapp.drawctx);
    const model_prev = try gui.addWindow(model_prev_win, default_rect, .{});

    const menu_bar = try gui.addWindow(try MenuBar.create(gui, editor), default_rect, .{});

    const main_2d_0 = try Ctx2dView.create(editor, gui, &gapp.drawctx, .y);
    const main_2d_1 = try Ctx2dView.create(editor, gui, &gapp.drawctx, .x);
    const main_2d_2 = try Ctx2dView.create(editor, gui, &gapp.drawctx, .z);

    const main_2d_id = try gui.addWindow(main_2d_0, .Empty, .{ .put_fbo = false });
    const main_2d_id2 = try gui.addWindow(main_2d_1, .Empty, .{ .put_fbo = false });
    const main_2d_id3 = try gui.addWindow(main_2d_2, .Empty, .{ .put_fbo = false });

    gui_prof.end();
    gui_prof.log("gui init");

    if (args.map == null) { //Only build the recents list if we don't have a map
        var recent_prof = profile.init();
        recent_prof.start();
        if (util.readFile(alloc, config_dir.dir, "recent_maps.txt")) |slice| {
            defer alloc.free(slice);
            try pause_win.buildRecentList(slice, args.game orelse config.default_game);
        } else |_| {
            log.err("failed to open recent_maps.txt", .{});
        }

        recent_prof.end();
        recent_prof.log("recent build");
    }

    const main_3d_view = try editor_view.Main3DView.create(editor, gui, &gapp.drawctx);
    const main_3d_id = try gui.addWindow(main_3d_view, .Empty, .{ .put_fbo = false });
    editor.workspaces.main_3d_win = main_3d_id;
    editor.workspaces.inspector = inspector_pane;
    { //Set up key contexts
        inspector_win.vt.key_ctx_mask = .empty;
        main_3d_view.key_ctx_mask.setValue(loaded_config.binds.view3d.context_id, true);
        main_3d_view.key_ctx_mask.setValue(loaded_config.binds.tool.context_id, true);

        model_prev_win.key_ctx_mask.setValue(loaded_config.binds.view3d.context_id, true);

        main_2d_0.key_ctx_mask.setValue(loaded_config.binds.view2d.context_id, true);
        main_2d_1.key_ctx_mask.setValue(loaded_config.binds.view2d.context_id, true);
        main_2d_2.key_ctx_mask.setValue(loaded_config.binds.view2d.context_id, true);

        main_2d_0.key_ctx_mask.setValue(loaded_config.binds.tool.context_id, true);
        main_2d_1.key_ctx_mask.setValue(loaded_config.binds.tool.context_id, true);
        main_2d_2.key_ctx_mask.setValue(loaded_config.binds.tool.context_id, true);

        gui.key_ctx_mask.setValue(loaded_config.binds.global.context_id, true);
    }

    loadctx.cb("Loading");

    loadctx.cb("Vpk's mounted");

    vpk.timer.log("Vpk dir");

    editor.draw_state.cam3d.fov = config.window.cam_fov;
    loadctx.setTime();

    if (args.blank) |blank| {
        try editor.setMapName(blank);
        try editor.initNewMap("sky_day01_01", args.game orelse editor.config.default_game);
    } else {
        if (args.map) |mapname| {
            try editor.loadMap(app_cwd.dir, mapname, &loadctx, args.game orelse editor.config.default_game);
        }
    }

    //TODO with assets loaded dynamically, names might not be correct when saving before all loaded
    loadctx.setTime();

    graph.gl.Enable(graph.gl.CULL_FACE);
    graph.gl.CullFace(graph.gl.BACK);

    editor.workspaces.main_2d = try gapp.workspaces.addWorkspace(.{ .split = .{ .orientation = .horizontal } });
    {
        const ih = gui.dstate.nstyle.item_h;
        var wsp = &(gapp.workspaces.getWorkspace(editor.workspaces.main_2d) orelse return error.fucked).pane;
        try wsp.split.append(gapp.workspaces.alloc, .{
            .window = .{ .id = menu_bar, .max_width = ih, .min_width = ih },
        });
        try wsp.split.append(gapp.workspaces.alloc, .{ .split = .{ .orientation = .vertical } });

        wsp = &wsp.split.children.items[wsp.split.children.items.len - 1];
        try wsp.split.append(gapp.workspaces.alloc, .{ .split = .{ .orientation = .horizontal } });
        try wsp.split.append(gapp.workspaces.alloc, .{ .split = .{ .orientation = .horizontal } });
        try wsp.split.append(gapp.workspaces.alloc, .{ .window = .{ .id = inspector_pane, .min_width = ih } });
        wsp.split.area = .{ .x1 = 1000, .y1 = 1000 };
        try wsp.split.handles.append(gapp.workspaces.alloc, 330);
        try wsp.split.handles.append(gapp.workspaces.alloc, 660);

        const wsm0 = &wsp.split.children.items[0];
        try wsm0.split.append(gapp.workspaces.alloc, .{ .window = .{ .id = main_3d_id } });
        try wsm0.split.append(gapp.workspaces.alloc, .{ .window = .{ .id = main_2d_id3 } });

        const wsm1 = &wsp.split.children.items[1];
        try wsm1.split.append(gapp.workspaces.alloc, .{ .window = .{ .id = main_2d_id } });
        try wsm1.split.append(gapp.workspaces.alloc, .{ .window = .{ .id = main_2d_id2 } });
    }

    editor.workspaces.main = try gapp.workspaces.addWorkspace(.{ .split = .{ .orientation = .horizontal } });
    {
        const ih = gui.dstate.nstyle.item_h;
        var wsp = &(gapp.workspaces.getWorkspace(editor.workspaces.main) orelse return error.fucked).pane;
        try wsp.split.append(gapp.workspaces.alloc, .{
            .window = .{ .id = menu_bar, .max_width = ih, .min_width = ih },
        });
        try wsp.split.append(gapp.workspaces.alloc, .{ .split = .{ .orientation = .vertical } });

        wsp = &wsp.split.children.items[wsp.split.children.items.len - 1];
        try wsp.split.append(gapp.workspaces.alloc, .{ .window = .{ .id = main_3d_id, .min_width = ih } });
        try wsp.split.append(gapp.workspaces.alloc, .{ .window = .{ .id = inspector_pane, .min_width = ih } });
        wsp.split.area = .{ .x1 = 1000, .y1 = 1000 };
        try wsp.split.handles.append(gapp.workspaces.alloc, 670);
    }

    editor.workspaces.pause = try gapp.workspaces.addWorkspace(.{ .split = .{ .orientation = .vertical } });
    gapp.workspaces.active_ws = editor.workspaces.pause;
    editor.workspaces.pre_pause = editor.workspaces.main;
    {
        const ih = gui.dstate.nstyle.item_h;
        var wsp = &(gapp.workspaces.getWorkspace(editor.workspaces.pause) orelse return error.fucked).pane;
        try wsp.split.append(gapp.workspaces.alloc, .{ .window = .{ .id = console_id, .min_width = ih } });
        try wsp.split.append(gapp.workspaces.alloc, .{ .window = .{ .id = pause_win_id, .min_width = ih } });
        wsp.split.area = .{ .x1 = 1000, .y1 = 1000 };
        try wsp.split.handles.append(gapp.workspaces.alloc, 670);
    }

    editor.workspaces.asset = try gapp.workspaces.addWorkspace(.{ .split = .{ .orientation = .horizontal } });
    {
        const ih = gui.dstate.nstyle.item_h;
        var wsp = &(gapp.workspaces.getWorkspace(editor.workspaces.asset) orelse return error.fucked).pane;
        try wsp.split.append(gapp.workspaces.alloc, .{
            .window = .{ .id = menu_bar, .max_width = ih, .min_width = ih },
        });
        //try wsp.split.append(gapp.workspaces.alloc, .{ .split = .{ .orientation = .vertical } });
        try wsp.split.append(gapp.workspaces.alloc, .{ .window = .{ .id = asset_pane, .min_width = ih } });

        //wsp = &wsp.split.children.items[wsp.split.children.items.len - 1];
    }

    editor.workspaces.model = try gapp.workspaces.addWorkspace(.{ .split = .{ .orientation = .horizontal } });
    {
        const ih = gui.dstate.nstyle.item_h;
        var wsp = &(gapp.workspaces.getWorkspace(editor.workspaces.model) orelse return error.fucked).pane;
        try wsp.split.append(gapp.workspaces.alloc, .{
            .window = .{ .id = menu_bar, .max_width = ih, .min_width = ih },
        });
        try wsp.split.append(gapp.workspaces.alloc, .{ .split = .{ .orientation = .vertical } });

        wsp = &wsp.split.children.items[wsp.split.children.items.len - 1];
        //var wsp = &(gapp.workspaces.getWorkspace(editor.workspaces.model) orelse return error.fucked).pane;
        try wsp.split.append(gapp.workspaces.alloc, .{ .window = .{ .id = model_win, .min_width = ih } });
        try wsp.split.append(gapp.workspaces.alloc, .{ .window = .{ .id = model_prev, .min_width = ih } });
    }

    while (true) {
        try gapp.run();
        if (editor.should_exit) break;
        if (editor.isUnsaved()) {
            gapp.main_window.should_exit = false;
            try NagWindow.makeTransientWindow(&gapp.gui, editor, .quit);
        } else {
            break;
        }
    }

    //DON'T clean exit. We need editor.deinit to get called so the thread pool is deinit
    //std.process.cleanExit();
}

pub fn main() !void {
    var total_app_profile = profile.init();
    total_app_profile.start();
    defer total_app_profile.log("app lifetime");
    defer total_app_profile.end();
    var gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = build_config.stack_trace_frames }){};

    {
        const alloc = if (IS_DEBUG) gpa.allocator() else std.heap.smp_allocator;

        var arg_it = try std.process.argsWithAllocator(alloc);
        defer arg_it.deinit();
        const exe_name = arg_it.next() orelse return error.invalidArgIt;
        _ = exe_name;
        var stdout_buf: [128]u8 = undefined;

        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        const out = &stdout_writer.interface;
        defer out.flush() catch {};
        const args = try graph.ArgGen.parseArgs(&app.Args, &arg_it);
        if (args.version != null) {
            try out.print("{s}\n", .{version.version});
            return;
        }

        if (args.dump_lang != null) {
            try @import("locale.zig").writeJsonTemplate(std.fs.cwd(), "en_US.json");
            try @import("locale.zig").writeCsv(out);
            return;
        }

        var locale: ?std.json.Parsed(@import("locale.zig").Strings) = null;
        if (args.lang) |lang_path| {
            locale = try @import("locale.zig").initJsonFile(std.fs.cwd(), lang_path, alloc);
            @import("locale.zig").lang = &locale.?.value;
        }
        defer {
            if (locale) |l|
                l.deinit();
        }

        if (args.build != null) {
            try std.json.Stringify.value(.{
                .version = version.version,
                .os = builtin.target.os.tag,
                .arch = builtin.target.cpu.arch,
                .mode = builtin.mode,
                .commit = build_config.commit_hash,
            }, .{ .whitespace = .indent_2 }, out);
            out.print("\n", .{}) catch {}; //Json doesn't emit final \n
            return;
        }

        try wrappedMain(alloc, args);
        //TODO we need to wait for async save threads to join!!!!

    }
    // if the application is quit while items are being loaded in the thread pool, we get spammed with memory leaks.
    // There is no benefit to ensuring those items are free'd on exit.
    if (IS_DEBUG)
        _ = gpa.detectLeaks(); // Not deferred, so on error there isn't spam
}

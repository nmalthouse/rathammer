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
const Split = @import("splitter.zig");
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

// Event system?
// events gui needs to be aware of
// selection changed
// tool changed
// something undone

pub fn dpiDetect(win: *graph.SDL.Window) !f32 {
    const sc = graph.c.SDL_GetWindowDisplayScale(win.win);
    if (sc == 0)
        return error.sdl;
    return sc;
}

pub fn pauseLoop(win: *graph.SDL.Window, draw: *graph.ImmediateDrawingContext, win_vt: *G.iWindow, gui: *G.Gui, loadctx: *edit.LoadCtx, editor: *Editor, should_exit: bool, console: *ConsoleWindow, rising: bool) !enum { cont, exit, unpause } {
    if (!editor.paused)
        return .unpause;
    if (win.isBindState(editor.conf.binds.global.quit, .rising) or should_exit)
        return .exit;
    win.pumpEvents(.wait);
    win.grabMouse(false);
    try draw.begin(colors.clear, win.screen_dimensions.toF());
    draw.real_screen_dimensions = win.screen_dimensions.toF();
    try editor.update(win);

    {
        const max_w = gui.dstate.nstyle.item_h * 30;
        const area = graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y);
        const w = @min(max_w, area.w);
        const side_l = (area.w - w);
        const sp = area.split(.vertical, side_l);
        const win_rect = sp[1];
        const other_rect = sp[0];
        try gui.pre_update();
        gui.active_windows.clearRetainingCapacity();
        try gui.active_windows.append(gui.alloc, win_vt);
        if (other_rect.w > 0)
            try gui.active_windows.append(gui.alloc, &console.vt);
        if (rising) {
            console.focus(gui);
        }
        if (other_rect.w > 0)
            try gui.updateWindowSize(&console.vt, other_rect);
        try gui.updateWindowSize(win_vt, win_rect);
        try gui.update();
        try gui.draw(false);
        gui.drawFbos();
    }
    try draw.flush(null, null);
    try loadctx.loadedSplash();

    try draw.end(editor.draw_state.cam3d);
    win.swap();
    return .cont;
}
pub var INSPECTOR: *InspectorWindow = undefined;

var font: graph.OnlineFont = undefined;
fn flush_cb(_: ?*anyopaque) void {
    font.syncBitmapToGL();
}

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

    var win = try graph.SDL.Window.createWindow("Rat Hammer", .{
        .window_size = .{ .x = config.window.width_px, .y = config.window.height_px },
        .frame_sync = if (args.novsync != null) .immediate else .adaptive_vsync,
        .gl_major_version = 4,
        .gl_minor_version = 5,
        .enable_debug = IS_DEBUG,
        .gl_flags = if (IS_DEBUG) &[_]u32{graph.c.SDL_GL_CONTEXT_DEBUG_FLAG} else &[_]u32{},
    }, alloc);
    defer win.destroyWindow();

    loaded_config.binds = try Conf.registerBindIds(Conf.Keys, &win.bindreg, config.keys);
    win.bindreg.enableAll(true);

    _ = graph.c.SDL_SetWindowMinimumSize(win.win, 800, 600);

    const Preset = struct {
        dpi: f32 = 1,
        fh: f32 = 25,
        ih: f32 = 14,
        scale: f32 = 2,

        pub fn distance(_: void, item: @This(), key: @This()) f32 {
            return @abs(item.dpi - key.dpi);
        }
    };

    const DPI_presets = [_]Preset{
        .{ .dpi = 1, .fh = 14, .ih = 25, .scale = 1 },
        .{ .dpi = 1.7, .fh = 18, .ih = 28, .scale = 1 },
    };
    const config_display_scale = if (config.window.display_scale > 0) config.window.display_scale else null;
    const sc = args.display_scale orelse config_display_scale orelse try dpiDetect(&win);
    edit.log.info("Detected a display scale of {d}", .{sc});
    const dpi_preset = blk: {
        const default_scaled = Preset{ .fh = 20 * sc, .ih = 25 * sc, .scale = 1 };
        const max_dpi_diff = 0.3;
        const index = util.nearest(Preset, &DPI_presets, {}, Preset.distance, .{ .dpi = sc }) orelse break :blk default_scaled;
        const p = DPI_presets[index];
        if (@abs(p.dpi - sc) > max_dpi_diff)
            break :blk default_scaled;
        edit.log.info("Matching dpi preset number: {d}, display scale: {d}, font_height {d}, item_height {d},", .{ index, p.dpi, p.fh, p.ih });
        break :blk p;
    };

    const scaled_item_height = args.gui_item_height orelse @trunc(dpi_preset.ih);
    const scaled_text_height = args.gui_font_size orelse @trunc(dpi_preset.fh);
    const gui_scale = args.gui_scale orelse dpi_preset.scale;
    edit.log.info("gui Size, text: {d} item: {d} ", .{ scaled_text_height, scaled_item_height });

    if (!graph.SDL.Window.glHasExtension("GL_EXT_texture_compression_s3tc")) return error.glMissingExt;
    var basic_prof = profile.init();
    basic_prof.start();
    var draw = graph.ImmediateDrawingContext.init(alloc);
    defer draw.deinit();

    font = try graph.OnlineFont.init(alloc, app_cwd.dir, args.fontfile orelse "ratasset/roboto.ttf", scaled_text_height, .{});

    draw.preflush_cb = flush_cb;

    defer font.deinit();
    const splash = graph.Texture.initFromImgFile(alloc, app_cwd.dir, "ratasset/small.png", .{}) catch edit.missingTexture();

    var loadctx = edit.LoadCtx{ .opt = .{
        .draw = &draw,
        .font = &font.font,
        .win = &win,
        .splash = splash,
        .timer = try std.time.Timer.start(),
        .gtimer = load_timer,
        .expected_cb = 100,
    } };
    basic_prof.end();
    basic_prof.log("draw init");

    var edit_prof = profile.init();
    edit_prof.start();

    var editor = try Editor.init(alloc, if (args.nthread) |nt| @intFromFloat(nt) else null, loaded_config, args, &win, &loadctx, dirs);
    defer editor.deinit();
    edit_prof.end();
    edit_prof.log("edit init");

    loadctx.cb("Loading gui");
    var gui_prof = profile.init();
    gui_prof.start();
    var gui = try G.Gui.init(alloc, &win, &font.font, &draw);
    defer gui.deinit();
    gui.dstate.nstyle.item_h = scaled_item_height;
    gui.dstate.nstyle.text_h = scaled_text_height;
    gui.dstate.scale = gui_scale;
    gui.dstate.tint = config.gui_tint;
    //gui.dstate.nstyle.color = G.DarkColorscheme;
    const default_rect = Rec(0, 0, 1000, 1000);
    const inspector_win = InspectorWindow.create(&gui, editor);
    INSPECTOR = inspector_win;
    const pause_win = try PauseWindow.create(&gui, editor, app_cwd.dir);
    _ = try gui.addWindow(&pause_win.vt, default_rect, .{});

    const console_win = try ConsoleWindow.create(&gui, editor, &editor.shell.iconsole);
    _ = try gui.addWindow(&console_win.vt, default_rect, .{});
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
    const nag_win = try NagWindow.create(&gui, editor);
    _ = try gui.addWindow(&nag_win.vt, default_rect, .{});
    const model_browse = try AssetBrowser.ModelBrowser.create(&gui, editor);
    const asset_win = try AssetBrowser.AssetBrowser.create(&gui, editor, model_browse);
    const asset_pane = try gui.addWindow(&asset_win.vt, default_rect, .{});
    const model_win = try gui.addWindow(&model_browse.vt, default_rect, .{});
    const model_prev = try gui.addWindow(try AssetBrowser.ModelPreview.create(editor, &gui, &draw), default_rect, .{});
    //try asset_win.populate(&editor.vpkctx, game_conf.asset_browser_exclude.prefix, game_conf.asset_browser_exclude.entry.items, model_browse);

    const menu_bar = try gui.addWindow(try MenuBar.create(&gui, editor), default_rect, .{});

    const main_2d_id = try gui.addWindow(try Ctx2dView.create(editor, &gui, &draw, .y), .Empty, .{ .put_fbo = false });
    const main_2d_id2 = try gui.addWindow(try Ctx2dView.create(editor, &gui, &draw, .x), .Empty, .{ .put_fbo = false });
    const main_2d_id3 = try gui.addWindow(try Ctx2dView.create(editor, &gui, &draw, .z), .Empty, .{ .put_fbo = false });

    gui_prof.end();
    gui_prof.log("gui init");

    if (args.map == null) { //Only build the recents list if we don't have a map
        var recent_prof = profile.init();
        recent_prof.start();
        if (util.readFile(alloc, config_dir.dir, "recent_maps.txt")) |slice| {
            defer alloc.free(slice);
            var it = std.mem.tokenizeScalar(u8, slice, '\n');
            while (it.next()) |filename| {
                const EXT = ".ratmap";
                if (std.mem.endsWith(u8, filename, EXT)) {
                    if (std.fs.cwd().openFile(filename, .{})) |recent_map| {
                        defer recent_map.close();
                        const qoi_data = util.getFileFromTar(alloc, recent_map, "thumbnail.qoi") catch continue;

                        const info_data = util.getFileFromTar(alloc, recent_map, "info.json") catch try alloc.alloc(u8, 0);
                        defer alloc.free(info_data);

                        const vpk_id = (editor.vpkctx.getResourceIdFmt("internal", "{s}", .{filename}, false) catch null) orelse {
                            alloc.free(qoi_data);
                            continue;
                        };

                        try editor.materials.put(vpk_id, .default());

                        async.QoiDecode.spawn(alloc, &editor.async_asset_load, qoi_data, vpk_id) catch {
                            alloc.free(qoi_data);
                            continue;
                        };

                        var rec = PauseWindow.Recent{
                            .name = try alloc.dupe(u8, filename[0 .. filename.len - EXT.len]),
                            .tex = vpk_id,
                            .game_config_index = editor.games.id(args.game orelse config.default_game),
                            .description = try alloc.alloc(u8, 0),
                        };
                        if (std.json.parseFromSlice(json_map.JsonInfo, alloc, info_data, .{})) |info| {
                            defer info.deinit();
                            alloc.free(rec.description);
                            rec.description = try alloc.dupe(u8, info.value.description);
                            rec.game_config_index = editor.games.id(info.value.game_config_name);
                        } else |_| {}

                        try pause_win.recents.append(pause_win.alloc, rec);
                    } else |_| {}
                }
            }
        } else |_| {
            log.err("failed to open recent_maps.txt", .{});
        }

        recent_prof.end();
        recent_prof.log("recent build");
    }

    const main_3d_id = try gui.addWindow(try editor_view.Main3DView.create(editor, &gui, &draw), .Empty, .{ .put_fbo = false });

    loadctx.cb("Loading");

    loadctx.cb("Vpk's mounted");

    vpk.timer.log("Vpk dir");

    editor.draw_state.cam3d.fov = config.window.cam_fov;
    loadctx.setTime();

    win.forcePoll(); // ensure first draw is fast on eventWait
    if (args.blank) |blank| {
        try editor.setMapName(blank);
        try editor.initNewMap("sky_day01_01", args.game orelse editor.config.default_game);
    } else {
        if (args.map) |mapname| {
            try editor.loadMap(app_cwd.dir, mapname, &loadctx, args.game orelse editor.config.default_game);
        } else {
            while (!win.should_exit) {
                switch (try pauseLoop(&win, &draw, &pause_win.vt, &gui, &loadctx, editor, pause_win.should_exit, console_win, false)) {
                    .exit => break,
                    .unpause => break,
                    .cont => continue,
                }
            }
        }
    }

    //TODO with assets loaded dynamically, names might not be correct when saving before all loaded
    loadctx.setTime();

    graph.gl.Enable(graph.gl.CULL_FACE);
    graph.gl.CullFace(graph.gl.BACK);

    var ws = Split.Splits.init(alloc);
    defer ws.deinit();
    const main_tab = ws.newArea(.{
        .sub = .{
            .split = .{ .k = .horiz, .pos = gui.dstate.nstyle.item_h, .kind = .abs },

            .left = ws.newArea(.{ .pane = menu_bar }),

            .right = ws.newArea(.{
                .sub = .{
                    .split = .{ .k = .vert, .pos = 0.67 },
                    .left = ws.newArea(.{ .pane = main_3d_id }),
                    .right = ws.newArea(.{ .pane = inspector_pane }),
                },
            }),
        },
    });

    const main_2d_tab = ws.newArea(.{
        .sub = .{
            .split = .{ .k = .vert, .pos = 0.5 },
            .left = ws.newArea(.{ .sub = .{
                .split = .{ .k = .horiz, .pos = 0.5 },
                .left = ws.newArea(.{ .pane = main_3d_id }),
                .right = ws.newArea(.{ .pane = main_2d_id3 }),
            } }),
            .right = ws.newArea(.{ .sub = .{
                .split = .{ .k = .vert, .pos = 0.5 },
                .left = ws.newArea(.{ .sub = .{
                    .split = .{ .k = .horiz, .pos = 0.5 },
                    .left = ws.newArea(.{ .pane = main_2d_id }),
                    .right = ws.newArea(.{ .pane = main_2d_id2 }),
                } }),
                .right = ws.newArea(.{ .pane = inspector_pane }),
            } }),
        },
    });
    try ws.workspaces.append(main_tab);

    try ws.workspaces.append(ws.newArea(.{ .pane = asset_pane }));
    try ws.workspaces.append(ws.newArea(.{
        .sub = .{
            .split = .{ .k = .vert, .pos = 0.4 },
            .left = ws.newArea(.{ .pane = model_win }),
            .right = ws.newArea(.{ .pane = model_prev }),
        },
    }));
    try ws.workspaces.append(main_2d_tab);

    var last_frame_group_owner: ?edit.EcsT.Id = null;

    var frame_timer = try std.time.Timer.start();
    var frame_time: u64 = 0;
    win.grabMouse(true);
    main_loop: while (!win.should_exit) {
        var just_paused = false;
        if (win.isBindState(loaded_config.binds.global.quit, .rising) or pause_win.should_exit)
            break :main_loop;
        if (win.isBindState(loaded_config.binds.global.pause, .rising)) {
            editor.paused = !editor.paused;

            if (editor.paused) { //Always start with it focused
                just_paused = true;
            }
        }

        if (editor.paused) {
            switch (try pauseLoop(&win, &draw, &pause_win.vt, &gui, &loadctx, editor, pause_win.should_exit, console_win, just_paused)) {
                .cont => continue :main_loop,
                .exit => break :main_loop,
                .unpause => editor.paused = false,
            }
        }
        draw.real_screen_dimensions = win.screen_dimensions.toF();

        win.pumpEvents(.poll);
        //POSONE please and thank you.
        frame_time = frame_timer.read();
        frame_timer.reset();
        editor.draw_state.frame_time_ms = @as(f32, @floatFromInt(frame_time)) / std.time.ns_per_ms;

        editor.edit_state.mpos = win.mouse.pos;

        const winrect = graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y);
        gui.clamp_window = winrect;
        graph.gl.Enable(graph.gl.BLEND);
        try editor.update(&win);
        //TODO move this back to POSONE once we can render 3dview to any fb
        //this is here so editor.update can create a thumbnail from backbuffer before its cleared
        try draw.begin(colors.clear, win.screen_dimensions.toF());

        { //Hacks to update gui
            const new_id = editor.selection.getGroupOwnerExclusive(&editor.groups);
            if (new_id != last_frame_group_owner) {
                inspector_win.vt.needs_rebuild = true;
            }
            last_frame_group_owner = new_id;
        }

        ws.doTheSliders(win.mouse.pos, win.mouse.delta, win.mouse.left);
        try ws.setWorkspaceAndArea(editor.draw_state.tab_index, winrect);

        //for (config.keys.inspector_tab.items, 0..) |bind, ind| {
        //    if (ind >= InspectorWindow.tabs.len)
        //        break;

        //    _ = bind;
        //    //if (win.isBindState(bind.b, .rising))
        //    //inspector_win.setTab(ind);
        //}
        editor.handleTabKeys(ws.workspaces.items);

        try gui.pre_update();
        gui.active_windows.clearRetainingCapacity();
        for (ws.getTab()) |out| {
            const pane_area = out[0];
            if (gui.getWindowId(out[1])) |win_vt| {
                try gui.active_windows.append(gui.alloc, win_vt);
                try gui.updateWindowSize(win_vt, pane_area);
            }
        }
        try gui.update();

        try gui.draw(false);
        gui.drawFbos();

        draw.setViewport(null);
        try loadctx.loadedSplash();
        try draw.end(editor.draw_state.cam3d);
        win.swap();
    }
    if (editor.edit_state.saved_at_delta != editor.undoctx.delta_counter) {
        win.should_exit = false;
        win.pumpEvents(.poll); //Clear quit keys
        editor.paused = true; //Needed for pause loop, hacky
        while (!win.should_exit) {
            if (editor.edit_state.saved_at_delta == editor.undoctx.delta_counter) {
                break; //The map has been saved async
            }
            switch (try pauseLoop(&win, &draw, &nag_win.vt, &gui, &loadctx, editor, nag_win.should_exit, console_win, false)) {
                .exit => break,
                .unpause => break,
                .cont => continue,
            }
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

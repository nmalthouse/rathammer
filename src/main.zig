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
const Os9Gui = graph.gui_app.Os9Gui;
const Gui = graph.Gui;
const Split = @import("splitter.zig");
const editor_view = @import("editor_views.zig");
const G = graph.RGui;
const LaunchWindow = @import("windows/launch.zig").LaunchWindow;
const NagWindow = @import("windows/savenag.zig").NagWindow;
const PauseWindow = @import("windows/pause.zig").PauseWindow;
const ConsoleWindow = @import("windows/console.zig").Console;
const InspectorWindow = @import("windows/inspector.zig").InspectorWindow;
const AssetBrowser = @import("windows/asset.zig").AssetBrowser;
const Ctx2dView = @import("view_2d.zig").Ctx2dView;
const panereg = @import("pane.zig");
const json_map = @import("json_map.zig");
const fs = @import("fs.zig");

const build_config = @import("config");
const Conf = @import("config.zig");
const version = @import("version.zig");

// Event system?
// events gui needs to be aware of
// selection changed
// tool changed
// something undone

fn event_cb(ev: graph.c.SDL_UserEvent) void {
    const rpc = @import("rpc.zig");
    const ha = std.hash.Wyhash.hash;
    const ed: *Editor = @alignCast(@ptrCast(ev.data1 orelse return));
    const this_id = ed.rpcserv.event_id;
    if (ev.type == this_id) {
        if (ev.data2) |us1| {
            const event: *rpc.Event = @alignCast(@ptrCast(us1));
            defer event.deinit(ed.rpcserv.alloc);
            for (event.msg) |msg| {
                var wr = event.stream.writer();
                switch (ha(0, msg.method)) {
                    ha(0, "pause") => {
                        ed.paused = !ed.paused;
                        ed.rpcserv.respond(wr, .{
                            .id = msg.id,
                            .result = .{ .null = {} },
                        }) catch {};
                    },
                    ha(0, "select_class") => {},
                    else => {
                        wr.print("Fuked dude, wrong method\n", .{}) catch {};
                    },
                }
            }
        }
    } else {
        std.debug.print("Unknown event: {d}\n", .{ev.type});
    }
}

//Deprecate this please
//wrapper to make the old gui stuff work with pane reg
//singleton on kind
pub const OldGuiPane = struct {
    const Self = @This();
    const guis = graph.RGui;
    const Gui = guis.Gui;

    const Kind = enum {
        texture,
        model,
        model_view,
    };

    vt: panereg.iPane,

    editor: *Editor,
    os9gui: *Os9Gui,
    kind: Kind,

    pub fn create(alloc: std.mem.Allocator, ed: *Editor, kind: Kind, os9gui: *Os9Gui) !*panereg.iPane {
        var ret = try alloc.create(@This());
        ret.* = .{
            .vt = .{
                .deinit_fn = &deinit,
                .draw_fn = &draw_fn,
            },
            .kind = kind,
            .os9gui = os9gui,
            .editor = ed,
        };
        return &ret.vt;
    }

    pub fn draw_fn(vt: *panereg.iPane, pane_area: graph.Rect, editor: *Editor, vd: panereg.ViewDrawState, pane_id: panereg.PaneId) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (self.kind) {
            .model => {
                editor.asset_browser.drawEditWindow(pane_area, self.os9gui, editor, .model) catch return;
            },
            .texture => {
                editor.asset_browser.drawEditWindow(pane_area, self.os9gui, editor, .texture) catch return;
            },
            .model_view => {
                _ = editor.panes.grab.trySetGrab(pane_id, editor.win.mouse.left == .high);
                editor.asset_browser.drawModelPreview(
                    editor.win,
                    pane_area,
                    vd.camstate,
                    editor,
                    vd.draw,
                ) catch return;
            },
        }
    }

    pub fn deinit(vt: *panereg.iPane, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

pub fn dpiDetect(win: *graph.SDL.Window) !f32 {
    const sc = graph.c.SDL_GetWindowDisplayScale(win.win);
    if (sc == 0)
        return error.sdl;
    return sc;
}

var font_ptr: ?*graph.OnlineFont = null;
fn flush_cb() void {
    if (font_ptr) |fp|
        fp.syncBitmapToGL();
}

pub fn pauseLoop(win: *graph.SDL.Window, draw: *graph.ImmediateDrawingContext, win_vt: *G.iWindow, gui: *G.Gui, gui_dstate: G.DrawState, loadctx: *edit.LoadCtx, editor: *Editor, should_exit: bool) !enum { cont, exit, unpause } {
    if (!editor.paused)
        return .unpause;
    if (win.isBindState(editor.config.keys.quit.b, .rising) or should_exit)
        return .exit;
    win.pumpEvents(.wait);
    win.grabMouse(false);
    try draw.begin(colors.clear, win.screen_dimensions.toF());
    draw.real_screen_dimensions = win.screen_dimensions.toF();
    try editor.update(win);

    {
        const max_w = gui.style.config.default_item_h * 30;
        const area = graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y);
        const w = @min(max_w, area.w);
        const side_l = (area.w - w);
        const winrect = area.replace(side_l, null, w, null);
        const wins = &.{win_vt};
        try gui.pre_update(wins);
        try gui.updateWindowSize(win_vt, winrect);
        try gui.update(wins);
        try gui.draw(gui_dstate, false, wins);
        gui.drawFbos(draw, wins);
    }
    try draw.flush(null, null);
    try loadctx.loadedSplash(win.keys.len > 0);

    try draw.end(editor.draw_state.cam3d);
    win.swap();
    return .cont;
}

const log = std.log.scoped(.app);
pub fn wrappedMain(alloc: std.mem.Allocator, args: anytype) !void {
    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();

    var cwd = try fs.WrappedDir.cwd(alloc);
    defer cwd.free(alloc);
    var app_cwd = try fs.openAppCwd(&env, cwd, alloc);
    defer app_cwd.close(alloc);

    const config_dir = try fs.openConfigDir(alloc, cwd, app_cwd, args.config, &env);
    defer config_dir.free(alloc);
    // if user has specified a config, don't copy
    const copy_default_config = args.config == null;
    const config_name = args.config orelse "config.vdf";
    if (config_dir.dir.openFile(config_name, .{})) |f| {
        f.close();
    } else |_| {
        if (copy_default_config) {
            log.info("config.vdf not found in config dir, copying default", .{});
            try app_cwd.dir.copyFile("config.vdf", config_dir.dir, "config.vdf", .{});

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
        log.err("User config failed to load with error {!}", .{err});
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
    const game_conf = config.games.map.get(game_name) orelse {
        std.debug.print("{s} is not defined in the \"games\" section\n", .{game_name});
        return error.gameConfigNotFound;
    };

    const default_game = args.game orelse config.default_game;
    if (args.games != null or args.checkhealth != null) {
        const out = std.io.getStdOut();
        const wr = out.writer();
        const sep = "------\n";

        const default_string = "default -> ";
        const default_pad = " " ** default_string.len;

        {
            try wr.print("Available game configs: \n", .{});
            var it = config.games.map.iterator();
            while (it.next()) |item| {
                try wr.print("{s}{s}\n", .{
                    if (std.mem.eql(u8, item.key_ptr.*, default_game)) default_string else default_pad,
                    item.key_ptr.*,
                });
            }
        }
        if (!config.games.map.contains(default_game)) try wr.print("{s} is not a defined game", .{default_game});
        try wr.writeAll(sep);
        try wr.print("App dir    : {s}\n", .{app_cwd.path});
        try wr.print("Config dir : {s}\n", .{config_dir.path});
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

    if (args.games != null or args.checkhealth != null) {
        const out = std.io.getStdOut();
        const wr = out.writer();

        var it = config.games.map.iterator();
        while (it.next()) |item| {
            if (!std.mem.eql(u8, item.key_ptr.*, default_game) and args.checkhealth == null) continue;
            const en = item.value_ptr;
            try wr.print("{s}:\n", .{item.key_ptr.*});
            var failed = false;
            dirs.games_dir.doesFileExistInDir(en.fgd_dir, en.fgd) catch |err| {
                failed = true;
                try wr.print("    fgd: {!}\n", .{err});
                try wr.print("        fgd_dir: {s}\n", .{en.fgd_dir});
                try wr.print("        fgd    : {s}\n", .{en.fgd});
            };
            for (en.gameinfo.items, 0..) |ginfo, i| {
                const name = if (ginfo.gameinfo_name.len > 0) ginfo.gameinfo_name else "gameinfo.txt";

                dirs.games_dir.doesFileExistInDir(ginfo.game_dir, name) catch |err| {
                    failed = true;

                    try wr.print("    gameinfo {d}: {!}\n", .{ i, err });
                    try wr.print("        game_dir: {s}\n", .{ginfo.game_dir});
                    try wr.print("        gameinfo: {s}\n", .{name});
                };
            }
            { //map builder

                const gdir = dirs.games_dir.doesDirExist(en.mapbuilder.game_dir);
                const edir = dirs.games_dir.doesDirExist(en.mapbuilder.exe_dir);
                if (!gdir or !edir) {
                    try wr.print("    mapbuilder: \n", .{});
                    if (!gdir)
                        try wr.print("        game_dir: error.fileNotFound\n", .{});
                    if (!edir)
                        try wr.print("        exe_dir : error.fileNotFound\n", .{});
                }
            }

            if (!failed)
                try wr.print("    good\n", .{});

            try wr.print("\n", .{});
        }

        return;
    }

    var win = try graph.SDL.Window.createWindow("Rat Hammer", .{
        .window_size = .{ .x = config.window.width_px, .y = config.window.height_px },
        .frame_sync = .adaptive_vsync,
        .gl_major_version = 4,
        .gl_minor_version = 2,
        .enable_debug = IS_DEBUG,
        .gl_flags = if (IS_DEBUG) &[_]u32{graph.c.SDL_GL_CONTEXT_DEBUG_FLAG} else &[_]u32{},
    });
    defer win.destroyWindow();

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
    var draw = graph.ImmediateDrawingContext.init(alloc);
    defer draw.deinit();
    var font = try graph.Font.init(alloc, app_cwd.dir, args.fontfile orelse "ratasset/roboto.ttf", scaled_text_height, .{
        .codepoints_to_load = &(graph.Font.CharMaps.Default),
    });
    defer font.deinit();
    const splash = graph.Texture.initFromImgFile(alloc, app_cwd.dir, "ratasset/small.png", .{}) catch edit.missingTexture();

    var loadctx = edit.LoadCtx{ .opt = .{
        .draw = &draw,
        .font = &font,
        .win = &win,
        .splash = splash,
        .timer = try std.time.Timer.start(),
        .gtimer = load_timer,
        .expected_cb = 100,
    } };

    var time_init = try std.time.Timer.start();

    var editor = try Editor.init(alloc, if (args.nthread) |nt| @intFromFloat(nt) else null, config, args, &win, &loadctx, dirs);
    defer editor.deinit();
    std.debug.print("edit init took {d} us\n", .{time_init.read() / std.time.ns_per_us});

    var os9gui = try Os9Gui.init(alloc, try app_cwd.dir.openDir("ratgraph", .{}), gui_scale, .{
        .cache_dir = editor.dirs.pref,
        .font_size_px = scaled_text_height,
        .item_height = scaled_item_height,
        .font = &font.font,
    });
    defer os9gui.deinit();
    draw.preflush_cb = &flush_cb;
    font_ptr = os9gui.ofont;

    loadctx.cb("Loading gui");
    var gui = try G.Gui.init(alloc, &win, editor.dirs.pref, try app_cwd.dir.openDir("ratgraph", .{}), &font.font);
    defer gui.deinit();
    gui.style.config.default_item_h = scaled_item_height;
    gui.style.config.text_h = scaled_text_height;
    gui.scale = gui_scale;
    gui.tint = config.gui_tint;
    const nstyle = G.Style{};
    const gui_dstate = G.DrawState{
        .ctx = &draw,
        .font = &font.font,
        .style = &gui.style,
        .gui = &gui,
        .scale = gui_scale,
        .nstyle = &nstyle,
    };
    const inspector_win = InspectorWindow.create(&gui, editor);
    const pause_win = try PauseWindow.create(&gui, editor, app_cwd.dir);
    try gui.addWindow(&pause_win.vt, Rec(0, 300, 1000, 1000));
    try gui.addWindow(&inspector_win.vt, Rec(0, 300, 1000, 1000));
    const nag_win = try NagWindow.create(&gui, editor);
    try gui.addWindow(&nag_win.vt, Rec(0, 300, 1000, 1000));
    const asset_win = try AssetBrowser.create(&gui, editor);
    try gui.addWindow(&asset_win.vt, Rec(0, 0, 100, 1000));
    try asset_win.populate(&editor.vpkctx, game_conf.asset_browser_exclude.prefix, game_conf.asset_browser_exclude.entry.items);

    const launch_win = try LaunchWindow.create(&gui, editor);
    if (args.map == null) { //Only build the recents list if we don't have a map
        var timer = try std.time.Timer.start();
        if (config_dir.dir.openFile("recent_maps.txt", .{})) |recent| {
            defer recent.close();
            const slice = try recent.reader().readAllAlloc(alloc, std.math.maxInt(usize));
            defer alloc.free(slice);
            var it = std.mem.tokenizeScalar(u8, slice, '\n');
            while (it.next()) |filename| {
                const EXT = ".ratmap";
                if (std.mem.endsWith(u8, filename, EXT)) {
                    if (std.fs.cwd().openFile(filename, .{})) |recent_map| {
                        const qoi_data = util.getFileFromTar(alloc, recent_map, "thumbnail.qoi") catch continue;

                        defer alloc.free(qoi_data);
                        const qoi = graph.Bitmap.initFromQoiBuffer(alloc, qoi_data) catch continue;
                        const rec = LaunchWindow.Recent{
                            .name = try alloc.dupe(u8, filename[0 .. filename.len - EXT.len]),
                            .tex = graph.Texture.initFromBitmap(qoi, .{}),
                        };
                        qoi.deinit();

                        recent_map.close();
                        try launch_win.recents.append(rec);
                    } else |_| {}
                }
            }
        } else |_| {}

        std.debug.print("Recent build in {d} ms\n", .{timer.read() / std.time.ns_per_ms});
    }
    try gui.addWindow(&launch_win.vt, Rec(0, 300, 1000, 1000));

    var console_active = false;
    const console_win = try ConsoleWindow.create(&gui, editor, &editor.shell.cb_vt);
    try gui.addWindow(&console_win.vt, Rec(0, 0, 800, 600));

    const main_3d_id = try editor.panes.add(try editor_view.Main3DView.create(editor.panes.alloc, &font.font, gui.style.config.text_h));
    const main_2d_id = try editor.panes.add(try Ctx2dView.create(editor.panes.alloc, .y, &font.font));
    const main_2d_id2 = try editor.panes.add(try Ctx2dView.create(editor.panes.alloc, .x, &font.font));
    const main_2d_id3 = try editor.panes.add(try Ctx2dView.create(editor.panes.alloc, .z, &font.font));
    const inspector_pane = try editor.panes.add(try panereg.GuiPane.create(editor.panes.alloc, &gui, &inspector_win.vt));
    const texture_pane = try editor.panes.add(try OldGuiPane.create(editor.panes.alloc, editor, .texture, &os9gui));
    const model_pane = try editor.panes.add(try OldGuiPane.create(editor.panes.alloc, editor, .model, &os9gui));
    const model_preview_pane = try editor.panes.add(try OldGuiPane.create(editor.panes.alloc, editor, .model_view, &os9gui));

    const use_old_texture = false;
    const asset_pane = try editor.panes.add(try panereg.GuiPane.create(editor.panes.alloc, &gui, &asset_win.vt));

    editor.edit_state.inspector_pane_id = inspector_pane;

    loadctx.cb("Loading");

    loadctx.cb("Vpk's mounted");

    vpk.timer.log("Vpk dir");

    editor.draw_state.cam3d.fov = config.window.cam_fov;
    loadctx.setTime();

    if (args.blank) |blank| {
        try editor.setMapName(blank);
        try editor.initNewMap("sky_day01_01");
    } else {
        if (args.map) |mapname| {
            try editor.loadMap(app_cwd.dir, mapname, &loadctx);
        } else {
            while (!win.should_exit) {
                switch (try pauseLoop(&win, &draw, &launch_win.vt, &gui, gui_dstate, &loadctx, editor, launch_win.should_exit)) {
                    .exit => break,
                    .unpause => break,
                    .cont => continue,
                }
            }
        }
    }

    editor.layers.printVis(editor.layers.root, 0);

    //TODO with assets loaded dynamically, names might not be correct when saving before all loaded

    loadctx.setTime();

    graph.c.glEnable(graph.c.GL_CULL_FACE);
    graph.c.glCullFace(graph.c.GL_BACK);

    var ws = Split.Splits.init(alloc);
    defer ws.deinit();
    const main_tab = ws.newArea(.{
        .sub = .{
            .split = .{ .k = .vert, .perc = 0.67 },
            .left = ws.newArea(.{ .pane = main_3d_id }),
            .right = ws.newArea(.{ .pane = inspector_pane }),
        },
    });

    const main_2d_tab = ws.newArea(.{
        .sub = .{
            .split = .{ .k = .vert, .perc = 0.5 },
            .left = ws.newArea(.{ .sub = .{
                .split = .{ .k = .horiz, .perc = 0.5 },
                .left = ws.newArea(.{ .pane = main_3d_id }),
                .right = ws.newArea(.{ .pane = main_2d_id3 }),
            } }),
            .right = ws.newArea(.{ .sub = .{
                .split = .{ .k = .vert, .perc = 0.5 },
                .left = ws.newArea(.{ .sub = .{
                    .split = .{ .k = .horiz, .perc = 0.5 },
                    .left = ws.newArea(.{ .pane = main_2d_id }),
                    .right = ws.newArea(.{ .pane = main_2d_id2 }),
                } }),
                .right = ws.newArea(.{ .pane = inspector_pane }),
            } }),
        },
    });
    try ws.workspaces.append(main_tab);
    try ws.workspaces.append(ws.newArea(.{ .pane = if (use_old_texture) texture_pane else asset_pane }));
    try ws.workspaces.append(ws.newArea(.{ .sub = .{
        .split = .{ .k = .vert, .perc = 0.4 },
        .left = ws.newArea(.{ .pane = model_pane }),
        .right = ws.newArea(.{ .pane = model_preview_pane }),
    } }));
    try ws.workspaces.append(main_2d_tab);

    var tab_outputs = std.ArrayList(struct { graph.Rect, ?usize }).init(alloc);
    defer tab_outputs.deinit();

    var tab_handles = std.ArrayList(Split.ResizeHandle).init(alloc);
    defer tab_handles.deinit();

    var last_frame_group_owner: ?edit.EcsT.Id = null;

    var frame_timer = try std.time.Timer.start();
    var frame_time: u64 = 0;
    win.grabMouse(true);
    main_loop: while (!win.should_exit) {
        if (win.isBindState(config.keys.quit.b, .rising) or pause_win.should_exit)
            break :main_loop;
        if (win.isBindState(config.keys.pause.b, .rising)) {
            editor.paused = !editor.paused;
        }
        if (console_active)
            editor.panes.grab.override();

        if (editor.paused) {
            switch (try pauseLoop(&win, &draw, &pause_win.vt, &gui, gui_dstate, &loadctx, editor, pause_win.should_exit)) {
                .cont => continue :main_loop,
                .exit => break :main_loop,
                .unpause => editor.paused = false,
            }
        }
        draw.real_screen_dimensions = win.screen_dimensions.toF();

        //win.grabMouse(editor.draw_state.grab.is);
        win.grabMouse(editor.panes.grab.was_grabbed);
        win.pumpEvents(.poll);
        //POSONE please and thank you.
        frame_time = frame_timer.read();
        frame_timer.reset();
        const perc_of_60fps: f32 = @as(f32, @floatFromInt(frame_time)) / std.time.ns_per_ms / 16;
        //if (win.mouse.pos.x >= draw.screen_dimensions.x - 40)
        //    graph.c.SDL_WarpMouseInWindow(win.win, 10, win.mouse.pos.y);

        editor.edit_state.mpos = win.mouse.pos;

        const is_full: Gui.InputState = .{ .mouse = win.mouse, .key_state = &win.key_state, .keys = win.keys.slice(), .mod_state = win.mod };
        const is = is_full;
        try os9gui.resetFrame(is, &win);

        const cam_state = graph.ptypes.Camera3D.MoveState{
            .down = win.bindHigh(config.keys.cam_down.b),
            .up = win.bindHigh(config.keys.cam_up.b),
            .left = win.bindHigh(config.keys.cam_strafe_l.b),
            .right = win.bindHigh(config.keys.cam_strafe_r.b),
            .fwd = win.bindHigh(config.keys.cam_forward.b),
            .bwd = win.bindHigh(config.keys.cam_back.b),
            .mouse_delta = if (editor.panes.grab.was_grabbed) win.mouse.delta.scale(editor.config.window.sensitivity_3d) else .{ .x = 0, .y = 0 },
            .scroll_delta = win.mouse.wheel_delta.y,
            .speed_perc = @as(f32, if (win.bindHigh(config.keys.cam_slow.b)) 0.1 else 1) * perc_of_60fps,
        };

        const winrect = graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y);
        gui.clamp_window = winrect;
        graph.c.glEnable(graph.c.GL_BLEND);
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
        //const tab = tabs[editor.draw_state.tab_index];
        //const areas = Split.fillBuf(tab.split, &areas_buf, winrect);

        try gui.pre_update(gui.windows.items);
        if (win.isBindState(config.keys.toggle_console.b, .rising)) {
            console_active = !console_active;
        }
        ws.doTheSliders(win.mouse.pos, win.mouse.delta, win.mouse.left);
        try ws.setWorkspaceAndArea(editor.draw_state.tab_index, winrect);

        for (config.keys.inspector_tab.items, 0..) |bind, ind| {
            if (ind >= InspectorWindow.tabs.len)
                break;

            if (win.isBindState(bind.b, .rising))
                inspector_win.setTab(ind);
        }

        for (ws.getTab()) |out| {
            const pane_area = out[0];
            const pane = out[1] orelse continue;
            if (editor.panes.get(pane)) |pane_vt| {
                //TODO put this in the places that should have it 2
                editor.handleMisc3DKeys(ws.workspaces.items);
                const owns = editor.panes.grab.tryOwn(pane_area, &win, pane);
                editor.panes.grab.current_stack_pane = pane;
                if (owns) {
                    editor.edit_state.lmouse = win.mouse.left;
                    editor.edit_state.rmouse = win.mouse.right;
                } else {
                    editor.edit_state.lmouse = .low;
                    editor.edit_state.rmouse = .low;
                }
                if (pane_vt.draw_fn) |drawf| {
                    drawf(pane_vt, pane_area, editor, .{ .draw = &draw, .win = &win, .camstate = cam_state }, pane);
                }
            }
        }
        if (console_active) {
            console_win.focus(&gui);
            console_win.area.dirty(&gui);
            try gui.update(&.{&console_win.vt});
            try gui.window_collector.append(gui.alloc, &console_win.vt);
        }

        editor.panes.grab.endFrame();

        try os9gui.drawGui(&draw);
        const wins = gui.window_collector.items;
        try gui.draw(gui_dstate, false, wins);
        gui.drawFbos(&draw, wins);

        draw.setViewport(null);
        try loadctx.loadedSplash(win.keys.len > 0);
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
            switch (try pauseLoop(&win, &draw, &nag_win.vt, &gui, gui_dstate, &loadctx, editor, nag_win.should_exit)) {
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
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = if (IS_DEBUG) 0 else 0,
    }){};
    const alloc = gpa.allocator();
    var arg_it = try std.process.argsWithAllocator(alloc);
    defer arg_it.deinit();

    const args = try graph.ArgGen.parseArgs(&app.Args, &arg_it);
    if (args.version != null) {
        const out = std.io.getStdOut();
        try out.writer().print("{s}\n", .{version.version});
        return;
    }

    if (args.build != null) {
        const out = std.io.getStdOut();
        var jout = std.json.writeStream(out.writer(), .{ .whitespace = .indent_2 });
        defer out.writer().print("\n", .{}) catch {}; //Json doesn't emit final \n
        defer jout.deinit();
        try jout.write(.{
            .version = version.version,
            .os = builtin.target.os.tag,
            .arch = builtin.target.cpu.arch,
            .mode = builtin.mode,
            .commit = build_config.commit_hash,
        });
        return;
    }

    try wrappedMain(alloc, args);
    //TODO we need to wait for async save threads to join!!!!

    // if the application is quit while items are being loaded in the thread pool, we get spammed with memory leaks.
    // There is no benefit to ensuring those items are free'd on exit.
    if (IS_DEBUG)
        _ = gpa.detectLeaks(); // Not deferred, so on error there isn't spam
}

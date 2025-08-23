const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const Mat4 = graph.za.Mat4;
const SparseSet = graph.SparseSet;
const meshutil = graph.meshutil;
const vmf = @import("vmf.zig");
const vdf = @import("vdf.zig");
const vpk = @import("vpk.zig");
const csg = @import("csg.zig");
const vtf = @import("vtf.zig");
const fgd = @import("fgd.zig");
const vvd = @import("vvd.zig");
const clipper = @import("clip_solid.zig");
const gameinfo = @import("gameinfo.zig");
const profile = @import("profile.zig");
const Gui = graph.Gui;
const StringStorage = @import("string.zig").StringStorage;
const Skybox = @import("skybox.zig").Skybox;
const Gizmo = @import("gizmo.zig").Gizmo;
const raycast = @import("raycast_solid.zig");
const DrawCtx = graph.ImmediateDrawingContext;
const thread_pool = @import("thread_pool.zig");
const assetbrowse = @import("asset_browser.zig");
const Conf = @import("config.zig");
const compile_conf = @import("config");
const undo = @import("undo.zig");
const tool_def = @import("tools.zig");
const util = @import("util.zig");
const Autosaver = @import("autosave.zig").Autosaver;
const NotifyCtx = @import("notify.zig").NotifyCtx;
const Selection = @import("selection.zig");
const VisGroups = @import("visgroup.zig");
const newvis = @import("newvis.zig");
const jsontovmf = @import("jsonToVmf.zig").jsontovmf;
const ecs = @import("ecs.zig");
const json_map = @import("json_map.zig");
const DISABLE_SPLASH = false;
const GroupId = ecs.Groups.GroupId;
const eviews = @import("editor_views.zig");
const path_guess = @import("path_guess.zig");
const shell = @import("shell.zig");
const grid_stuff = @import("grid.zig");
const class_tracker = @import("class_track.zig");
const version = @import("version.zig").version;
const pane = @import("pane.zig");

const async_util = @import("async.zig");
const util3d = @import("util_3d.zig");
const pointfile = @import("pointfile.zig");
const def_render = @import("def_render.zig");

const MAPFMT = " {s}{s} - RatHammer";
var WINDOW_TITLE_BUFFER: [256]u8 = undefined;

const builtin = @import("builtin");
const WINDOZE = builtin.target.os.tag == .windows;
pub const TMP_DIR = if (WINDOZE) "C:/rathammer_tmp" else "/tmp/mapcompile";
pub const MAP_OUT = "dump";

const Model = struct {
    mesh: ?*vvd.MultiMesh = null,

    pub fn initEmpty(_: std.mem.Allocator) @This() {
        return .{ .mesh = null };
    }

    //Alloc  allocated meshptr
    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        if (self.mesh) |mm| {
            mm.deinit();
            alloc.destroy(mm);
        }
    }
};

pub threadlocal var mesh_build_time = profile.BasicProfiler.init();
pub const EcsT = ecs.EcsT;
const Side = ecs.Side;
const MeshBatch = ecs.MeshBatch;
const Displacement = ecs.Displacement;
const Entity = ecs.Entity;
const AABB = ecs.AABB;
const KeyValues = ecs.KeyValues;
pub const log = std.log.scoped(.rathammer);
pub const Context = struct {
    const Self = @This();
    const ButtonState = graph.SDL.ButtonState;

    /// Only real state is a timer, has helper functions for naming and pruning autosaves.
    autosaver: Autosaver,

    /// These have no real state, just exist to prevent excessive memory allocation.
    rayctx: raycast.Ctx,
    csgctx: csg.Context,
    clipctx: clipper.ClipCtx,

    /// Manages mounting of vpks and assigning a unique id to all resource string paths.
    vpkctx: vpk.Context,

    scratch_buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    /// Stores all the mesh data for solids.
    meshmap: ecs.MeshMap,

    /// Store static strings for the lifetime of application
    string_storage: StringStorage,

    /// Stores undo state, most changes to world state (ecs) should be done through a undo vtable
    undoctx: undo.UndoContext,

    /// This sucks, clean it up
    fgd_ctx: fgd.EntCtx,

    /// These maps map vpkids to their respective resource,
    /// when fetching a resource with getTexture, etc. Something is always returned. If an entry does not exist,
    /// a job is submitted to the load thread pool and a placeholder is inserted into the map and returned
    textures: std.AutoHashMap(vpk.VpkResId, graph.Texture),
    models: std.AutoHashMap(vpk.VpkResId, Model),

    skybox: Skybox,

    /// Draw colored text messages to the screen for a short time
    notifier: NotifyCtx,

    /// Gui widget
    asset_browser: assetbrowse.AssetBrowserGui,

    /// Stores all the world state, solids, entities, disp, etc.
    ecs: EcsT,
    groups: ecs.Groups,

    async_asset_load: thread_pool.Context,
    /// Used to track tool txtures, TODO turn this into transparent_map, sticking all $alphatest and $translucent in here for
    /// alpha draw ordering
    tool_res_map: std.AutoHashMap(vpk.VpkResId, void),
    visgroups: VisGroups,
    autovis: newvis.VisContext,

    shell: *shell.CommandCtx,

    loadctx: *LoadCtx,

    classtrack: class_tracker.Tracker,

    panes: pane.PaneReg,

    tools: tool_def.ToolRegistry,
    //panes: eviews.PaneReg,
    paused: bool = true,
    has_loaded_map: bool = false,

    draw_state: struct {
        init_asset_count: usize = 0, //Used to indicate we are loading things

        active_lights: usize = 0,
        draw_outlines: bool = true,

        draw_displacment_solid: bool = false,

        factor: f32 = 64,
        light_mul: f32 = 0.11,
        const_add: f32 = 0, //Added to light constant factor
        far: f32 = 512 * 64,
        pad: f32 = 164,
        index: usize = 0,
        planes: [4]f32 = [4]f32{ 462, 1300, 4200, 16400 },
        pointfile: ?pointfile.PointFile = null,
        portalfile: ?pointfile.PortalFile = null,
        tab_index: usize = 0,
        meshes_dirty: bool = false,

        //TODO remove this once we have a decent split system
        //Used by inspector when clicking select on a texture or model kv
        texture_browser_tab_index: usize = 1,
        model_browser_tab_index: usize = 2,

        /// This should be replaced with visgroups, for the most part.
        tog: struct {
            wireframe: bool = false,
            sprite: bool = true,
            models: bool = true,
            skybox: bool = true,

            model_render_dist: f32 = 512 * 2,
        } = .{},

        basic_shader: graph.glID,
        cam3d: graph.Camera3D = .{ .up = .z, .move_speed = 10, .max_move_speed = 100, .fwd_back_kind = .planar },
        cam_far_plane: f32 = 512 * 64,
        cam_near_plane: f32 = 1,

        /// we keep our own so that we can do some draw calls with depth some without.
        ctx: graph.ImmediateDrawingContext,
        screen_space_text_ctx: graph.ImmediateDrawingContext,
    },

    selection: Selection,
    renderer: def_render.Renderer,

    hacky_extra_vmf: struct {
        //Not freed, use static_string
        override_vis_group: ?[]const u8 = null,
    } = .{},

    gui_crap: struct {
        tool_changed: bool = true,
    } = .{},

    edit_state: struct {
        map_version: u64 = 0, //Incremented every save
        autosaved_at_delta: u64 = 0, // Don't keep autosaving the same thing
        saved_at_delta: u64 = 0,
        //Used to get a rising edge to set window title
        was_saved: bool = true,

        manual_hidden_count: usize = 0,
        default_group_entity: enum { none, func_detail } = .func_detail,
        __tool_index: usize = 0,

        lmouse: ButtonState = .low,
        rmouse: ButtonState = .low,
        mpos: graph.Vec2f = undefined,
        inspector_pane_id: usize = 100000,
    } = .{},
    grid: grid_stuff.Snap = .{ .s = Vec3.set(16) },

    config: Conf.Config,
    game_conf: Conf.GameEntry,
    dirs: struct {
        const Dir = std.fs.Dir;
        cwd: Dir, //Should really be named, game cwd
        app_cwd: Dir,
        fgd: Dir,
        pref: Dir,
        autosave: Dir,
        config: Dir,
    },
    win: *graph.SDL.Window,

    /// These are currently only used for baking all tool icons into an atlas.
    asset: graph.AssetBake.AssetMap,
    //TODO Once the toolbar is written in the new gui AND we can load pngs from vpkctx
    // just draw normally as the number of drawcalls be amortized with the good gui.
    asset_atlas: graph.Texture,

    /// This arena is reset every editor.update()
    frame_arena: std.heap.ArenaAllocator,
    /// basename of map, without extension or path
    loaded_map_name: ?[]const u8 = null,
    /// This is always relative to cwd
    loaded_map_path: ?[]const u8 = null,

    pub fn setWindowTitle(self: *Self, map_fmt_args: anytype) void {
        var fbs = std.io.FixedBufferStream([]u8){ .buffer = &WINDOW_TITLE_BUFFER, .pos = 0 };
        fbs.writer().print(MAPFMT, map_fmt_args) catch {
            WINDOW_TITLE_BUFFER[0] = 0;
        };
        fbs.writer().writeByte(0) catch {
            WINDOW_TITLE_BUFFER[0] = 0;
        };
        if (!graph.c.SDL_SetWindowTitle(self.win.win, &WINDOW_TITLE_BUFFER[0])) {
            log.err("Failed to set window title", .{});
        }
    }

    pub fn setMapName(self: *Self, filename: []const u8) !void {
        const eql = std.mem.eql;
        const allowed_exts = [_][]const u8{
            ".json",
            ".tar",
            ".ratmap",
            ".vmf",
        };
        var dot_index: ?usize = null;
        var slash_index: ?usize = null;
        if (std.mem.lastIndexOfScalar(u8, filename, '.')) |index| {
            var found = false;
            for (allowed_exts) |ex| {
                if (eql(u8, filename[index..], ex)) {
                    found = true;
                }
            }
            if (!found) {
                log.warn("Unknown map extension: {s}", .{filename});
            }
            dot_index = index;
            //pruned = filename[0..index];
        } else {
            log.warn("Map has no extension {s}", .{filename});
        }
        if (std.mem.lastIndexOfAny(u8, filename, "\\/")) |sep| {
            slash_index = sep;
        }
        const lname = filename[if (slash_index) |si| si + 1 else 0..if (dot_index) |d| d else filename.len];
        self.loaded_map_name = try self.storeString(lname);
        self.loaded_map_path = try self.storeString(filename[0..if (slash_index) |s| s + 1 else 0]);
        //pruned = pruned[sep + 1 ..];

        //self.loaded_map_name = try self.storeString(pruned);
    }

    pub fn init(
        alloc: std.mem.Allocator,
        num_threads: ?u32,
        config: Conf.Config,
        args: anytype,
        win_ptr: *graph.SDL.Window,
        loadctx: *LoadCtx,
        env: *std.process.EnvMap,
        app_cwd: std.fs.Dir,
        conf_dir: std.fs.Dir,
    ) !*Self {
        const shader_dir = try app_cwd.openDir("ratasset/shader", .{});
        var ret = try alloc.create(Context);
        ret.* = .{
            //These are initilized in editor.postInit
            .dirs = undefined,
            .game_conf = undefined,
            .asset = undefined,
            .asset_atlas = undefined,

            .classtrack = class_tracker.Tracker.init(alloc),
            .loadctx = loadctx,
            .win = win_ptr,
            .notifier = NotifyCtx.init(alloc, 4000),
            .autosaver = try Autosaver.init(config.autosave.interval_min * std.time.ms_per_min, config.autosave.max, config.autosave.enable, alloc),
            .rayctx = raycast.Ctx.init(alloc),
            .selection = Selection.init(alloc),
            .frame_arena = std.heap.ArenaAllocator.init(alloc),
            .groups = ecs.Groups.init(alloc),
            .config = config,
            .alloc = alloc,
            .fgd_ctx = fgd.EntCtx.init(alloc),
            .undoctx = undo.UndoContext.init(alloc),
            .string_storage = StringStorage.init(alloc),
            .asset_browser = assetbrowse.AssetBrowserGui.init(alloc),
            .tools = tool_def.ToolRegistry.init(alloc),
            .panes = pane.PaneReg.init(alloc),
            .csgctx = try csg.Context.init(alloc),
            .clipctx = clipper.ClipCtx.init(alloc),
            .vpkctx = try vpk.Context.init(alloc),
            .visgroups = VisGroups.init(alloc),
            .autovis = newvis.VisContext.init(alloc),
            .meshmap = ecs.MeshMap.init(alloc),
            .ecs = try EcsT.init(alloc),
            .scratch_buf = std.ArrayList(u8).init(alloc),
            .models = std.AutoHashMap(vpk.VpkResId, Model).init(alloc),
            .async_asset_load = try thread_pool.Context.init(alloc, num_threads),
            .textures = std.AutoHashMap(vpk.VpkResId, graph.Texture).init(alloc),
            .skybox = try Skybox.init(alloc, shader_dir),
            .tool_res_map = std.AutoHashMap(vpk.VpkResId, void).init(alloc),
            .shell = try shell.CommandCtx.create(alloc, ret),
            .renderer = try def_render.Renderer.init(alloc, shader_dir),

            .draw_state = .{
                .ctx = graph.ImmediateDrawingContext.init(alloc),
                .screen_space_text_ctx = DrawCtx.init(alloc),
                .basic_shader = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
                    .{ .path = "basic.vert", .t = .vert },
                    .{ .path = "basic.frag", .t = .frag },
                }),
            },
        };
        //If an error occurs during initilization it is fatal so there is no reason to clean up resources.
        //Thus we call, defer editor.deinit(); after all is initialized..
        try ret.postInit(args, loadctx, env, app_cwd, conf_dir);
        return ret;
    }

    /// Called by init
    fn postInit(self: *Self, args: anytype, loadctx: *LoadCtx, env: *std.process.EnvMap, app_cwd: std.fs.Dir, conf_dir: std.fs.Dir) !void {
        if (self.config.default_game.len == 0) {
            std.debug.print("config.vdf must specify a default_game!\n", .{});
            return error.incompleteConfig;
        }
        const game_name = args.game orelse self.config.default_game;
        const game_conf = self.config.games.map.get(game_name) orelse {
            std.debug.print("{s} is not defined in the \"games\" section\n", .{game_name});
            return error.gameConfigNotFound;
        };
        self.game_conf = game_conf;

        //args.custom_cwd overrides everything
        const cwd = if (args.custom_cwd) |cc| util.openDirFatal(std.fs.cwd(), cc, .{}, "") else blk: {
            if (self.config.paths.steam_dir.len > 0) {
                const p = self.config.paths.steam_dir;
                if (std.fs.cwd().openDir(p, .{})) |steam_dir| {
                    log.info("Opened config.paths.steam_dir: {s}", .{p});
                    break :blk steam_dir;
                } else |err| {
                    log.err("Failed to open config.paths.steam_dir: {s}, with error {!}", .{ p, err });
                }
            }
            break :blk try path_guess.guessSteamPath(env, self.alloc) orelse {
                log.info("Failed to guess steam path, defaulting to exe cwd ", .{});
                break :blk std.fs.cwd();
            };
        };
        const custom_cwd_msg = "Set a custom cwd with --custom_cwd flag";
        const fgd_dir = util.openDirFatal(cwd, args.fgddir orelse game_conf.fgd_dir, .{}, "");

        loadctx.cb("Dir's opened");
        const ORG = "rathammer";
        const APP = "";
        const path = graph.c.SDL_GetPrefPath(ORG, APP);
        if (path == null) {
            log.err("Unable to make pref path", .{});
        }
        const pref = try std.fs.cwd().makeOpenPath(std.mem.span(path), .{});
        const autosave = try pref.makeOpenPath("autosave", .{});

        try graph.AssetBake.assetBake(self.alloc, app_cwd, "ratasset", pref, "packed", .{});
        loadctx.cb("Asset's baked");

        self.asset = try graph.AssetBake.AssetMap.initFromManifest(self.alloc, pref, "packed");
        self.asset_atlas = try graph.AssetBake.AssetMap.initTextureFromManifest(self.alloc, pref, "packed");

        for (game_conf.gameinfo.items) |gamei| {
            const base_dir_ = util.openDirFatal(cwd, gamei.base_dir, .{}, custom_cwd_msg);
            const game_dir_ = util.openDirFatal(cwd, gamei.game_dir, .{}, custom_cwd_msg);

            try gameinfo.loadGameinfo(self.alloc, base_dir_, game_dir_, &self.vpkctx, loadctx, if (gamei.gameinfo_name.len != 0) gamei.gameinfo_name else "gameinfo.txt");
        }

        if (args.basedir) |bd| {
            if (args.gamedir) |gd| {
                const base_dir_ = util.openDirFatal(cwd, bd, .{}, custom_cwd_msg);
                const game_dir_ = util.openDirFatal(cwd, gd, .{}, custom_cwd_msg);
                try gameinfo.loadGameinfo(self.alloc, base_dir_, game_dir_, &self.vpkctx, loadctx, "gameinfo.txt");
            }
        }

        self.dirs = .{ .cwd = cwd, .fgd = fgd_dir, .pref = pref, .autosave = autosave, .app_cwd = app_cwd, .config = conf_dir };

        //try gameinfo.loadGameinfo(self.alloc, base_dir, game_dir, &self.vpkctx, loadctx);
        try self.asset_browser.populate(&self.vpkctx, game_conf.asset_browser_exclude.prefix, game_conf.asset_browser_exclude.entry.items);
        try fgd.loadFgd(&self.fgd_ctx, fgd_dir, args.fgd orelse game_conf.fgd);

        //The order in which these are registered maps to the order 'tool' keybinds are specified in config.vdf
        try self.tools.registerCustom("translate", tool_def.Translate, try tool_def.Translate.create(self.alloc, self));
        try self.tools.register("translate_face", tool_def.TranslateFace);
        try self.tools.register("place_model", tool_def.PlaceEntity);
        try self.tools.register("cube_draw", tool_def.CubeDraw);
        try self.tools.register("fast_face", tool_def.FastFaceManip);
        try self.tools.registerCustom("texture", tool_def.TextureTool, try tool_def.TextureTool.create(self.alloc, self));
        try self.tools.registerCustom("vertex", tool_def.VertexTranslate, try tool_def.VertexTranslate.create(self.alloc, self));
        try self.tools.register("clip", tool_def.Clipping);

        try self.autovis.add(.{ .name = "props", .filter = "prop_", .kind = .class, .match = .startsWith });
        try self.autovis.add(.{ .name = "trigger", .filter = "trigger_", .kind = .class, .match = .startsWith });
        try self.autovis.add(.{ .name = "tools", .filter = "materials/tools", .kind = .texture, .match = .startsWith });
        try self.autovis.add(.{ .name = "func", .filter = "func", .kind = .class, .match = .startsWith });
        try self.autovis.add(.{ .name = "models", .filter = "", .kind = .model, .match = .startsWith });
        try self.autovis.add(.{ .name = "world", .filter = "", .kind = .class, .match = .startsWith, .invert = true });

        if (comptime compile_conf.http_version_check) {
            if (self.config.enable_version_check and args.no_version_check == null) {
                try async_util.CheckVersionHttp_INCOMPLETE.spawn(self.alloc, &self.async_asset_load);
            }
        }
    }

    pub fn deinit(self: *Self) void {
        self.asset.deinit();

        self.classtrack.deinit();
        self.visgroups.deinit();
        self.autovis.deinit();
        self.tools.deinit();
        self.panes.deinit();
        self.tool_res_map.deinit();
        self.undoctx.deinit();
        self.ecs.deinit();
        self.fgd_ctx.deinit();
        self.notifier.deinit();
        self.selection.deinit();
        self.string_storage.deinit();
        self.rayctx.deinit();
        self.scratch_buf.deinit();
        self.asset_browser.deinit();
        self.csgctx.deinit();
        self.clipctx.deinit();
        self.vpkctx.deinit();
        self.skybox.deinit();
        self.frame_arena.deinit();
        self.groups.deinit();
        self.renderer.deinit();
        self.shell.destroy(self.alloc);
        var mit = self.models.valueIterator();
        while (mit.next()) |m| {
            m.deinit(self.alloc);
        }
        self.models.deinit();
        self.textures.deinit();

        var it = self.meshmap.iterator();
        while (it.next()) |item| {
            item.value_ptr.*.deinit();
            self.alloc.destroy(item.value_ptr.*);
        }
        self.meshmap.deinit();
        self.draw_state.ctx.deinit();
        self.draw_state.screen_space_text_ctx.deinit();
        if (self.draw_state.pointfile) |pf|
            pf.verts.deinit();
        if (self.draw_state.portalfile) |pf|
            pf.verts.deinit();
        self.async_asset_load.deinit();

        //destroy does not take a pointer to alloc, so this is safe.
        self.alloc.destroy(self);
    }

    /// This is a wrapper around ecs.getOptPtr which only returns component if the visgroup component is attached.
    pub fn getComponent(self: *Self, index: EcsT.Id, comptime comp: EcsT.Components) ?*EcsT.Fields[@intFromEnum(comp)].ftype {
        const ent = self.ecs.getEntity(index) catch return null;
        if (!ent.isSet(@intFromEnum(comp))) return null;
        const vis_mask = EcsT.getComponentMask(&.{ .invisible, .deleted, .autovis_invisible });
        if (self.ecs.intersects(index, vis_mask)) return null;
        return self.ecs.getPtr(index, comp) catch null;
    }

    pub fn dupeEntity(self: *Self, ent: EcsT.Id) !EcsT.Id {
        const duped = try self.ecs.dupeEntity(ent);
        if (self.getComponent(duped, .entity)) |new_ent| {
            try new_ent.setClass(self, new_ent.class, duped);
        }
        return duped;
    }

    /// Wrapper around iterator that omits anything with deleted
    pub fn Iterator(comptime comp: EcsT.Components) type {
        return struct {
            const childT = EcsT.Fields[@intFromEnum(comp)].ftype;
            const Ch = ecs.SparseSet(childT, EcsT.Id);
            //const childT = Fields[@intFromEnum(component_type)].ftype;
            child_it: Ch.Iterator,

            //Index into sparse, IE current entity id
            i: EcsT.Id,
            ecs: *EcsT,

            pub fn next(self: *@This()) ?*childT {
                const vis_mask = EcsT.getComponentMask(&.{ .invisible, .deleted, .autovis_invisible });
                while (self.child_it.next()) |item| {
                    if (self.ecs.intersects(self.child_it.i, vis_mask))
                        continue;
                    self.i = self.child_it.i;
                    //if (!(self.ecs.hasComponent(self.child_it.i, .deleted) catch false)) {
                    //    self.i = self.child_it.i;
                    return item;
                    //}
                }
                return null;
            }
        };
    }

    pub fn editIterator(self: *Self, comptime comp: EcsT.Components) Iterator(comp) {
        return .{
            .child_it = @field(self.ecs.data, @tagName(comp)).denseIterator(),
            .i = 0,
            .ecs = &self.ecs,
        };
    }

    pub fn rebuildMeshesIfDirty(self: *Self) !void {
        var it = self.meshmap.iterator();
        while (it.next()) |mesh| {
            try mesh.value_ptr.*.rebuildIfDirty(self);
        }
    }

    pub fn rebuildVisGroups(self: *Self) !void {
        std.debug.print("Rebuilding visgroups\n", .{});
        {
            var it = self.ecs.iterator(.invisible);
            while (it.next()) |_| {
                if (try self.ecs.getOptPtr(it.i, .solid)) |solid| {
                    try solid.rebuild(it.i, self);
                }
            }
            self.ecs.clearComponent(.invisible);
        }
        //IF

        var it = self.ecs.iterator(.editor_info);
        while (it.next()) |info| {
            var copy = self.visgroups.disabled;
            copy.setIntersection(info.vis_mask);
            if (copy.findFirstSet() != null) {
                self.ecs.attachComponent(it.i, .invisible, .{}) catch {}; // We discard error incase it is already attached
                if (try self.ecs.getOptPtr(it.i, .solid)) |solid|
                    try solid.removeFromMeshMap(it.i, self);
            } else {
                _ = try self.ecs.removeComponentOpt(it.i, .invisible);
                if (try self.ecs.getOptPtr(it.i, .solid)) |solid|
                    try solid.rebuild(it.i, self);
            }
        }
    }

    pub fn rebuildAutoVis(self: *Self) !void {
        var get_class = false;
        var get_texture = false;
        var get_model = false;

        const disabled, const dis_mask = try self.autovis.getDisabled();
        for (disabled) |dis| {
            switch (dis.kind) {
                .class => get_class = true,
                .texture => get_texture = true,
                .model => get_model = true,
            }
        }

        var mod_name = std.ArrayList(u8).init(self.frame_arena.allocator());
        defer mod_name.deinit();
        var tex_name = std.ArrayList(u8).init(self.frame_arena.allocator());
        defer tex_name.deinit();

        var groups_hidden = std.AutoHashMap(ecs.Groups.GroupId, void).init(self.frame_arena.allocator());

        var num_changed: usize = 0;

        var it = self.ecs.iterator(.bounding_box);
        const vis_mask = EcsT.getComponentMask(&.{ .invisible, .deleted });
        while (it.next()) |_| {
            var is_hidden = false;
            if (self.ecs.intersects(it.i, vis_mask))
                continue;

            const was_hidden = self.ecs.hasComponent(it.i, .autovis_invisible) catch false;
            if (was_hidden) // The component must be removed from all !
                _ = try self.ecs.removeComponentOpt(it.i, .autovis_invisible);

            const ent = if (get_class or get_model) try self.ecs.getOptPtr(it.i, .entity) else null;
            const solid = if (get_texture) try self.ecs.getOptPtr(it.i, .solid) else null;

            mod_name.clearRetainingCapacity();
            tex_name.clearRetainingCapacity();
            mblk: {
                if (!get_model) break :mblk;
                const entity = ent orelse break :mblk;
                const mod_id = entity._model_id orelse break :mblk;

                const mask = try self.autovis.getCachedMask(mod_id, &self.vpkctx);
                if (mask.intersectWith(dis_mask).mask != 0)
                    is_hidden = true;
            }
            const texture = mblk: {
                if (!get_texture or is_hidden) break :mblk null;
                const sol = solid orelse break :mblk null;
                if (sol.sides.items.len == 0) break :mblk null;
                //just use the first side
                const side = sol.sides.items[0];
                if (side.tex_id == 0) {
                    try tex_name.appendSlice(side.material);
                    break :mblk tex_name.items;
                }

                for (sol.sides.items) |oside| { //Ensure all sides have the same texture
                    if (oside.tex_id != side.tex_id)
                        break :mblk null;
                }

                const mask = try self.autovis.getCachedMask(side.tex_id, &self.vpkctx);
                if (mask.intersectWith(dis_mask).mask != 0)
                    is_hidden = true;
                break :mblk null;
            };

            if (!is_hidden and ent != null) {
                const mask = try self.autovis.getCachedClassMask(ent.?.class);
                if (mask.intersectWith(dis_mask).mask != 0)
                    is_hidden = true;
            }

            if (!is_hidden) {
                check_disabled: for (disabled) |dis| {
                    if (newvis.checkMatch(dis, null, texture, null)) {
                        is_hidden = true;
                        break :check_disabled;
                    }
                }
            }

            if (is_hidden) {
                self.ecs.attachComponent(it.i, .autovis_invisible, .{}) catch {};
                if (self.groups.getGroup(it.i)) |group_id| {
                    try groups_hidden.put(group_id, {});
                }
            }

            if (is_hidden != was_hidden) {
                num_changed += 1;
                if (try self.ecs.getOptPtr(it.i, .solid)) |s_ptr| {
                    if (is_hidden) {
                        try s_ptr.removeFromMeshMap(it.i, self);
                    } else {
                        try s_ptr.rebuild(it.i, self);
                    }
                }
            }
        }
        {
            var group_it = self.editIterator(.group);
            while (group_it.next()) |item| {
                if (!groups_hidden.contains(item.id)) continue;
                num_changed += 1;
                self.ecs.attachComponent(group_it.i, .autovis_invisible, .{}) catch continue;
                if (try self.ecs.getOptPtr(group_it.i, .solid)) |s_ptr| {
                    try s_ptr.removeFromMeshMap(group_it.i, self);
                }
            }
        }
    }

    pub fn isBindState(self: *const Self, bind: graph.SDL.NewBind, state: graph.SDL.ButtonState) bool {
        if (!self.panes.stackOwns()) return false;
        return self.win.isBindState(bind, state);
    }

    pub fn mouseState(self: *const Self) graph.SDL.MouseState {
        if (!self.panes.stackOwns()) return .{};
        return self.win.mouse;
    }

    pub fn writeToJson(self: *Self, writer: anytype) !void {
        var jwr = std.json.writeStream(writer, .{ .whitespace = .indent_1 });
        try jwr.beginObject();
        {
            try jwr.objectField("editor");
            try jwr.write(json_map.JsonEditor{
                .cam = json_map.JsonCamera.fromCam(self.draw_state.cam3d),
                .map_json_version = json_map.CURRENT_MAP_VERSION,
                .map_version = self.edit_state.map_version,
                .editor_version = version,
            });

            try jwr.objectField("visgroup");
            try self.visgroups.writeToJson(&jwr);

            try jwr.objectField("extra");
            {
                try jwr.beginObject();
                try jwr.objectField("recent_mat");
                try self.writeComponentToJson(&jwr, self.asset_browser.recent_mats.list, 0);
                try jwr.endObject();
            }

            try jwr.objectField("sky_name");
            try jwr.write(self.skybox.sky_name);
            try jwr.objectField("objects");
            try jwr.beginArray();
            {
                for (self.ecs.entities.items, 0..) |ent, id| {
                    if (ent.isSet(EcsT.Types.tombstone_bit))
                        continue;
                    if (ent.isSet(@intFromEnum(EcsT.Components.deleted)))
                        continue;
                    try jwr.beginObject();
                    {
                        try jwr.objectField("id");
                        try jwr.write(id);

                        if (self.groups.getGroup(@intCast(id))) |group| {
                            try jwr.objectField("owned_group");
                            try jwr.write(group);
                        }

                        inline for (EcsT.Fields, 0..) |field, f_i| {
                            if (!@hasDecl(field.ftype, "ECS_NO_SERIAL")) {
                                if (ent.isSet(f_i)) {
                                    try jwr.objectField(field.name);
                                    const ptr = try self.ecs.getPtr(@intCast(id), @enumFromInt(f_i));
                                    try self.writeComponentToJson(&jwr, ptr.*, @intCast(id));
                                }
                            }
                        }
                    }
                    try jwr.endObject();
                }
            }
            try jwr.endArray();
        }
        //Men I trust, men that rust
        try jwr.endObject();
    }

    pub fn writeComponentToJson(self: *Self, jw: anytype, comp: anytype, id: EcsT.Id) !void {
        const T = @TypeOf(comp);
        const info = @typeInfo(T);
        switch (T) {
            []const u8 => return jw.write(comp),
            vpk.VpkResId => {
                if (self.vpkctx.namesFromId(comp)) |name| {
                    return try jw.print("\"{s}/{s}.{s}\"", .{ name.path, name.name, name.ext });
                }
                std.debug.print("THIS IS BAD, trying to serialize an id that has not been loaded yet, json will be null\n", .{});
                return try jw.write(null);
            },
            Vec3 => return jw.print("\"{e} {e} {e}\"", .{ comp.x(), comp.y(), comp.z() }),
            Side.UVaxis => return jw.print("\"{} {} {} {} {}\"", .{ comp.axis.x(), comp.axis.y(), comp.axis.z(), comp.trans, comp.scale }),
            else => {},
        }
        switch (info) {
            .int, .float, .bool => try jw.write(comp),
            .optional => {
                if (comp) |p|
                    return try self.writeComponentToJson(jw, p, id);
                return try jw.write(null);
            },
            .@"struct" => |s| {
                if (std.meta.hasFn(T, "serial")) {
                    return try comp.serial(self, jw, id);
                }
                if (vdf.getArrayListChild(@TypeOf(comp))) |child| {
                    if (child == u8) {
                        try jw.write(comp.items);
                    } else {
                        try jw.beginArray();
                        for (comp.items) |item| {
                            try self.writeComponentToJson(jw, item, id);
                        }
                        try jw.endArray();
                    }
                    return;
                }
                try jw.beginObject();
                inline for (s.fields) |field| {
                    if (field.name[0] == '_') { //Skip fields

                    } else {
                        try jw.objectField(field.name);
                        try self.writeComponentToJson(jw, @field(comp, field.name), id);
                    }
                }
                try jw.endObject();
            },
            else => @compileError("no work for : " ++ @typeName(T)),
        }
    }

    //TODO poke around codebase, make sure this rebuilds ALL the dependant state
    pub fn rebuildAllDependentState(self: *Self) !void {
        mesh_build_time.start();
        {
            var it = self.ecs.iterator(.entity);
            while (it.next()) |ent| {
                try ent.setClass(self, ent.class, it.i);
                // Clear before we iterate solids as they will insert themselves into here
                //ent.solids.clearRetainingCapacity();
            }
        }
        { //First clear
            var mesh_it = self.meshmap.valueIterator();
            while (mesh_it.next()) |batch| {
                batch.*.mesh.vertices.clearRetainingCapacity();
                batch.*.mesh.indicies.clearRetainingCapacity();
            }
        }
        { //Iterate all solids and add
            var it = self.ecs.iterator(.solid);
            while (it.next()) |solid| {
                const bb = (try self.ecs.getOptPtr(it.i, .bounding_box)) orelse continue;
                solid.recomputeBounds(bb);
                try solid.rebuild(it.i, self);
                //if (solid._parent_entity) |pid| {
                //    try self.attachSolid(it.i, pid);
                //}
            }
        }
        {
            var it = self.ecs.iterator(.displacements);
            while (it.next()) |disp| {
                try disp.rebuild(it.i, self);
            }
        }
        { //Set all the gl data
            var it = self.meshmap.valueIterator();
            while (it.next()) |item| {
                item.*.mesh.setData();
            }
        }
        mesh_build_time.end();
        mesh_build_time.log("Mesh build time");
    }

    pub fn getOrPutMeshBatch(self: *Self, res_id: vpk.VpkResId) !*MeshBatch {
        const res = try self.meshmap.getOrPut(res_id);
        if (!res.found_existing) {
            const tex = try self.getTexture(res_id);
            res.value_ptr.* = try self.alloc.create(MeshBatch);
            res.value_ptr.*.* = MeshBatch.init(self.alloc, res_id, tex);
            try self.async_asset_load.addNotify(res_id, &res.value_ptr.*.notify_vt);
        }
        return res.value_ptr.*;
    }

    pub fn attachSolid(self: *Self, solid_id: EcsT.Id, parent_id: EcsT.Id) !void {
        if (try self.ecs.getOptPtr(parent_id, .entity)) |ent| {
            var found = false;
            for (ent.solids.items) |item| {
                if (item == solid_id) {
                    found = true;
                    break;
                }
            }
            if (!found)
                try ent.solids.append(solid_id);
        }
    }

    ///Given a csg defined solid, convert to mesh and store.
    pub fn putSolidFromVmf(self: *Self, solid: vmf.Solid, group_id: ?GroupId) !void {
        const vis_override = if (self.hacky_extra_vmf.override_vis_group) |n| try self.visgroups.getOrPutTopLevelGroup(n) else null;
        const vis_mask = if (vis_override) |vo| self.visgroups.getMask(&.{vo}) else try self.visgroups.getMaskFromEditorInfo(&solid.editor);
        const new = try self.ecs.createEntity();
        try self.ecs.attach(new, .editor_info, .{ .vis_mask = vis_mask });
        const newsolid = try self.csgctx.genMesh2(
            solid.side,
            self.alloc,
            &self.string_storage,
            self,
            //@intCast(self.set.sparse.items.len),
        );
        if (group_id) |gid| {
            try self.ecs.attach(new, .group, .{ .id = gid });
        }
        var opt_disps: ?ecs.Displacements = null;

        for (solid.side, 0..) |*side, s_i| {
            const tex = try self.loadTextureFromVpk(side.material);
            const res = try self.getOrPutMeshBatch(tex.res_id);
            try res.contains.put(new, {});

            if (side.dispinfo.power != -1) {
                if (opt_disps == null)
                    opt_disps = try ecs.Displacements.init(self.alloc, solid.side.len);
                //for (newsolid.sides.items) |*sp|
                //    sp.Displacement_id = true;
                //const disp_id = try self.ecs.createEntity();
                var disp_gen = try Displacement.initFromVmf(self.alloc, tex.res_id, s_i, &side.dispinfo);
                try disp_gen.setStartI(&newsolid, self, side.dispinfo.startposition.v);
                try disp_gen.genVerts(&newsolid, self);
                try opt_disps.?.put(disp_gen, s_i);

                //try res.contains.put(disp_id, {});
                if (false) { //dump to obj
                    std.debug.print("o disp\n", .{});
                    for (disp_gen.verts.items) |vert| {
                        std.debug.print("v {d} {d} {d}\n", .{ vert.x(), vert.y(), vert.z() });
                    }
                    for (0..@divExact(disp_gen.index.items.len, 3)) |i| {
                        std.debug.print("f {d} {d} {d}\n", .{
                            disp_gen.index.items[(i * 3) + 0] + 1,
                            disp_gen.index.items[(i * 3) + 1] + 1,
                            disp_gen.index.items[(i * 3) + 2] + 1,
                        });
                    }
                }

                //try self.ecs.attach(disp_id, .displacement, disp_gen);
            }
        }
        try self.ecs.attach(new, .solid, newsolid);
        try self.ecs.attach(new, .bounding_box, .{});
        if (opt_disps) |disps|
            try self.ecs.attach(new, .displacements, disps);
        //try self.set.insert(newsolid.id, newsolid);
    }

    pub fn screenRay(self: *Self, screen_area: graph.Rect, view_3d: Mat4) []const raycast.RcastItem {
        const rc = util3d.screenSpaceRay(
            screen_area.dim(),
            if (self.panes.grab.was_grabbed) screen_area.center() else self.edit_state.mpos,
            view_3d,
        );
        return self.rayctx.findNearestSolid(&self.ecs, rc[0], rc[1], &self.csgctx, false) catch &.{};
    }

    pub fn getCurrentTool(self: *Self) ?*tool_def.i3DTool {
        if (self.edit_state.__tool_index >= self.tools.vtables.items.len)
            return null;
        return self.tools.vtables.items[self.edit_state.__tool_index];
    }

    pub fn setTool(self: *Self, new_tool: usize) void {
        if (new_tool >= self.tools.vtables.items.len) {
            log.warn("tring to set invalid tool, ignoring", .{});
            return;
        }
        self.gui_crap.tool_changed = true;
        if (self.edit_state.__tool_index == new_tool) {
            if (self.getCurrentTool()) |vt| {
                if (vt.event_fn) |evf|
                    evf(vt, .reFocus, self);
            }
            return;
        } else {
            if (self.getCurrentTool()) |old_vt| {
                if (old_vt.event_fn) |evf| {
                    evf(old_vt, .unFocus, self);
                }
            }
            self.edit_state.__tool_index = new_tool;
            if (self.getCurrentTool()) |vt| {
                if (vt.event_fn) |evf| {
                    evf(vt, .focus, self);
                }
            }
        }
    }

    pub fn initNewMap(self: *Self) !void {
        try self.skybox.loadSky(try self.storeString("sky_day01_01"), &self.vpkctx);
        try self.visgroups.putDefaultVisGroups();
        self.has_loaded_map = true;
    }

    fn loadRatmap(self: *Self, path: std.fs.Dir, filename: []const u8, loadctx: *LoadCtx) !void {
        const in_file = try path.openFile(filename, .{});
        defer in_file.close();
        const slice = try in_file.reader().readAllAlloc(self.alloc, std.math.maxInt(usize));
        defer self.alloc.free(slice);
        var fname_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var lname_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var fbs = std.io.FixedBufferStream([]const u8){ .buffer = slice, .pos = 0 };
        var tar_it = std.tar.iterator(fbs.reader(), .{
            .file_name_buffer = &fname_buffer,
            .link_name_buffer = &lname_buffer,
        });
        while (try tar_it.next()) |file| {
            if (std.mem.eql(u8, file.name, "map.json.gz")) {
                var unzipped = std.ArrayList(u8).init(self.alloc);
                defer unzipped.deinit();
                try std.compress.gzip.decompress(file.reader(), unzipped.writer());

                try self.loadJson(unzipped.items, loadctx, filename);

                continue;
            }
        }
    }

    pub fn loadMap(self: *Self, path: std.fs.Dir, filename: []const u8, loadctx: *LoadCtx) !void {
        loadctx.printCb("Loading map {s}", .{filename});
        const endsWith = std.mem.endsWith;
        var ext: []const u8 = "";
        if (endsWith(u8, filename, ".ratmap")) {
            ext = ".ratmap";
            try self.loadRatmap(path, filename, loadctx);
        } else if (endsWith(u8, filename, ".json")) {
            ext = ".json";
            try self.loadJsonFile(path, filename, loadctx);
        } else if (endsWith(u8, filename, ".vmf")) {
            ext = ".vmf";
            try self.loadVmf(path, filename, loadctx);
        } else {
            return error.unknownMapExtension;
        }

        self.setWindowTitle(.{ "", self.loaded_map_name orelse "unnamed map" });

        { //TODO MOVE TO SAVE MAP INSTEAD?
            var recent = std.ArrayList([]const u8).init(self.alloc);
            defer recent.deinit();
            const aa = self.frame_arena.allocator();
            const out_name = try path.realpathAlloc(aa, filename);
            if (self.dirs.config.openFile("recent_maps.txt", .{})) |recent_list| { //Keep track of recent maps
                defer recent_list.close();

                const slice = try recent_list.reader().readAllAlloc(self.alloc, std.math.maxInt(usize));
                defer self.alloc.free(slice);
                var it = std.mem.tokenizeScalar(u8, slice, '\n');
                while (it.next()) |filen| {
                    if (std.fs.cwd().openFile(filen, .{})) |recent_map| {
                        //const qoi_data = json_map.getFileFromTar(recent_map,"thumbnail.qoi") catch continue;
                        recent_map.close();
                        try recent.append(try aa.dupe(u8, filen));
                    } else |_| {}
                }
            } else |_| {}

            const out_ = out_name[0 .. out_name.len - ext.len];
            const out_rat = try self.printScratch("{s}.ratmap", .{out_});
            for (recent.items, 0..) |rec, i| {
                if (std.mem.eql(u8, rec, out_rat)) {
                    _ = recent.orderedRemove(i);
                    break;
                }
            }

            try recent.insert(0, out_rat);
            if (self.dirs.config.createFile("recent_maps.txt", .{})) |recent_out| {
                defer recent_out.close();
                for (recent.items) |rec| {
                    try recent_out.writer().print("{s}\n", .{rec});
                }
            } else |_| {}
        }
        //try self.visgroups.putDefaultVisGroups();
    }

    fn loadJsonFile(self: *Self, path: std.fs.Dir, filename: []const u8, loadctx: *LoadCtx) !void {
        const infile = try path.openFile(filename, .{});
        defer infile.close();

        const slice = try infile.reader().readAllAlloc(self.alloc, std.math.maxInt(usize));
        defer self.alloc.free(slice);

        try self.loadJson(slice, loadctx, filename);
    }

    fn loadJson(self: *Self, slice: []const u8, loadctx: *LoadCtx, filename: []const u8) !void {
        if (self.has_loaded_map) {
            log.err("Map already loaded", .{});
            return error.multiMapLoadNotSupported;
        }
        defer self.has_loaded_map = true;
        var timer = try std.time.Timer.start();
        defer log.info("Loaded json in {d}ms", .{timer.read() / std.time.ns_per_ms});

        const jsonctx = json_map.InitFromJsonCtx{
            .alloc = self.alloc,
            .str_store = &self.string_storage,
        };
        var parsed = try json_map.loadJson(jsonctx, slice, loadctx, &self.ecs, &self.vpkctx, &self.groups);
        defer parsed.deinit();

        try self.setMapName(filename);

        try self.skybox.loadSky(try self.storeString(parsed.value.sky_name), &self.vpkctx);
        parsed.value.editor.cam.setCam(&self.draw_state.cam3d);
        self.edit_state.map_version = parsed.value.editor.map_version;
        if (parsed.value.extra == .object) {
            const ex = &parsed.value.extra;
            if (std.json.parseFromValue(struct { recent_mat: [][]const u8 }, self.alloc, ex.*, .{})) |v| {
                defer v.deinit();
                for (v.value.recent_mat) |mat| {
                    if (try self.vpkctx.resolveId(.{ .name = mat }, false)) |id| {
                        try self.asset_browser.recent_mats.put(id.id);
                    }
                }
                if (self.asset_browser.recent_mats.list.items.len > 0) {
                    self.asset_browser.selected_mat_vpk_id = self.asset_browser.recent_mats.list.items[0];
                }
            } else |_| {} //This data is not essential to parse
        }

        try self.visgroups.insertVisgroupsFromJson(parsed.value.visgroup);

        loadctx.cb("Building meshes");
        try self.rebuildAllDependentState();
    }

    //TODO write a vmf -> json utility like jsonToVmf.zig
    //Then, only have a single function to load serialized data into engine "loadJson"
    fn loadVmf(self: *Self, path: std.fs.Dir, filename: []const u8, loadctx: *LoadCtx) !void {
        const vis_override = if (self.hacky_extra_vmf.override_vis_group) |n| try self.visgroups.getOrPutTopLevelGroup(n) else null;
        self.has_loaded_map = true;
        if (false and self.has_loaded_map) {
            log.err("Map already loaded", .{});
            return error.multiMapLoadNotSupported;
        }
        var timer = try std.time.Timer.start();
        const infile = util.openFileFatal(path, filename, .{}, "");
        defer infile.close();
        defer log.info("Loaded vmf in {d}ms", .{timer.read() / std.time.ns_per_ms});

        const slice = try infile.reader().readAllAlloc(self.alloc, std.math.maxInt(usize));
        defer self.alloc.free(slice);
        var aa = std.heap.ArenaAllocator.init(self.alloc);
        var obj = try vdf.parse(self.alloc, slice);
        defer obj.deinit();
        loadctx.cb("vmf parsed");
        try self.setMapName(filename);
        const vmf_ = try vdf.fromValue(vmf.Vmf, &.{ .obj = &obj.value }, aa.allocator(), null);
        if (vis_override == null)
            try self.visgroups.buildMappingFromVmf(vmf_.visgroups, null);
        try self.skybox.loadSky(try self.storeString(vmf_.world.skyname), &self.vpkctx);
        {
            loadctx.expected_cb = vmf_.world.solid.len + vmf_.entity.len + 10;
            var gen_timer = try std.time.Timer.start();
            for (vmf_.world.solid, 0..) |solid, si| {
                try self.putSolidFromVmf(solid, null);
                loadctx.printCb("csg generated {d} / {d}", .{ si, vmf_.world.solid.len });
            }
            for (vmf_.entity, 0..) |ent, ei| {
                loadctx.printCb("ent generated {d} / {d}", .{ ei, vmf_.entity.len });
                const new = try self.ecs.createEntity();
                const group_id = if (ent.solid.len > 0) try self.groups.newGroup(new) else 0;
                const vis_mask = if (vis_override) |vo| self.visgroups.getMask(&.{vo}) else try self.visgroups.getMaskFromEditorInfo(&ent.editor);
                try self.ecs.attach(new, .editor_info, .{ .vis_mask = vis_mask });
                for (ent.solid) |solid|
                    try self.putSolidFromVmf(solid, group_id);
                {
                    var bb = AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
                    if (group_id != 0) //Group owners have no bounds
                        bb.b = bb.a;
                    var model_id: ?vpk.VpkResId = null;
                    if (ent.rest_kvs.count() > 0) {
                        var kvs = KeyValues.init(self.alloc);
                        var it = ent.rest_kvs.iterator();
                        while (it.next()) |item| {
                            //We use the no notify method because all notifiable fields are absorbed by vmf.entity
                            try kvs.putStringNoNotify(try self.storeString(item.key_ptr.*), item.value_ptr.*);
                        }

                        if (kvs.getString("model")) |model| {
                            if (model.len > 0) {
                                model_id = self.modelIdFromName(model) catch null;
                                if (self.loadModel(model)) |m| {
                                    _ = m;
                                } else |err| {
                                    log.err("Load model failed with {}", .{err});
                                }
                            }
                        }

                        try self.ecs.attach(new, .key_values, kvs);
                    }
                    bb.setFromOrigin(ent.origin.v);
                    try self.ecs.attach(new, .entity, .{
                        .origin = ent.origin.v,
                        .angle = ent.angles.v,
                        .class = try self.storeString(ent.classname),
                        ._model_id = model_id,
                        ._sprite = null,
                    });

                    try self.ecs.attach(new, .bounding_box, bb);

                    if (ent.connections.is_init) {
                        const new_con = try ecs.Connections.initFromVmf(self.alloc, &ent.connections, &self.string_storage);
                        try self.ecs.attach(new, .connections, new_con);
                    }

                    {
                        var new_ent = try self.ecs.getPtr(new, .entity);
                        try new_ent.setClass(self, ent.classname, new);
                        try new_ent.setAngle(self, new, new_ent.angle);
                    }
                }

                //try procSolid(&editor.csgctx, alloc, solid, &editor.meshmap, &editor.vpkctx);
            }
            try self.rebuildAllDependentState();
            const nm = self.meshmap.count();
            const whole_time = gen_timer.read();

            log.info("csg took {d} {d:.2} us", .{ nm, csg.gen_time / std.time.ns_per_us / nm });
            log.info("Generated {d} meshes in {d:.2} ms", .{ nm, whole_time / std.time.ns_per_ms });
        }
        aa.deinit();
        loadctx.cb("csg generated");
    }

    pub fn drawToolbar(self: *Self, area: graph.Rect, draw: *DrawCtx, font: *graph.FontInterface, fh: f32) void {
        const start = area.pos();
        const w = fh * 5;
        const tool_index = self.edit_state.__tool_index;
        for (self.tools.vtables.items, 0..) |tool, i| {
            const fi: f32 = @floatFromInt(i);
            const rec = graph.Rec(start.x + fi * w, start.y, w, w);
            tool.tool_icon_fn(tool, draw, self, rec);
            var buf: [32]u8 = undefined;
            const n = if (i < self.config.keys.tool.items.len) self.config.keys.tool.items[i].b.nameFull(&buf) else "NONE";
            draw.textClipped(rec, "{s}", .{n}, .{ .px_size = fh, .font = font, .color = 0xff }, .left);
            if (tool_index == i) {
                draw.rectBorder(rec, 3, 0x00ff00ff);
            }
        }
    }

    fn modelIdFromName(self: *Self, mdl_name: []const u8) !?vpk.VpkResId {
        const mdln = blk: {
            if (std.mem.endsWith(u8, mdl_name, ".mdl"))
                break :blk mdl_name[0 .. mdl_name.len - 4];
            break :blk mdl_name;
        };

        return try self.vpkctx.getResourceIdFmt("mdl", "{s}", .{mdln}, true);
    }

    pub fn loadModel(self: *Self, model_name: []const u8) !vpk.VpkResId {
        const mod = try self.storeString(model_name);
        const res_id = try self.modelIdFromName(mod) orelse return error.noMdl;
        if (self.models.get(res_id)) |_| return res_id; //Don't load model twice!
        try self.models.put(res_id, Model.initEmpty(self.alloc));
        try self.async_asset_load.loadModel(res_id, mod, &self.vpkctx);
        return res_id;
    }

    pub fn loadModelFromId(self: *Self, res_id: vpk.VpkResId) !void {
        if (self.models.get(res_id)) |_| return; //Don't load model twice!
        if (self.vpkctx.namesFromId(res_id)) |names| {
            const mod = try self.storeString(try self.printScratch("{s}/{s}.{s}", .{ names.path, names.name, names.ext }));
            try self.models.put(res_id, Model.initEmpty(self.alloc));

            try self.async_asset_load.loadModel(res_id, mod, &self.vpkctx);
        }
    }

    pub fn storeString(self: *Self, string: []const u8) ![]const u8 {
        return try self.string_storage.store(string);
    }

    pub fn getTexture(self: *Self, res_id: vpk.VpkResId) !graph.Texture {
        if (self.textures.get(res_id)) |tex| return tex;

        try self.loadTexture(res_id);

        return missingTexture();
    }

    pub fn loadTexture(self: *Self, res_id: vpk.VpkResId) !void {
        if (self.textures.get(res_id)) |_| return;

        { //track tools
            if (self.vpkctx.namesFromId(res_id)) |name| {
                if (std.mem.startsWith(u8, name.path, "materials/tools")) {
                    try self.tool_res_map.put(res_id, {});
                }
            }
        }

        try self.textures.put(res_id, missingTexture());
        try self.async_asset_load.loadTexture(res_id, &self.vpkctx);
    }

    pub fn loadTextureFromVpk(self: *Self, material: []const u8) !struct { tex: graph.Texture, res_id: vpk.VpkResId } {
        const res_id = try self.vpkctx.getResourceIdFmt("vmt", "materials/{s}", .{material}, true) orelse return .{ .tex = missingTexture(), .res_id = 0 };
        if (self.textures.get(res_id)) |tex| return .{ .tex = tex, .res_id = res_id };

        try self.loadTexture(res_id);

        return .{ .tex = missingTexture(), .res_id = res_id };
    }

    pub fn camRay(self: *Self, area: graph.Rect, view: Mat4) [2]Vec3 {
        return util3d.screenSpaceRay(
            area.dim(),
            if (self.panes.grab.was_grabbed) area.center() else self.edit_state.mpos,
            view,
        );
    }

    pub fn printScratch(self: *Self, comptime str: []const u8, args: anytype) ![]const u8 {
        self.scratch_buf.clearRetainingCapacity();
        try self.scratch_buf.writer().print(str, args);
        return self.scratch_buf.items;
    }

    pub fn printScratchZ(self: *Self, comptime str: []const u8, args: anytype) ![]const u8 {
        _ = try self.printScratch(str, args);
        try self.scratch_buf.append(0);
        return self.scratch_buf.items;
    }

    pub fn saveAndNotify(self: *Self, basename: []const u8, path: []const u8) !void {
        self.edit_state.map_version += 1;
        var timer = try std.time.Timer.start();
        try self.notify("saving: {s}{s}", .{ path, basename }, 0xfca73fff);

        const name = try self.printScratch("{s}{s}.ratmap", .{ path, basename });
        //TODO make copy of existing map incase something goes wrong

        const out_file = try std.fs.cwd().createFile(name, .{});

        var jwriter = std.ArrayList(u8).init(self.alloc);

        if (self.writeToJson(jwriter.writer())) {
            try self.notify(" saved: {s}{s} in {d:.1}ms", .{ path, basename, timer.read() / std.time.ns_per_ms }, 0xff00ff);
            self.edit_state.saved_at_delta = self.undoctx.delta_counter;
            self.edit_state.was_saved = true;

            self.setWindowTitle(.{ "", self.loaded_map_name orelse "unnamed_map" });

            const sz = 256;
            var bmp = try graph.Bitmap.initBlank(self.alloc, sz, sz, .rgb_8);
            //Hack, stores the last frames wdim
            //If the 3d viewport is not at 0,0, it will be incorrect
            const screen_area = self.draw_state.screen_space_text_ctx.screen_dimensions;
            { //Try to create a thumbnail

                var rb = try graph.RenderTexture.init(sz, sz);
                defer rb.deinit();
                graph.c.glBlitNamedFramebuffer(
                    0,
                    rb.fb,
                    0,
                    0,
                    @intFromFloat(screen_area.x),
                    @intFromFloat(screen_area.y),
                    0,
                    sz,
                    sz,
                    0,
                    graph.c.GL_COLOR_BUFFER_BIT,
                    graph.c.GL_LINEAR,
                );
                graph.c.glBindFramebuffer(graph.c.GL_FRAMEBUFFER, rb.fb);
                graph.c.glReadPixels(0, 0, sz, sz, graph.c.GL_RGB, graph.c.GL_UNSIGNED_BYTE, &bmp.data.items[0]);
            }

            try async_util.CompressAndSave.spawn(
                self.alloc,
                &self.async_asset_load,
                jwriter,
                out_file,
                bmp,
            );
        } else |err| {
            jwriter.deinit();
            out_file.close();
            log.err("writeToJson failed ! {}", .{err});
            try self.notify("save failed!: {}", .{err}, 0xff0000ff);
        }
    }

    pub fn notify(self: *Self, comptime fmt: []const u8, args: anytype, color: u32) !void {
        log.info(fmt, args);
        try self.notifier.submitNotify(fmt, args, color);
    }

    pub fn update(self: *Self, win: *graph.SDL.Window) !void {
        //TODO in the future, set app state to 'autosaving' and send saving to worker thread
        if (self.edit_state.saved_at_delta == self.undoctx.delta_counter or self.edit_state.autosaved_at_delta == self.undoctx.delta_counter) {
            self.autosaver.resetTimer(); //Don't autosave if the map is already saved
        } else {
            if (self.edit_state.was_saved) {
                self.edit_state.was_saved = false;
                self.setWindowTitle(.{ "*", self.loaded_map_name orelse "unnamed_map" });
            }
        }
        if (self.autosaver.shouldSave()) {
            self.edit_state.autosaved_at_delta = self.undoctx.delta_counter;
            const basename = self.loaded_map_name orelse "unnamed_map";
            log.info("Autosaving {s}", .{basename});
            self.autosaver.resetTimer();
            if (self.autosaver.getSaveFileAndPrune(self.dirs.autosave, basename, ".json")) |out_file| {
                defer out_file.close();
                var bwr = std.io.bufferedWriter(out_file.writer());
                defer bwr.flush() catch {};
                self.writeToJson(bwr.writer()) catch |err| {
                    log.err("writeToJson failed ! {}", .{err});
                    try self.notify("Autosave failed!: {}", .{err}, 0xff0000ff);
                };
            } else |err| {
                log.err("Autosave failed with error {}", .{err});
                try self.notify("Autosave failed!: {}", .{err}, 0xff0000ff);
            }
            try self.notify("Autosaved: {s}", .{basename}, 0x00ff00ff);
        }
        if (win.isBindState(self.config.keys.save.b, .rising)) {
            if (self.loaded_map_name) |basename| {
                self.saveAndNotify(basename, self.loaded_map_path orelse "") catch |err| {
                    try self.notify("Failed saving map: {!}", .{err}, 0xff0000ff);
                };
            } else {
                try async_util.SdlFileData.spawn(self.alloc, &self.async_asset_load, .save_map);
            }
        }
        if (win.isBindState(self.config.keys.save_new.b, .rising)) {
            try async_util.SdlFileData.spawn(self.alloc, &self.async_asset_load, .save_map);
        }
        if (win.isBindState(self.config.keys.build_map.b, .rising)) {
            blk: {
                const lp = self.loaded_map_path orelse break :blk;
                const lm = self.loaded_map_name orelse break :blk;
                if (self.saveAndNotify(lm, lp)) {
                    var build_arena = std.heap.ArenaAllocator.init(self.alloc);
                    defer build_arena.deinit();
                    if (jsontovmf(
                        build_arena.allocator(),
                        &self.ecs,
                        self.skybox.sky_name,
                        &self.vpkctx,
                        &self.groups,
                        null,
                    )) {
                        try self.notify("Exported map to vmf", .{}, 0x00ff00ff);

                        try async_util.MapCompile.spawn(self.alloc, &self.async_asset_load, .{
                            .vmf = "dump.vmf",
                            .gamedir_pre = self.game_conf.mapbuilder.game_dir,
                            .exedir_pre = self.game_conf.mapbuilder.exe_dir,
                            .gamename = self.game_conf.mapbuilder.game_name,

                            .outputdir = self.game_conf.mapbuilder.output_dir,
                            .cwd = self.dirs.cwd,
                            .tmpdir = self.game_conf.mapbuilder.tmp_dir,
                        });
                    } else |err| {
                        try self.notify("Failed exporting map to vmf {!}", .{err}, 0xff0000ff);
                    }
                } else |err| {
                    try self.notify("Failed saving map: {!}", .{err}, 0xff0000ff);
                }
            }
        }

        _ = self.frame_arena.reset(.retain_capacity);
        //self.edit_state.last_frame_tool_index = self.edit_state.tool_index;
        const MAX_UPDATE_TIME = std.time.ns_per_ms * 16;
        var timer = try std.time.Timer.start();
        //defer std.debug.print("UPDATE {d} ms\n", .{timer.read() / std.time.ns_per_ms});
        self.draw_state.init_asset_count = 0;
        var tcount: usize = 0;
        {
            self.async_asset_load.notifyCompletedGeneric(self);
            self.async_asset_load.completed_mutex.lock();
            defer self.async_asset_load.completed_mutex.unlock();
            tcount = self.async_asset_load.completed.items.len;
            var num_rm_tex: usize = 0;
            for (self.async_asset_load.completed.items) |*completed| {
                if (completed.data.deinitToTexture(self.async_asset_load.alloc)) |texture| {
                    try self.textures.put(completed.vpk_res_id, texture);
                    self.async_asset_load.notifyTexture(completed.vpk_res_id, self);
                } else |err| {
                    log.err("texture init failed with : {}", .{err});
                }

                num_rm_tex += 1;
                const elapsed = timer.read();
                if (elapsed > MAX_UPDATE_TIME)
                    break;
            }
            self.draw_state.init_asset_count += num_rm_tex;
            for (0..num_rm_tex) |_|
                _ = self.async_asset_load.completed.orderedRemove(0);

            var completed_ids = std.ArrayList(vpk.VpkResId).init(self.frame_arena.allocator());
            var num_removed: usize = 0;
            for (self.async_asset_load.completed_models.items) |*completed| {
                var model = completed.mesh;
                model.initGl();
                try self.models.put(completed.res_id, .{ .mesh = model });
                for (completed.texture_ids.items) |tid| {
                    try self.async_asset_load.addNotify(tid, &completed.mesh.notify_vt);
                }
                for (model.meshes.items) |*mesh| {
                    const t = try self.getTexture(mesh.tex_res_id);
                    mesh.texture_id = t.id;
                }
                try completed_ids.append(completed.res_id);
                completed.texture_ids.deinit();
                num_removed += 1;

                const elapsed = timer.read();
                if (elapsed > MAX_UPDATE_TIME)
                    break;
            }
            self.draw_state.init_asset_count += num_removed;
            for (0..num_removed) |_|
                _ = self.async_asset_load.completed_models.orderedRemove(0);

            var m_it = self.ecs.iterator(.entity);
            while (m_it.next()) |ent| {
                if (ent._model_id) |mid| {
                    if (std.mem.indexOfScalar(vpk.VpkResId, completed_ids.items, mid) != null) {
                        try ent.setModel(self, m_it.i, .{ .id = mid }, false);
                    }
                }
            }
        }
        if (tcount > 0) {
            self.draw_state.meshes_dirty = true;
        }

        if (self.draw_state.meshes_dirty) {
            self.draw_state.meshes_dirty = false;
            try self.rebuildMeshesIfDirty();
        }
    }

    pub fn handleMisc3DKeys(ed: *Self, tabs: anytype) void {
        const config = &ed.config;
        const ds = &ed.draw_state;

        { //key binding stuff
            for (config.keys.workspace.items, 0..) |b, i| {
                if (ed.win.isBindState(b.b, .rising))
                    ds.tab_index = i;
            }

            if (ed.isBindState(config.keys.grid_inc.b, .rising))
                ed.grid.double();
            if (ed.isBindState(config.keys.grid_dec.b, .rising))
                ed.grid.half();
            ds.tab_index = @min(ds.tab_index, tabs.len - 1);

            {
                for (config.keys.tool.items, 0..) |b, i| {
                    if (ed.isBindState(b.b, .rising)) {
                        ed.setTool(i);
                    }
                }
            }
        }
    }
};

pub const LoadCtx = struct {

    //No need for high fps when loading. Only repaint this often.
    refresh_period_ms: usize = 66,

    buffer: [256]u8 = undefined,
    timer: std.time.Timer,
    draw: *graph.ImmediateDrawingContext,
    win: *graph.SDL.Window,
    font: *graph.Font,
    splash: graph.Texture,
    draw_splash: bool = true,
    gtimer: std.time.Timer,
    time: u64 = 0,

    expected_cb: usize = 1, // these are used to update progress bar
    cb_count: usize = 0,

    pub fn printCb(self: *@This(), comptime fmt: []const u8, args: anytype) void {
        self.cb_count += 1;
        if (self.timer.read() / std.time.ns_per_ms < self.refresh_period_ms) {
            return;
        }
        self.cb_count -= 1;
        var fbs = std.io.FixedBufferStream([]u8){ .buffer = &self.buffer, .pos = 0 };
        fbs.writer().print(fmt, args) catch return;
        self.cb(fbs.getWritten());
    }

    pub fn addExpected(self: *@This(), addition: usize) void {
        self.expected_cb += addition;
    }

    pub fn cb(self: *@This(), message: []const u8) void {
        self.cb_count += 1;
        if (self.timer.read() / std.time.ns_per_ms < self.refresh_period_ms) {
            return;
        }
        self.timer.reset();
        self.win.pumpEvents(.poll);
        self.draw.begin(0x678caaff, self.win.screen_dimensions.toF()) catch return;
        //self.draw.text(.{ .x = 0, .y = 0 }, message, &self.font.font, 100, 0xffffffff);
        const perc: f32 = @as(f32, @floatFromInt(self.cb_count)) / @as(f32, @floatFromInt(self.expected_cb));
        self.drawSplash(perc, message);
        self.draw.end(null) catch return;
        self.win.swap(); //So the window doesn't look too broken while loading
    }

    pub fn drawSplash(self: *@This(), perc: f32, message: []const u8) void {
        if (DISABLE_SPLASH)
            return;
        const cx = self.draw.screen_dimensions.x / 2;
        const cy = self.draw.screen_dimensions.y / 2;
        const w: f32 = @floatFromInt(self.splash.w);
        const h: f32 = @floatFromInt(self.splash.h);
        const sr = graph.Rec(cx - w / 2, cy - h / 2, w, h);
        const tbox = graph.Rec(sr.x + 10, sr.y + 156, 420, 22);
        const pbar = graph.Rec(sr.x + 8, sr.y + 172, 430, 6);
        self.draw.rectTex(sr, self.splash.rect(), self.splash);
        self.draw.textClipped(
            tbox,
            "{s}",
            .{message},
            .{ .px_size = 15, .color = 0xff, .font = &self.font.font },
            .left,
        );
        const p = @min(1, perc);
        self.draw.rect(pbar.split(.vertical, pbar.w * p)[0], 0xf7a41dff);
    }

    pub fn loadedSplash(self: *@This(), end: bool) !void {
        if (DISABLE_SPLASH)
            return;
        if (self.draw_splash) {
            var fbs = std.io.FixedBufferStream([]u8){ .buffer = &self.buffer, .pos = 0 };
            try fbs.writer().print("v{s} Loaded in {d:.2} ms. {s}.{s}.{s}", .{
                version,
                self.time / std.time.ns_per_ms,
                @tagName(builtin.mode),
                @tagName(builtin.target.os.tag),
                @tagName(builtin.target.cpu.arch),
            });
            graph.c.glEnable(graph.c.GL_BLEND);
            //graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
            self.draw.rect(graph.Rec(0, 0, self.draw.screen_dimensions.x, self.draw.screen_dimensions.y), 0x88);
            self.drawSplash(1.0, fbs.getWritten());
            if (end)
                self.draw_splash = false;
        }
    }
};

/// Returns the infamous pink and black checker texture.
pub fn missingTexture() graph.Texture {
    const static = struct {
        const m = [3]u8{ 0xfc, 0x05, 0xbe };
        const b = [3]u8{ 0x0, 0x0, 0x0 };
        const data = m ++ b ++ b ++ m;
        var texture: ?graph.Texture = null;
    };

    if (static.texture == null) {
        static.texture = graph.Texture.initFromBuffer(
            &static.data,
            2,
            2,
            .{
                .pixel_format = graph.c.GL_RGB,
                .pixel_store_alignment = 1,
                .mag_filter = graph.c.GL_NEAREST,
            },
        );
        static.texture.?.w = 400; //Zoom the texture out
        static.texture.?.h = 400;
    }
    return static.texture.?;
}

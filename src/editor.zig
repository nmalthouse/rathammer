const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const Mat4 = graph.za.Mat4;
const SparseSet = graph.SparseSet;
const meshutil = graph.meshutil;
const colors = @import("colors.zig").colors;
const vmf = @import("vmf.zig");
const vdf = @import("vdf.zig");
const vpk = @import("vpk.zig");
const csg = @import("csg.zig");
const vtf = @import("vtf.zig");
const fgd = @import("fgd.zig");
const vvd = @import("vvd.zig");
const uuid = @import("uuidlib");
const clipper = @import("clip_solid.zig");
const gameinfo = @import("gameinfo.zig");
const profile = @import("profile.zig");
const RGui = graph.RGui;
const StringStorage = @import("string.zig").StringStorage;
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
const L = @import("locale.zig");
const Selection = @import("selection.zig");
const autovis = @import("autovis.zig");
const Layer = @import("layer.zig");
const jsontovmf = @import("jsonToVmf.zig").jsontovmf;
const ecs = @import("ecs.zig");
const json_map = @import("json_map.zig");
const DISABLE_SPLASH = false;
const GroupId = ecs.Groups.GroupId;
const eviews = @import("editor_views.zig");
const path_guess = @import("fs.zig");
const shell = @import("shell.zig");
const grid_stuff = @import("grid.zig");
const class_tracker = @import("class_track.zig");
const version = @import("version.zig").version;
const app = @import("app.zig");
const action = @import("actions.zig");
const rpc = @import("rpc/server.zig");

const async_util = @import("async.zig");
const util3d = graph.util_3d;
const pointfile = @import("pointfile.zig");
const def_render = graph.def_render;

const MAPFMT = " {s}{s} - RatHammer";
var WINDOW_TITLE_BUFFER: [256]u8 = undefined;
const Game = @import("game.zig");

const builtin = @import("builtin");
const WINDOZE = builtin.target.os.tag == .windows;

pub const DrawMode = enum {
    shaded,
    lightmap_scale,
};

pub const Model = struct {
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

    app_update: RGui.app.iUpdate = .{ .pre_update = preUpdate },

    /// Only real state is a timer, has helper functions for naming and pruning autosaves.
    autosaver: Autosaver,

    /// These have no real state, just exist to prevent excessive memory allocation.
    rayctx: raycast.Ctx,
    csgctx: csg.Context,
    clipctx: clipper.ClipCtx,

    /// Manages mounting of vpks and assigning a unique id to all resource string paths.
    vpkctx: vpk.Context,

    scratch_buf: std.ArrayList(u8) = .{},
    alloc: std.mem.Allocator,
    _selection_scratch: std.ArrayListUnmanaged(EcsT.Id) = .{},

    /// Stores all the mesh data for solids.
    meshmap: ecs.MeshMap,

    /// Store static strings for the lifetime of application
    string_storage: StringStorage,

    /// Stores all the world state, solids, entities, disp, etc.
    ecs: EcsT,
    groups: ecs.Groups,

    /// Stores undo state, most changes to world state (ecs) should be done through a undo vtable
    undoctx: undo.UndoContext,

    layers: Layer.Context,

    omit_solids: std.AutoArrayHashMapUnmanaged(EcsT.Id, bool) = .{},

    /// This sucks, clean it up
    fgd_ctx: fgd.EntCtx,

    /// These maps map vpkids to their respective resource,
    /// when fetching a resource with getTexture, etc. Something is always returned. If an entry does not exist,
    /// a job is submitted to the load thread pool and a placeholder is inserted into the map and returned
    materials: std.AutoHashMap(vpk.VpkResId, ecs.Material),
    models: std.AutoHashMap(vpk.VpkResId, Model),

    /// Draw colored text messages to the screen for a short time
    notifier: NotifyCtx,

    /// Gui widget
    asset_browser: assetbrowse.AssetBrowserGui,

    async_asset_load: thread_pool.Context,
    /// Used to track tool txtures, TODO turn this into transparent_map, sticking all $alphatest and $translucent in here for
    /// alpha draw ordering
    tool_res_map: std.AutoHashMap(vpk.VpkResId, void),
    autovis: autovis.VisContext,

    rpcserv: *rpc.RpcServer,

    shell: *shell.CommandCtx,

    loadctx: *LoadCtx,

    eventctx: *app.EventCtx,

    classtrack: class_tracker.Tracker,
    targetname_track: class_tracker.Tracker,

    stack_owns_input: bool = false,
    stack_grabbed_mouse: bool = false,

    tools: tool_def.ToolRegistry,
    _paused: bool = true,
    has_loaded_map: bool = false,

    should_exit: bool = false,

    draw_state: struct {
        mode: DrawMode = .shaded,
        skybox_textures: ?[6]graph.glID = null,
        init_asset_count: usize = 0, //Used to indicate we are loading things

        active_lights: usize = 0,
        draw_outlines: bool = true,

        //draw_displacment_solid: bool = false,

        factor: f32 = 64,
        light_mul: f32 = 0.11,
        const_add: f32 = 0, //Added to light constant factor
        far: f32 = 512 * 64,
        pad: f32 = 164,
        index: usize = 0,
        planes: [4]f32 = [4]f32{ 462, 1300, 4200, 16400 },
        pointfile: ?pointfile.PointFile = null,
        portalfile: ?pointfile.PortalFile = null,
        meshes_dirty: bool = false,

        /// This should be replaced with visgroups, for the most part.
        tog: struct {
            wireframe: bool = false,
            sprite: bool = true,
            models: bool = true,
            skybox: bool = true,

            debug_stats: bool = false,

            model_render_dist: f32 = 512 * 2,
        } = .{},

        cam3d: graph.Camera3D = .{
            .pos = .new(0, 0, 128),
            .up = .z,
            .move_speed = 10,
            .max_move_speed = 100,
            .fwd_back_kind = .planar,

            .near = 1,
            .far = 512 * 64,
        },

        displacement_mode: enum {
            disp_only,
            solid_only,
            both,
        } = .disp_only,

        /// we keep our own so that we can do some draw calls with depth some without.
        ctx: graph.ImmediateDrawingContext,
        screen_space_text_ctx: graph.ImmediateDrawingContext,
    },

    selection: Selection,
    renderer: def_render.Renderer,

    workspaces: struct {
        const WsId = RGui.workspaces.WorkspaceId;

        main_3d_win: RGui.WindowId = .none,
        inspector: RGui.WindowId = .none,
        model_win: RGui.WindowId = .none,

        pause: WsId = .none,
        main: WsId = .none,
        asset: WsId = .none,
        model: WsId = .none,
        main_2d: WsId = .none,

        pre_pause: WsId = .none, //Save ws before we paused
    } = .{},

    edit_state: struct {
        /// destroy 180 billion keyboard worth of pressing ctrl+s to overflow this
        map_version: u64 = 0, //Incremented every save
        autosaved_at_delta: u64 = 0, // Don't keep autosaving the same thing
        saved_at_delta: u64 = 0,
        map_uuid: u128 = 0,
        //Used to get a rising edge to set window title
        was_saved: bool = true,

        manual_hidden_count: usize = 0,
        default_group_entity: enum { none, func_detail } = .func_detail,
        __tool_index: u16 = 0,

        lmouse: ButtonState = .low,
        rmouse: ButtonState = .low,
        mpos: graph.Vec2f = undefined,

        selected_layer: Layer.Id = .none,
        selected_model_vpk_id: ?vpk.VpkResId = null,
        selected_texture_vpk_id: ?vpk.VpkResId = null,

        map_description: std.ArrayList(u8) = .{},

        marquee: struct {
            start: graph.Vec2f = .zero,
        } = .{},
    } = .{},
    grid: grid_stuff.Snap = .{ .s = Vec3.set(16) },

    games: Game.GameList,
    config: Conf.Config,
    conf: *const Conf.ConfigCtx,
    gapp: *RGui.app.GuiApp,
    game_conf: Conf.GameEntry,
    dirs: path_guess.Dirs,

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
    loaded_game_name: ?[]const u8 = null,
    game_loaded: bool = false,

    /// static string
    loaded_skybox_name: []const u8 = "",

    last_exported_obj_name: ?[]const u8 = null,
    last_exported_obj_path: ?[]const u8 = null,

    pub fn setWindowTitle(self: *Self, map_fmt_args: anytype) void {
        var fbs = std.io.FixedBufferStream([]u8){ .buffer = &WINDOW_TITLE_BUFFER, .pos = 0 };
        fbs.writer().print(MAPFMT, map_fmt_args) catch {
            WINDOW_TITLE_BUFFER[0] = 0;
        };
        fbs.writer().writeByte(0) catch {
            WINDOW_TITLE_BUFFER[0] = 0;
        };
        if (!graph.c.SDL_SetWindowTitle(self.gapp.main_window.win, &WINDOW_TITLE_BUFFER[0])) {
            log.err("Failed to set window title", .{});
        }
    }

    // result stored in frame_arena
    pub fn getMapFullPath(self: *Self) ?[]const u8 {
        const lm = self.loaded_map_name orelse return null;
        const lp = self.loaded_map_path orelse return null;

        const aa = self.frame_arena.allocator();
        const name = std.fs.path.join(aa, &.{ lp, self.printScratch("{s}.ratmap", .{lm}) catch return null }) catch return null;
        const full_path = self.dirs.app_cwd.dir.realpathAlloc(aa, name) catch |err| {
            std.debug.print("Realpath failed with {t} on {s}\n", .{ err, name });
            return null;
        };
        return full_path;
    }

    pub fn setMapName(self: *Self, filename: []const u8) !void {
        const split = try util.pathToMapName(filename);

        self.loaded_map_name = try self.storeString(split[1]);
        self.loaded_map_path = try self.storeString(split[0]);
    }

    pub fn setObjName(self: *Self, filename: []const u8) !void {
        const path = std.fs.path.dirname(filename) orelse "";
        const base = std.fs.path.basename(filename);

        const ext = std.fs.path.extension(base);
        const real_base = if (std.mem.eql(u8, ext, "obj")) base else try self.printScratch("{s}.obj", .{base[0 .. base.len - ext.len]});

        self.last_exported_obj_name = try self.storeString(real_base);
        self.last_exported_obj_path = try self.storeString(path);
    }

    pub fn init(
        alloc: std.mem.Allocator,
        num_threads: ?u32,
        config: *const Conf.ConfigCtx,
        args: anytype,
        loadctx: *LoadCtx,
        dirs: path_guess.Dirs,
        gapp: *RGui.app.GuiApp,
    ) !*Self {
        app.EventCtx.SdlEventId = try gapp.main_window.addUserEventCb(app.EventCtx.graph_event_cb);
        shell.RpcEventId = try gapp.main_window.addUserEventCb(shell.rpc_cb);
        const shader_dir = try dirs.app_cwd.dir.openDir("ratgraph/asset/shader", .{});
        var ret = try alloc.create(Context);
        ret.* = .{
            //These are initilized in editor.postInit
            .game_conf = undefined,
            .asset = undefined,
            .asset_atlas = undefined,

            .gapp = gapp,
            .games = .init(alloc),
            .classtrack = .init(alloc),
            .targetname_track = .init(alloc),
            .loadctx = loadctx,
            .notifier = NotifyCtx.init(alloc, 4000),
            .autosaver = try Autosaver.init(config.config.autosave.interval_min * std.time.ms_per_min, config.config.autosave.max, config.config.autosave.enable, alloc),
            .rayctx = raycast.Ctx.init(alloc),
            .frame_arena = std.heap.ArenaAllocator.init(alloc),
            .groups = ecs.Groups.init(alloc),
            .config = config.config,
            .conf = config,
            .alloc = alloc,
            .fgd_ctx = fgd.EntCtx.init(alloc),
            .undoctx = undo.UndoContext.init(alloc),
            .string_storage = try StringStorage.init(alloc),
            .asset_browser = assetbrowse.AssetBrowserGui.init(alloc),
            .tools = tool_def.ToolRegistry.init(alloc),
            .csgctx = try csg.Context.init(alloc),
            .clipctx = clipper.ClipCtx.init(alloc),
            .vpkctx = try vpk.Context.init(alloc),
            .autovis = autovis.VisContext.init(alloc),
            .layers = try Layer.Context.init(alloc),
            .meshmap = ecs.MeshMap.init(alloc),
            .ecs = try EcsT.init(alloc),
            .models = std.AutoHashMap(vpk.VpkResId, Model).init(alloc),
            .async_asset_load = try thread_pool.Context.init(alloc, num_threads),
            .materials = .init(alloc),
            .tool_res_map = std.AutoHashMap(vpk.VpkResId, void).init(alloc),
            .shell = try shell.CommandCtx.create(alloc, ret),
            .renderer = try def_render.Renderer.init(alloc, shader_dir),
            .eventctx = try app.EventCtx.create(alloc),
            .selection = Selection.init(alloc, ret.eventctx),
            .rpcserv = try rpc.RpcServer.create(alloc, ret.shell, shell.RpcEventId),

            .dirs = dirs,

            .draw_state = .{
                .ctx = graph.ImmediateDrawingContext.init(alloc),
                .screen_space_text_ctx = DrawCtx.init(alloc),
            },
        };
        //If an error occurs during initilization it is fatal so there is no reason to clean up resources.
        //Thus we call, defer editor.deinit(); after all is initialized..
        try ret.postInit(args, loadctx);
        return ret;
    }

    /// Called by init
    fn postInit(self: *Self, args: anytype, loadctx: *LoadCtx) !void {
        if (self.config.default_game.len == 0) {
            std.debug.print("config.vdf must specify a default_game!\n", .{});
            return error.incompleteConfig;
        }

        try graph.AssetBake.assetBake(self.alloc, self.dirs.app_cwd.dir, "ratasset", self.dirs.pref, "packed", .{});
        loadctx.cb("Asset's baked");

        self.asset = try graph.AssetBake.AssetMap.initFromManifest(self.alloc, self.dirs.pref, "packed");
        self.asset_atlas = try graph.AssetBake.AssetMap.initTextureFromManifest(self.alloc, self.dirs.pref, "packed");

        //try self.loadGame(args.game orelse self.config.default_game);

        //The order in which these are registered maps to the order 'tool' keybinds are specified in config.vdf
        try self.tools.register(tool_def.Translate, try tool_def.Translate.create(self.alloc, self));
        try self.tools.register(tool_def.TranslateFace, try tool_def.TranslateFace.create(self.alloc));
        try self.tools.register(tool_def.PlaceEntity, try tool_def.PlaceEntity.create(self.alloc));
        try self.tools.register(tool_def.CubeDraw, try tool_def.CubeDraw.create(self.alloc, self));
        try self.tools.register(tool_def.FastFaceManip, try tool_def.FastFaceManip.create(self.alloc, self));
        try self.tools.register(tool_def.TextureTool, try tool_def.TextureTool.create(self.alloc, self));
        try self.tools.register(tool_def.VertexTranslate, try tool_def.VertexTranslate.create(self.alloc, self));
        try self.tools.register(tool_def.Clipping, try tool_def.Clipping.create(self.alloc, self));

        try self.autovis.add(.{ .name = "props", .filter = "prop_", .kind = .class, .match = .startsWith });
        try self.autovis.add(.{ .name = "trigger", .filter = "trigger_", .kind = .class, .match = .startsWith });
        try self.autovis.add(.{ .name = "tools", .filter = "materials/tools", .kind = .texture, .match = .startsWith });
        try self.autovis.add(.{ .name = "func", .filter = "func", .kind = .class, .match = .startsWith });
        try self.autovis.add(.{ .name = "skybox", .filter = "skybox.vmt", .kind = .texture, .match = .endsWith });
        //try self.autovis.add(.{ .name = "models", .filter = "", .kind = .model, .match = .startsWith });
        //try self.autovis.add(.{ .name = "world", .filter = "", .kind = .class, .match = .startsWith, .invert = true });

        if (comptime compile_conf.http_version_check) {
            if (self.config.enable_version_check and args.no_version_check == null) {
                try async_util.CheckVersionHttp.spawn(self.alloc, &self.async_asset_load);
            }
        }
        try self.games.createGameList(&self.conf.games, self.dirs.games_dir);
    }

    pub fn loadGame(self: *Self, game_name: []const u8) !void {
        defer self.game_loaded = true;
        const custom_cwd_msg = "Set a custom cwd with --custom_cwd flag";
        const game_conf = self.conf.games.get(game_name) orelse {
            std.debug.print("{s} is not defined in the \"games\" section\n", .{game_name});
            return error.gameConfigNotFound;
        };
        self.game_conf = game_conf;
        const games_dir = self.dirs.games_dir.dir;
        self.loaded_game_name = try self.storeString(game_name);
        for (game_conf.gameinfo) |gamei| {
            const base_dir_ = util.openDirFatal(games_dir, gamei.base_dir, .{}, custom_cwd_msg);
            const game_dir_ = util.openDirFatal(games_dir, gamei.game_dir, .{}, custom_cwd_msg);

            try gameinfo.loadGameinfo(
                self.alloc,
                base_dir_,
                game_dir_,
                gamei.game_dir,
                .{ .u_scale = gamei.u_scale, .v_scale = gamei.v_scale },
                &self.vpkctx,
                self.loadctx,
                if (gamei.gameinfo_name.len != 0) gamei.gameinfo_name else "gameinfo.txt",
            );
        }
        //if (args.basedir) |bd| {
        //    if (args.gamedir) |gd| {
        //        const base_dir_ = util.openDirFatal(games_dir, bd, .{}, custom_cwd_msg);
        //        const game_dir_ = util.openDirFatal(games_dir, gd, .{}, custom_cwd_msg);
        //        try gameinfo.loadGameinfo(self.alloc, base_dir_, game_dir_, &self.vpkctx, loadctx, "gameinfo.txt");
        //    }
        //}

        if (self.dirs.fgd) |*f| f.close();
        self.dirs.fgd = util.openDirFatal(self.dirs.games_dir.dir, game_conf.fgd_dir, .{}, "");

        fgd.loadFgd(&self.fgd_ctx, self.dirs.fgd orelse return error.noFgdDir, game_conf.fgd) catch |err| {
            std.debug.print("--------------\n", .{});
            std.debug.print("If this is an fgd of an existing game,  Please open a bug report containing the fgd you are trying to load and I will fix the parser\n", .{});
            std.debug.print("--------------\n", .{});
            return err;
        };

        self.eventctx.pushEvent(.{ .gameLoaded = {} });
    }

    pub fn deinit(self: *Self) void {
        self.asset.deinit();
        self.games.deinit();
        self.edit_state.map_description.deinit(self.alloc);
        self.classtrack.deinit();
        self.targetname_track.deinit();
        self.autovis.deinit();
        self.layers.deinit();
        self.tools.deinit();
        self.tool_res_map.deinit();
        self.undoctx.deinit();
        self.ecs.deinit();
        self.fgd_ctx.deinit();
        self.notifier.deinit();
        self.selection.deinit();
        self.string_storage.deinit();
        self.rayctx.deinit();
        self.scratch_buf.deinit(self.alloc);
        self.asset_browser.deinit();
        self.omit_solids.deinit(self.alloc);
        self.csgctx.deinit();
        self.clipctx.deinit();
        self.vpkctx.deinit();
        self.frame_arena.deinit();
        self.groups.deinit();
        self.renderer.deinit();
        self.shell.destroy(self.alloc);
        var mit = self.models.valueIterator();
        while (mit.next()) |m| {
            m.deinit(self.alloc);
        }
        self.models.deinit();
        self.materials.deinit();

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
        self._selection_scratch.deinit(self.alloc);
        self.eventctx.destroy();
        self.rpcserv.destroy();

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

    pub fn hasComponent(self: *Self, index: EcsT.Id, comptime comp: EcsT.Components) bool {
        const ent = self.ecs.getEntity(index) catch return false;
        return ent.isSet(@intFromEnum(comp));
    }

    pub fn putComponent(self: *Self, index: EcsT.Id, comptime comp: EcsT.Components, val: EcsT.Fields[@intFromEnum(comp)].ftype) void {
        const ent = self.ecs.getEntity(index) catch return;
        const vis_mask = EcsT.getComponentMask(&.{ .invisible, .deleted, .autovis_invisible });
        if (self.ecs.intersects(index, vis_mask)) return;
        if (!ent.isSet(@intFromEnum(comp))) {
            self.ecs.attach(index, comp, val) catch return;
            return;
        }

        if (self.ecs.getPtr(index, comp) catch null) |ptr| {
            ptr.* = val;
        }
    }

    // remove the given entity from mesh storage until next update
    pub fn markSolidRemoved(self: *Self, ent: EcsT.Id) !void {
        if (self.omit_solids.getPtr(ent)) |om| {
            om.* = true;
            return;
        }

        try self.omit_solids.put(self.alloc, ent, true);
        if (self.getComponent(ent, .solid)) |sol|
            try sol.removeFromMeshMap(ent, self);
    }

    pub fn dupeEntity(self: *Self, ent: EcsT.Id) !EcsT.Id {
        const duped = try self.ecs.dupeEntity(ent);
        if (self.getComponent(duped, .entity)) |new_ent| {
            try new_ent.setClass(self, new_ent.class, duped);
            try new_ent.setTargetname(self, duped, new_ent._targetname);
        }
        //a layer of 0 is implied
        if (self.edit_state.selected_layer != .none) {
            self.putComponent(duped, .layer, .{ .id = self.edit_state.selected_layer });
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

    pub fn getSelected(self: *Self) []const EcsT.Id {
        self._selection_scratch.clearRetainingCapacity();

        self.selection.sanitizeSelection(self) catch return &.{};
        self._selection_scratch.appendSlice(self.alloc, self.selection._list.ids.items) catch return &.{};
        //const vis_mask = EcsT.getComponentMask(&.{ .invisible, .deleted, .autovis_invisible });

        //for (self.selection.list.ids.items) |pot| {
        //    if (self.ecs.intersects(pot, vis_mask))
        //        continue;
        //    self._selection_scratch.append(self.alloc, pot) catch return &.{};
        //}

        return self._selection_scratch.items;
    }

    pub fn rebuildMeshesIfDirty(self: *Self) !void {
        var it = self.meshmap.iterator();
        while (it.next()) |mesh| {
            try mesh.value_ptr.*.rebuildIfDirty(self);
        }
    }

    pub fn rebuildVisGroups(self: *Self) !void {
        {
            var it = self.ecs.iterator(.invisible);
            while (it.next()) |_| {
                if (try self.ecs.getOptPtr(it.i, .solid)) |solid| {
                    try solid.markDirty(it.i, self);
                }
            }
            self.ecs.clearComponent(.invisible);
        }

        var it = self.editIterator(.layer);
        while (it.next()) |lay| {
            if (self.layers.isDisabled(lay.id)) {
                self.ecs.attachComponent(it.i, .invisible, .{}) catch {}; // We discard error incase it is already attached
                if (try self.ecs.getOptPtr(it.i, .solid)) |solid|
                    try solid.removeFromMeshMap(it.i, self);
            } else {
                _ = try self.ecs.removeComponentOpt(it.i, .invisible);
                if (try self.ecs.getOptPtr(it.i, .solid)) |solid|
                    try solid.markDirty(it.i, self);
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
        const aa = self.frame_arena.allocator();

        var mod_name = std.ArrayList(u8){};
        defer mod_name.deinit(aa);
        var tex_name = std.ArrayList(u8){};
        defer tex_name.deinit(aa);

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
                    try tex_name.appendSlice(aa, side.material);
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
                    if (autovis.checkMatch(dis, null, texture, null)) {
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
                        try s_ptr.markDirty(it.i, self);
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

    pub fn isBindState(self: *const Self, bind: graph.SDL.keybinding.BindId, state: graph.SDL.ButtonState) bool {
        return self.gapp.main_window.isBindState(bind, state);
    }

    pub fn getCam3DMove(ed: *const Self, do_look: bool) graph.ptypes.Camera3D.MoveState {
        const perc_of_60fps = ed.gapp.frame_took_ms / 16.6666;
        const bind = &ed.conf.binds.view3d;

        return graph.ptypes.Camera3D.MoveState{
            .down = ed.isBindState(bind.cam_down, .high),
            .up = ed.isBindState(bind.cam_up, .high),
            .left = ed.isBindState(bind.cam_strafe_l, .high),
            .right = ed.isBindState(bind.cam_strafe_r, .high),
            .fwd = ed.isBindState(bind.cam_forward, .high),
            .bwd = ed.isBindState(bind.cam_back, .high),
            .mouse_delta = if (do_look and ed.stack_owns_input) ed.gapp.main_window.mouse.delta.scale(ed.config.window.sensitivity_3d) else .zero,
            .scroll_delta = if (ed.stack_owns_input) ed.gapp.main_window.mouse.wheel_delta.y else 0,
            .speed_perc = @as(f32, if (ed.isBindState(bind.cam_slow, .high)) 0.1 else 1) * perc_of_60fps,
        };
    }

    pub fn mouseState(self: *const Self) graph.SDL.MouseState {
        if (!self.stack_owns_input) return .{};
        return self.gapp.main_window.mouse;
    }

    pub fn writeToJson(self: *Self, writer: *std.Io.Writer) !void {
        var jwr = std.json.Stringify{
            .writer = writer,
            .options = .{ .whitespace = .indent_1 },
        };
        try jwr.beginObject();
        {
            if (self.edit_state.map_uuid == 0) {
                self.edit_state.map_uuid = uuid.v4.new();
            }

            try jwr.objectField("editor");
            try jwr.write(json_map.JsonEditor{
                .cam = json_map.JsonCamera.fromCam(self.draw_state.cam3d),
                .map_json_version = json_map.CURRENT_MAP_VERSION,
                .map_version = self.edit_state.map_version,
                .uuid = self.edit_state.map_uuid,
                .editor_version = version,
            });

            try jwr.objectField("visgroup");
            try self.layers.writeToJson(&jwr);

            try jwr.objectField("extra");
            {
                try jwr.beginObject();
                try jwr.objectField("recent_mat");
                try self.writeComponentToJson(&jwr, self.asset_browser.recent_mats.list, 0);
                try jwr.objectField("selected_layer");
                try jwr.write(@as(u16, @intFromEnum(self.edit_state.selected_layer)));
                try jwr.endObject();
            }

            try jwr.objectField("sky_name");
            try jwr.write(self.loaded_skybox_name);
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
            .@"enum" => {
                if (std.meta.hasFn(T, "serial")) {
                    return try comp.serial(self, jw, id);
                }
                @compileError("unsupported enum");
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

                if (try self.ecs.getOptPtr(it.i, .key_values)) |kvs| {
                    try ent.setTargetname(self, it.i, kvs.getString("targetname") orelse "");
                }
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
        {
            var it = self.editIterator(.displacements);
            while (it.next()) |disp| {
                try disp.markDispDirty(it.i, self);
            }
        }
        { //Iterate all solids and add
            var it = self.editIterator(.solid); //must use editIterator, omit hidden
            while (it.next()) |solid| {
                //const bb = (try self.ecs.getOptPtr(it.i, .bounding_box)) orelse continue;
                //solid.recomputeBounds(bb, try self.ecs.getOptPtr(it.i, .displacements));
                try solid.markDirty(it.i, self);
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
            const tex = try self.getMaterial(res_id);
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
    pub fn putSolidFromVmf(self: *Self, solid: vmf.Solid, group_id: ?GroupId, vis_override: ?Layer.Id) !void {
        const vis_id = vis_override orelse self.layers.getIdFromEditorInfo(&solid.editor);
        const new = try self.ecs.createEntity();
        if (vis_id) |vm| {
            try self.ecs.attach(new, .layer, .{ .id = vm });
        }
        var newsolid = try self.csgctx.genMesh2(
            solid.side,
            self.alloc,
            &self.string_storage,
            //@intCast(self.set.sparse.items.len),
        );
        if (group_id) |gid| {
            try self.ecs.attach(new, .group, .{ .id = gid });
        }
        var opt_disps: ?ecs.Displacements = null;

        for (newsolid.sides.items) |*side| {
            const tex = try self.loadTextureFromVpk(side.material);
            side.tex_id = tex.res_id;
        }

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
            if (self.stack_grabbed_mouse) screen_area.center() else self.edit_state.mpos.sub(screen_area.pos()),
            view_3d,
        );
        return self.rayctx.findNearestObject(self, rc[0], rc[1], .{
            .aabb_only = false,
        }) catch &.{};
    }

    pub fn getCurrentTool(self: *Self) ?*tool_def.i3DTool {
        return self.tools.vtables.getOpt(self.edit_state.__tool_index);
    }

    pub fn setTool(self: *Self, new_tool: u16) void {
        if (self.tools.vtables.getOpt(new_tool) == null) {
            log.warn("tring to set invalid tool, ignoring", .{});
            return;
        }
        defer self.eventctx.pushEvent(.{ .tool_changed = {} });
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

    pub fn initNewMap(self: *Self, sky_name: []const u8, game_name: []const u8) !void {
        try self.loadGame(game_name);
        if (sky_name.len > 0)
            try self.loadSkybox(sky_name);
        self.has_loaded_map = true;
    }

    fn loadRatmap(self: *Self, path: std.fs.Dir, filename: []const u8, loadctx: *LoadCtx) !void {
        const in_file = try path.openFile(filename, .{});
        defer in_file.close();

        const compressed = try util.getFileFromTar(self.alloc, in_file, "map.json.gz");
        defer self.alloc.free(compressed);
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        defer aw.deinit();

        var in: std.Io.Reader = .fixed(compressed);
        var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
        _ = try decompress.reader.streamRemaining(&aw.writer);

        try self.loadJson(aw.written(), loadctx, filename);

        //log.err("map.json.gz was not found in ratmap {s}", .{filename});
        //return error.invalidTarRatmap;
    }

    pub fn unloadGame(self: *Self) !void {
        if (!self.game_loaded) return;
        defer self.game_loaded = false;

        self.fgd_ctx.reset();
        {
            self.vpkctx.mutex.lock();
            defer self.vpkctx.mutex.unlock();
            var it = self.vpkctx.entries.iterator();

            while (it.next()) |item| {
                if (self.materials.getPtr(item.key_ptr.*)) |tex| {
                    tex.deinit();
                    self.async_asset_load.removeNotify(item.key_ptr.*);
                    _ = self.materials.remove(item.key_ptr.*);
                }
                if (self.models.getPtr(item.key_ptr.*)) |model| {
                    model.deinit(self.alloc);
                    _ = self.models.remove(item.key_ptr.*);
                }
            }
            self.vpkctx.entries.clearAndFree(self.vpkctx.alloc);
            for (self.vpkctx.dirs.items) |*dir|
                dir.deinit();
            self.vpkctx.dirs.clearAndFree(self.alloc);
            for (self.vpkctx.loose_dirs.items) |*dir|
                dir.dir.close();
            self.vpkctx.loose_dirs.clearAndFree(self.alloc);
            //Also clear the dirs
        }
        //unload texture
        //unload model
        //unload vpk entries
    }

    pub fn loadMap(self: *Self, path: std.fs.Dir, filename: []const u8, loadctx: *LoadCtx, game_name: []const u8) !void {
        if (self.game_loaded and self.loaded_game_name != null and std.mem.eql(u8, game_name, self.loaded_game_name.?)) {
            //Do nothing, keep game loaded
        } else {
            try self.unloadGame();
            try self.loadGame(game_name);
        }
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
            try self.loadVmf(path, filename, loadctx, null);
        } else {
            return error.unknownMapExtension;
        }

        self.setWindowTitle(.{ "", self.loaded_map_name orelse "unnamed map" });
    }

    pub fn addRecentMap(self: *Self, full_path: []const u8) !void {
        var recent = std.ArrayList([]const u8){};
        defer recent.deinit(self.alloc);
        const aa = self.frame_arena.allocator();
        if (util.readFile(self.alloc, self.dirs.config.dir, "recent_maps.txt")) |slice| { //Keep track of recent maps
            defer self.alloc.free(slice);
            var it = std.mem.tokenizeScalar(u8, slice, '\n');
            while (it.next()) |filen| {
                if (std.fs.cwd().openFile(filen, .{})) |recent_map| {
                    //const qoi_data = json_map.getFileFromTar(recent_map,"thumbnail.qoi") catch continue;
                    recent_map.close();
                    try recent.append(self.alloc, try aa.dupe(u8, filen));
                } else |_| {}
            }
        } else |_| {}

        for (recent.items, 0..) |rec, i| {
            if (std.mem.eql(u8, rec, full_path)) {
                _ = recent.orderedRemove(i);
                break;
            }
        }

        try recent.insert(self.alloc, 0, full_path);
        if (self.dirs.config.dir.createFile("recent_maps.txt", .{})) |recent_out| {
            defer recent_out.close();
            var buf: [256]u8 = undefined;
            var writer = recent_out.writer(&buf);
            for (recent.items) |rec| {
                try writer.interface.print("{s}\n", .{rec});
            }
            try writer.interface.flush();
        } else |_| {}
    }

    fn loadJsonFile(self: *Self, path: std.fs.Dir, filename: []const u8, loadctx: *LoadCtx) !void {
        const slice = try util.readFile(self.alloc, path, filename);

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

        if (!self.has_loaded_map) {
            try self.setMapName(filename);
            try self.loadSkybox(parsed.value.sky_name);
            parsed.value.editor.cam.setCam(&self.draw_state.cam3d);
            self.edit_state.map_version = parsed.value.editor.map_version;
            self.edit_state.map_uuid = parsed.value.editor.uuid;
            log.info("Map version : {d}", .{self.edit_state.map_version});
            if (parsed.value.extra == .object) {
                const ex = &parsed.value.extra;
                if (std.json.parseFromValue(struct { recent_mat: [][]const u8, selected_layer: u16 = 0 }, self.alloc, ex.*, .{})) |v| {
                    defer v.deinit();
                    for (v.value.recent_mat) |mat| {
                        if (try self.vpkctx.resolveId(.{ .name = mat }, false)) |id| {
                            try self.asset_browser.recent_mats.append(id.id);
                        }
                    }
                    if (self.asset_browser.recent_mats.list.items.len > 0) {
                        self.edit_state.selected_texture_vpk_id = self.asset_browser.recent_mats.list.items[0];
                    }
                    self.edit_state.selected_layer = @enumFromInt(v.value.selected_layer);
                } else |_| {} //This data is not essential to parse
            }

            try self.layers.insertVisgroupsFromJson(parsed.value.visgroup);
        }

        loadctx.cb("Building meshes");
        try self.rebuildAllDependentState();
        try self.layers.rebuildMasks();
        try self.rebuildVisGroups();
    }

    //TODO write a vmf -> json utility like jsonToVmf.zig
    //Then, only have a single function to load serialized data into engine "loadJson"
    pub fn loadVmf(
        self: *Self,
        path: std.fs.Dir,
        filename: []const u8,
        loadctx: *LoadCtx,
        /// If set map's vis groups will be ignored and all objects will be put in a layer with override_vis name
        override_vis: ?[]const u8,
    ) !void {
        const vis_override = if (override_vis) |n| try self.layers.getOrPutTopLevelGroup(n) else null;
        defer self.has_loaded_map = true;
        var timer = try std.time.Timer.start();

        defer log.info("Loaded vmf in {d}ms", .{timer.read() / std.time.ns_per_ms});

        const slice = util.readFile(self.alloc, path, filename) catch |e| util.fatalPrintFilePath(path, filename, e, "");

        defer self.alloc.free(slice);
        var aa = std.heap.ArenaAllocator.init(self.alloc);
        var obj = try vdf.parse(self.alloc, slice, null, .{});
        defer obj.deinit();
        loadctx.cb("vmf parsed");
        const vmf_ = try vdf.fromValue(vmf.Vmf, &obj, &.{ .obj = &obj.value }, aa.allocator(), null);
        if (vis_override == null)
            try self.layers.buildMappingFromVmf(vmf_.visgroups.visgroup, self.layers.root);

        if (!self.has_loaded_map) {
            try self.setMapName(filename);
            try self.loadSkybox(vmf_.world.skyname);
        }
        {
            loadctx.addExpected(vmf_.world.solid.len + vmf_.entity.len + 10);
            var gen_timer = try std.time.Timer.start();
            for (vmf_.world.solid, 0..) |solid, si| {
                try self.putSolidFromVmf(solid, null, vis_override);
                loadctx.printCb("csg generated {d} / {d}", .{ si, vmf_.world.solid.len });
            }
            for (vmf_.entity, 0..) |ent, ei| {
                loadctx.printCb("ent generated {d} / {d}", .{ ei, vmf_.entity.len });
                const new = try self.ecs.createEntity();
                const group_id = if (ent.solid.len > 0) try self.groups.newGroup(new) else 0;
                const vis_id = vis_override orelse self.layers.getIdFromEditorInfo(&ent.editor);
                if (vis_id) |vo| {
                    try self.ecs.attach(new, .layer, .{ .id = vo });
                }
                for (ent.solid) |solid|
                    try self.putSolidFromVmf(solid, group_id, vis_override);
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
                            const key = obj.stringFromId(item.key_ptr.*) orelse "";
                            try kvs.putStringNoNotify(try self.storeString(key), item.value_ptr.*);
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

            log.info("csg took {d} {d:.2} us", .{ nm, csg.gen_time / std.time.ns_per_us / (nm + 1) });
            log.info("Generated {d} meshes in {d:.2} ms", .{ nm, whole_time / std.time.ns_per_ms });
        }
        aa.deinit();
        loadctx.cb("csg generated");
    }

    pub fn drawToolbar(self: *Self, area: graph.Rect, draw: *DrawCtx, font: *graph.FontInterface, fh: f32) void {
        const start = area.pos();
        const w = fh * 5;
        const tool_index = self.edit_state.__tool_index;
        const info = @typeInfo(@TypeOf(self.conf.binds.tool)).@"struct".fields;
        inline for (info[0 .. info.len - 1], 0..) |tool_name, i| {
            if (i < self.tools.vtables.dense.items.len) {
                const tool = self.tools.vtables.dense.items[i];
                const fi: f32 = @floatFromInt(i);
                const rec = graph.Rec(start.x + fi * w, start.y, w, w);
                tool.tool_icon_fn(tool, draw, self, rec);
                var buf: [32]u8 = undefined;
                const n = @field(self.config.keys.tool, tool_name.name).nameFull(&buf);
                draw.textClipped(rec, "{s}", .{n}, .{ .px_size = fh, .font = font, .color = 0xff }, .left);
                if (tool_index == i) {
                    draw.rectBorder(rec, 3, colors.selected);
                }
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

    pub fn getMaterial(self: *Self, res_id: vpk.VpkResId) !ecs.Material {
        if (self.materials.get(res_id)) |tex| return tex;

        try self.loadTexture(res_id);

        return .default();
    }

    pub fn getTexture(self: *Self, res_id: vpk.VpkResId) !graph.Texture {
        if (self.materials.get(res_id)) |tex| return tex.slots[0];

        try self.loadTexture(res_id);

        return missingTexture();
    }

    pub fn loadTexture(self: *Self, res_id: vpk.VpkResId) !void {
        if (self.materials.get(res_id)) |_| return;

        { //track tools
            if (self.vpkctx.namesFromId(res_id)) |name| {
                if (std.mem.startsWith(u8, name.path, "materials/tools")) {
                    try self.tool_res_map.put(res_id, {});
                }
            }
        }

        try self.materials.put(res_id, .default());
        try self.async_asset_load.loadTexture(res_id, &self.vpkctx);
    }

    /// 'material' is without materials/ prefix or .vmt suffix
    pub fn loadTextureFromVpk(self: *Self, material: []const u8) !struct { tex: graph.Texture, res_id: vpk.VpkResId } {
        const res_id = try self.vpkctx.getResourceIdFmt("vmt", "materials/{s}", .{material}, true) orelse return .{ .tex = missingTexture(), .res_id = 0 };
        if (self.materials.get(res_id)) |tex| return .{ .tex = tex.slots[0], .res_id = res_id };

        try self.loadTexture(res_id);

        return .{ .tex = missingTexture(), .res_id = res_id };
    }

    pub fn camRay(self: *Self, area: graph.Rect, view: Mat4) [2]Vec3 {
        return util3d.screenSpaceRay(
            area.dim(),
            if (self.stack_grabbed_mouse) area.center() else self.edit_state.mpos.sub(area.pos()),
            view,
        );
    }

    pub fn printScratch(self: *Self, comptime str: []const u8, args: anytype) ![]const u8 {
        self.scratch_buf.clearRetainingCapacity();
        try self.scratch_buf.print(self.alloc, str, args);
        return self.scratch_buf.items;
    }

    pub fn printArena(self: *Self, comptime str: []const u8, args: anytype) ![]const u8 {
        return try std.fmt.allocPrint(self.frame_arena.allocator(), str, args);
    }

    pub fn printScratchZ(self: *Self, comptime str: []const u8, args: anytype) ![]const u8 {
        _ = try self.printScratch(str, args);
        try self.scratch_buf.append(self.alloc, 0);
        return self.scratch_buf.items;
    }

    pub fn saveAndNotify(self: *Self, basename: []const u8, path: []const u8, post: async_util.CompressAndSave.Post) !void {
        self.edit_state.map_version += 1;
        var timer = try std.time.Timer.start();

        const name = try std.fs.path.join(self.frame_arena.allocator(), &.{ path, try self.printScratch("{s}.ratmap", .{basename}) });
        self.notify("{s}: {s}", .{ L.lang.saving, name }, colors.tentative);

        var jwriter = std.Io.Writer.Allocating.init(self.alloc);

        if (true) { //TODO REMOVE

            var out = try std.fs.cwd().createFile("undo_dump.json", .{});
            defer out.close();

            //try self.undoctx.writeToJson(out.writer());
        }

        if (self.writeToJson(&jwriter.writer)) {
            var info_writer = std.Io.Writer.Allocating.init(self.alloc);
            var jwr_info = std.json.Stringify{ .writer = &info_writer.writer, .options = .{} };
            try jwr_info.write(json_map.JsonInfo{
                .json_info_version = json_map.JsonInfo.format_version,
                .game_config_name = self.loaded_game_name orelse "nogame",
                .description = self.edit_state.map_description.items,
            });

            self.notify(" {s}: {s} -> {d:.1}{s}", .{ L.lang.saved, name, timer.read() / std.time.ns_per_ms, L.lang.units.ms }, colors.good);
            self.edit_state.saved_at_delta = self.undoctx.delta_counter;
            self.edit_state.was_saved = true;

            self.setWindowTitle(.{ "", self.loaded_map_name orelse "unnamed_map" });

            const sz = 256;
            var bmp = try graph.Bitmap.initBlank(self.alloc, sz, sz, .rgb_8);
            { //Try to create a thumbnail

                var rb = try graph.RenderTexture.init(sz, sz);
                defer rb.deinit();
                rb.bind(true);

                if (self.gapp.gui.getWindowId(self.workspaces.main_3d_win)) |main3d| {
                    const winptr: *eviews.Main3DView = @alignCast(@fieldParentPtr("vt", main3d));

                    const old_dim = winptr.drawctx.screen_dimensions;
                    winptr.drawctx.screen_dimensions = .{ .x = sz, .y = sz };
                    defer winptr.drawctx.screen_dimensions = old_dim;
                    try eviews.Main3DView.draw3Dview(winptr, self, .{ .w = sz, .h = sz }, winptr.drawctx, false);
                }

                graph.gl.BindFramebuffer(graph.gl.FRAMEBUFFER, rb.fb);
                graph.gl.ReadPixels(0, 0, sz, sz, graph.gl.RGB, graph.gl.UNSIGNED_BYTE, &bmp.data.items[0]);
                try bmp.invertY();
            }

            try async_util.CompressAndSave.spawn(
                self.alloc,
                &self.async_asset_load,
                .{
                    .json_buffer = try jwriter.toOwnedSlice(),
                    .json_info_buffer = try info_writer.toOwnedSlice(),
                    .dir = try std.fs.cwd().openDir(".", .{}),
                    .name = name,
                    .post = post,
                    .thumbnail = bmp,
                },
            );
        } else |err| {
            jwriter.deinit();
            //out_file.close();
            log.err("writeToJson failed ! {}", .{err});
            self.notify("save failed!: {}", .{err}, colors.bad);
        }
    }

    pub fn notify(self: *Self, comptime fmt: []const u8, args: anytype, color: u32) void {
        log.info(fmt, args);
        const str = self.notifier.submitNotify(fmt, args, color) catch {
            std.debug.print("NOTIFY FAILED\n", .{});
            return;
        };
        self.eventctx.pushEvent(.{ .notify = self.eventctx.alloc.dupe(u8, str) catch return });
    }

    pub fn setPaused(self: *Self, should_pause: bool) void {
        if (self._paused == should_pause) return; //ensure this function is idempotent

        if (!should_pause and !self.has_loaded_map) return; //We can only unpause if we have a map

        self._paused = should_pause;
        if (self._paused)
            self.workspaces.pre_pause = self.gapp.workspaces.active_ws;
        self.gapp.workspaces.active_ws = if (self._paused) self.workspaces.pause else self.workspaces.pre_pause;
    }

    pub fn loadSkybox(self: *Self, sky_name: []const u8) !void {
        const name = try self.storeString(sky_name);
        self.loaded_skybox_name = name;
        self.draw_state.skybox_textures = [_]graph.glID{0} ** 6;
        const txt = &(self.draw_state.skybox_textures.?);
        for (def_render.Skybox_name_endings, 0..) |end, i| {
            const vtf_buf = try self.vpkctx.getFileTempFmt("vtf", "materials/skybox/{s}{s}", .{ name, end }, true) orelse {
                std.debug.print("Cant find sky {s}{s}\n", .{ name, end });
                continue;
            };
            const tex = vtf.loadTexture(vtf_buf, self.alloc) catch |err| {
                std.debug.print("Had an oopis {t}\n", .{err});
                continue;
            };
            txt[i] = tex.id;
        }
    }

    pub fn preUpdate(vt: *RGui.app.iUpdate) void {
        const self: *Self = @alignCast(@fieldParentPtr("app_update", vt));

        self.update() catch |err| {
            std.debug.print("err {t}\n", .{err});
            @panic("totally fucked");
        };
    }

    pub fn isUnsaved(self: *Self) bool {
        return self.edit_state.saved_at_delta != self.undoctx.delta_counter;
    }

    pub fn update(self: *Self) !void {
        const win = &self.gapp.main_window;
        self.edit_state.mpos = win.mouse.pos;
        self.handleMisc3DKeys();
        self.handleTabKeys();
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
                var write_buf: [4096]u8 = undefined;
                var wr = out_file.writer(&write_buf);
                self.writeToJson(&wr.interface) catch |err| {
                    log.err("writeToJson failed ! {}", .{err});
                    self.notify("Autosave failed!: {}", .{err}, colors.bad);
                };
                try wr.interface.flush();
            } else |err| {
                log.err("Autosave failed with error {}", .{err});
                self.notify("Autosave failed!: {}", .{err}, colors.bad);
            }
            self.notify("{s}: {s}", .{ L.lang.autosaved, basename }, colors.good);
        }
        const gbind = &self.conf.binds.global;

        if (win.isBindState(gbind.pause, .rising)) {
            self.setPaused(!self._paused);
        }
        if (win.isBindState(gbind.save, .rising)) {
            try action.trySave(self);
        }
        if (win.isBindState(gbind.save_new, .rising)) {
            try async_util.SdlFileData.spawn(self.alloc, &self.async_asset_load, .save_map);
        }
        const build_map = win.isBindState(gbind.build_map, .rising);
        const build_map_user = win.isBindState(gbind.build_map_user, .rising);
        if (build_map or build_map_user) {
            try action.buildMap(self, build_map_user);
        }

        _ = self.frame_arena.reset(.retain_capacity);
        const aa = self.frame_arena.allocator();
        const MAX_UPDATE_TIME = std.time.ns_per_ms * 16;
        var update_timer = try std.time.Timer.start();
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
                if (completed.deinitToMaterial(self.async_asset_load.alloc)) |texture| {
                    try self.materials.put(completed.vpk_res_id, texture);
                    self.async_asset_load.notifyTexture(completed.vpk_res_id, self);
                } else |err| {
                    log.err("texture init failed with : {}", .{err});
                }

                num_rm_tex += 1;
                const elapsed = update_timer.read();
                if (elapsed > MAX_UPDATE_TIME)
                    break;
            }
            self.draw_state.init_asset_count += num_rm_tex;
            for (0..num_rm_tex) |_|
                _ = self.async_asset_load.completed.orderedRemove(0);

            var completed_ids = std.ArrayList(vpk.VpkResId){};
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
                try completed_ids.append(aa, completed.res_id);
                completed.texture_ids.deinit(self.alloc);
                num_removed += 1;

                const elapsed = update_timer.read();
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
        {
            var to_rem = std.ArrayList(usize){};
            const keys = self.omit_solids.keys();
            for (self.omit_solids.values(), 0..) |*val, i| {
                if (val.*) {
                    val.* = false;
                    continue;
                }

                try to_rem.append(aa, i);

                if (try self.ecs.getOptPtr(keys[i], .solid)) |solid| {
                    try solid.markDirty(keys[i], self);
                }
            }
            var i = to_rem.items.len;
            while (i > 0) : (i -= 1) {
                self.omit_solids.swapRemoveAt(to_rem.items[i - 1]);
            }
        }

        if (self.draw_state.meshes_dirty) {
            var rebuild_time = try std.time.Timer.start();
            self.draw_state.meshes_dirty = false;

            var count: usize = 0;
            var it = self.meshmap.iterator();
            while (it.next()) |mesh| {
                if (mesh.value_ptr.*.is_dirty) {
                    count += 1;
                }
                try mesh.value_ptr.*.rebuildIfDirty(self);
            }

            const took = rebuild_time.read();
            if (took > std.time.ns_per_ms) {
                //std.debug.print("{d} mesh build in {d} ms\n", .{ count, took / std.time.ns_per_ms });
            }
        }
    }

    pub fn markMeshDirty(ed: *Self, ent_id: EcsT.Id, tex_id: vpk.VpkResId) !void {
        const batch = try ed.getOrPutMeshBatch(tex_id);
        batch.*.is_dirty = true;

        //ensure this is in batch
        try batch.*.contains.put(ent_id, {});

        ed.draw_state.meshes_dirty = true;
    }

    pub fn handleTabKeys(ed: *Self) void {
        if (ed._paused) return;
        const bb = &ed.conf.binds.global;
        if (ed.isBindState(bb.workspace_0, .rising)) {
            ed.gapp.workspaces.active_ws = ed.workspaces.main;
        } else if (ed.isBindState(bb.workspace_texture, .rising)) {
            ed.gapp.workspaces.active_ws = ed.workspaces.asset;
        } else if (ed.isBindState(bb.workspace_model, .rising)) {
            ed.gapp.workspaces.active_ws = ed.workspaces.model;
        } else if (ed.isBindState(bb.workspace_1, .rising)) {
            ed.gapp.workspaces.active_ws = ed.workspaces.main_2d;
        }
    }

    pub fn setIgnoreGroups(ed: *Self, value: bool) void {
        ed.selection.ignore_groups = value;
        ed.eventctx.pushEvent(.{ .menubar_dirty = {} });
        ed.eventctx.pushEvent(.{ .selection_changed = {} });
    }

    pub fn handleMisc3DKeys(ed: *Self) void {
        { //key binding stuff

            if (ed.isBindState(ed.conf.binds.view3d.grid_inc, .rising))
                ed.grid.double();
            if (ed.isBindState(ed.conf.binds.view3d.grid_dec, .rising))
                ed.grid.half();

            if (ed.isBindState(ed.conf.binds.view2d.grid_inc, .rising))
                ed.grid.double();
            if (ed.isBindState(ed.conf.binds.view2d.grid_dec, .rising))
                ed.grid.half();

            if (ed.isBindState(ed.conf.binds.view3d.ignore_groups, .rising)) {
                ed.setIgnoreGroups(!ed.selection.ignore_groups);
            }

            if (ed.isBindState(ed.conf.binds.view3d.next_invalid, .rising)) {
                action.selectNextInvalid(ed) catch {};
            }

            const fi = @typeInfo(@TypeOf(ed.conf.binds.tool)).@"struct".fields;
            inline for (fi[0 .. fi.len - 1], 0..) |field, i| {
                if (ed.isBindState(@field(ed.conf.binds.tool, field.name), .rising)) {
                    ed.setTool(@intCast(i));
                }
            }
        }
    }
};

pub const LoadCtx = struct {
    opt: ?LoadCtxReal = null,

    pub fn printCb(oself: *@This(), comptime fmt: []const u8, args: anytype) void {
        const self = &(oself.opt orelse return);
        self.cb_count += 1;
        if (self.timer.read() / std.time.ns_per_ms < self.refresh_period_ms) {
            return;
        }
        self.cb_count -= 1;
        var fbs = std.io.FixedBufferStream([]u8){ .buffer = &self.buffer, .pos = 0 };
        fbs.writer().print(fmt, args) catch return;
        oself.cb(fbs.getWritten());
    }

    pub fn addExpected(oself: *@This(), addition: usize) void {
        const self = &(oself.opt orelse return);
        self.expected_cb += addition;
    }

    pub fn cb(oself: *@This(), message: []const u8) void {
        const self = &(oself.opt orelse return);
        self.cb_count += 1;
        if (self.timer.read() / std.time.ns_per_ms < self.refresh_period_ms) {
            return;
        }
        self.timer.reset();
        self.win.pumpEvents(.poll);
        self.draw.begin(colors.splash_clear, self.win.screen_dimensions.toF()) catch return;
        //self.draw.text(.{ .x = 0, .y = 0 }, message, &self.font.font, 100, 0xffffffff);
        const perc: f32 = @as(f32, @floatFromInt(self.cb_count)) / @as(f32, @floatFromInt(self.expected_cb));
        oself.drawSplash(perc, message);
        self.draw.end(null) catch return;
        self.win.swap(); //So the window doesn't look too broken while loading
    }

    pub fn drawSplash(oself: *@This(), perc: f32, message: []const u8) void {
        const self = &(oself.opt orelse return);
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
            .{ .px_size = 15, .color = 0xff, .font = self.font },
            .left,
        );
        const p = @min(1, perc);
        self.draw.rect(pbar.split(.vertical, pbar.w * p)[0], colors.progress);
    }

    pub fn loadedSplash(oself: *@This()) !void {
        const self = &(oself.opt orelse return);
        if (DISABLE_SPLASH)
            return;
        if (self.draw_splash) {
            var fbs = std.io.FixedBufferStream([]u8){ .buffer = &self.buffer, .pos = 0 };
            try fbs.writer().print("v{s}  {s}.{s}.{s}", .{
                version,
                //self.time / std.time.ns_per_ms,
                @tagName(builtin.mode),
                @tagName(builtin.target.os.tag),
                @tagName(builtin.target.cpu.arch),
            });
            graph.gl.Enable(graph.gl.BLEND);
            //graph.gl.Clear(graph.gl.DEPTH_BUFFER_BIT);
            if (colors.splash_tint > 0)
                self.draw.rect(graph.Rec(0, 0, self.draw.screen_dimensions.x, self.draw.screen_dimensions.y), colors.splash_tint);
            oself.drawSplash(1.0, fbs.getWritten());
            if (self.gapp.main_window.keys.len > 0 or self.gapp.main_window.mouse.left != .low or self.gapp.main_window.mouse.right != .low)
                self.draw_splash = false;
        }
    }

    pub fn resetTime(self: *@This()) void {
        if (self.opt) |*o| {
            o.gtimer.reset();
        }
    }

    pub fn setTime(self: *@This()) void {
        if (self.opt) |*o| {
            o.time = o.gtimer.read();
        }
    }

    pub fn setDraw(self: *@This(), should: bool) void {
        if (self.opt) |*o| {
            o.draw_splash = should;
        }
    }
};

pub const LoadCtxReal = struct {

    //No need for high fps when loading. Only repaint this often.
    refresh_period_ms: usize = 66,

    buffer: [256]u8 = undefined,
    timer: std.time.Timer,
    draw: *graph.ImmediateDrawingContext,
    win: *graph.SDL.Window,
    font: *graph.FontInterface,
    splash: graph.Texture,
    draw_splash: bool = true,
    gtimer: std.time.Timer,
    time: u64 = 0,

    expected_cb: usize = 1, // these are used to update progress bar
    cb_count: usize = 0,
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
                .pixel_format = graph.gl.RGB,
                .pixel_store_alignment = 1,
                .mag_filter = graph.gl.NEAREST,
            },
        );
        static.texture.?.w = 32; //Zoom the texture out
        static.texture.?.h = 32;
    }
    return static.texture.?;
}

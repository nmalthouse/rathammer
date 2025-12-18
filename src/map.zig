const std = @import("std");
// Stores all the state for a single map file being edited
// not implemented yet

pub const Map = struct {
    /// Only real state is a timer, has helper functions for naming and pruning autosaves.
    autosaver: Autosaver,

    /// Stores all the world state, solids, entities, disp, etc.
    ecs: EcsT,
    groups: ecs.Groups,

    /// Stores all the mesh data for solids.
    meshmap: ecs.MeshMap,

    /// Stores undo state, most changes to world state (ecs) should be done through a undo vtable
    undoctx: undo.UndoContext,

    layers: Layer.Context,

    skybox: Skybox,

    /// Draw colored text messages to the screen for a short time
    notifier: NotifyCtx,

    autovis: autovis.VisContext,

    classtrack: class_tracker.Tracker,
    targetname_track: class_tracker.Tracker,

    cam3d: graph.Camera3D = .{ .up = .z, .move_speed = 10, .max_move_speed = 100, .fwd_back_kind = .planar },

    selection: Selection,

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
        __tool_index: usize = 0,

        lmouse: ButtonState = .low,
        rmouse: ButtonState = .low,
        mpos: graph.Vec2f = undefined,

        selected_layer: Layer.Id = .none,
        selected_model_vpk_id: ?vpk.VpkResId = null,
        selected_texture_vpk_id: ?vpk.VpkResId = null,
    } = .{},

    grid: grid_stuff.Snap = .{ .s = Vec3.set(16) },

    /// basename of map, without extension or path
    loaded_map_name: ?[]const u8 = null,
    /// This is always relative to cwd
    loaded_map_path: ?[]const u8 = null,

    last_exported_obj_name: ?[]const u8 = null,
    last_exported_obj_path: ?[]const u8 = null,

    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, config: Conf.Config) !Map {
        return .{
            .classtrack = .init(alloc),
            .targetname_track = .init(alloc),
            .notifier = NotifyCtx.init(alloc, 4000),
            .autosaver = try Autosaver.init(config.autosave.interval_min * std.time.ms_per_min, config.autosave.max, config.autosave.enable, alloc),
            .selection = Selection.init(alloc),
            .groups = ecs.Groups.init(alloc),
            .undoctx = undo.UndoContext.init(alloc),
            .autovis = autovis.VisContext.init(alloc),
            .layers = try Layer.Context.init(alloc),
            .meshmap = ecs.MeshMap.init(alloc),
            .ecs = try EcsT.init(alloc),
            .skybox = try Skybox.init(alloc, shader_dir),
        };
    }

    pub fn deinit(self: *Map) void {
        self.classtrack.deinit();
        self.targetname_track.deinit();
        self.autovis.deinit();
        self.layers.deinit();
        self.undoctx.deinit();
        self.ecs.deinit();
        self.notifier.deinit();
        self.selection.deinit();
        self.skybox.deinit();
        self.groups.deinit();

        var it = self.meshmap.iterator();
        while (it.next()) |item| {
            item.value_ptr.*.deinit();
            self.alloc.destroy(item.value_ptr.*);
        }
        self.meshmap.deinit();
    }
};

const Autosaver = @import("autosave.zig").Autosaver;
const ecs = @import("ecs.zig");
const EcsT = ecs.EcsT;
const undo = @import("undo.zig");
const Layer = @import("layer.zig");
const Skybox = @import("skybox.zig").Skybox;
const NotifyCtx = @import("notify.zig").NotifyCtx;
const autovis = @import("autovis.zig");
const class_tracker = @import("class_track.zig");
const graph = @import("graph");
const Selection = @import("selection.zig");
const ButtonState = graph.SDL.ButtonState;
const vpk = @import("vpk.zig");
const grid_stuff = @import("grid.zig");
const Vec3 = graph.za.Vec3;
const Conf = @import("config.zig");

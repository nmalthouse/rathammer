pub const Game = struct {
    //crantson

    /// Store static strings for the lifetime of game
    string_storage: StringStorage,

    /// This sucks, clean it up
    fgd_ctx: fgd.EntCtx,

    /// These maps map vpkids to their respective resource,
    /// when fetching a resource with getTexture, etc. Something is always returned. If an entry does not exist,
    /// a job is submitted to the load thread pool and a placeholder is inserted into the map and returned
    textures: std.AutoHashMap(vpk.VpkResId, ecs.Material),
    models: std.AutoHashMap(vpk.VpkResId, Model),

    /// Used to track tool txtures, TODO turn this into transparent_map, sticking all $alphatest and $translucent in here for
    /// alpha draw ordering
    tool_res_map: std.AutoHashMap(vpk.VpkResId, void),
};

const std = @import("std");

const ecs = @import("ecs.zig");
const vpk = @import("vpk.zig");
const StringStorage = @import("string.zig").StringStorage;
const fgd = @import("fgd.zig");
const Model = @import("editor.zig").Model;

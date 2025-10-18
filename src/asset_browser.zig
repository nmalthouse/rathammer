const std = @import("std");
const graph = @import("graph");
const vpk = @import("vpk.zig");
const Os9Gui = graph.gui_app.Os9Gui;
const guiutil = graph.gui_app;
const Vec3 = graph.za.Vec3;
const edit = @import("editor.zig");
const Config = @import("config.zig");
const ecs = @import("ecs.zig");
const Gui = graph.Gui;
const guis = graph.RGui;
const RGui = guis.Gui;
//TODO center camera view on model on new model load

pub const DialogState = struct {
    target_id: ecs.EcsT.Id,

    previous_pane_index: usize,

    kind: enum { texture, model },
};

pub const RecentsList = struct {
    max: usize = 16,
    alloc: std.mem.Allocator,
    list: std.ArrayListUnmanaged(vpk.VpkResId) = .{},

    pub fn init(alloc: std.mem.Allocator, max: usize) @This() {
        return .{
            .alloc = alloc,
            .max = max,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.list.deinit(self.alloc);
    }

    pub fn append(self: *@This(), id: vpk.VpkResId) !void {
        try self.list.append(self.alloc, id);
    }

    pub fn put(self: *@This(), id: vpk.VpkResId) !void {
        for (self.list.items, 0..) |item, index| {
            if (item == id) {
                _ = self.list.orderedRemove(index);
                break;
            }
        }

        try self.list.insert(self.alloc, 0, id);
        if (self.list.items.len > self.max)
            try self.list.resize(self.alloc, self.max);
    }
};

const log = std.log.scoped(.asset_browser);
pub const AssetBrowserGui = struct {
    const Self = @This();

    dialog_state: ?DialogState = null,

    recent_mats: RecentsList,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .recent_mats = RecentsList.init(alloc, 16),
        };
    }

    pub fn deinit(self: *Self) void {
        self.recent_mats.deinit();
    }

    pub fn applyDialogState(self: *Self, editor: *edit.Context) !void {
        defer self.dialog_state = null;
        if (self.dialog_state) |ds| {
            switch (ds.kind) {
                .model => {
                    const mid = editor.edit_state.selected_model_vpk_id orelse return;
                    if (try editor.ecs.getOptPtr(ds.target_id, .entity)) |ent| {
                        try ent.setModel(editor, ds.target_id, .{ .id = mid }, false);
                    }
                    //To set the model, first change the kv,
                    //then set ent._model_id
                },
                .texture => {
                    const tid = editor.edit_state.selected_texture_vpk_id orelse return;
                    if (try editor.ecs.getOptPtr(ds.target_id, .key_values)) |ent| {
                        if (try editor.vpkctx.resolveId(.{ .id = tid }, false)) |idd| {
                            //var name = idd.name;
                            //if (std.mem.startsWith(u8, name, "materials/"))
                            //    name = idd.name["materials/".len..];
                            try ent.putString(editor, ds.target_id, "texture", idd.name);
                        }
                    }
                },
            }

            editor.draw_state.tab_index = ds.previous_pane_index;
        }
        editor.draw_state.tab_index = 0;
    }
};

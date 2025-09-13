const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const vmf = @import("vmf.zig");
const ROOT_LAYER_NAME = "world";
const json_map = @import("json_map.zig");
const edit = @import("editor.zig");
const action = @import("actions.zig");
const Undo = @import("undo.zig");

/// Rathammer supports up to 2**16 visgroups but hammer does not
pub const MAX_VIS_GROUP_VMF = 128;

pub const Id = u16;
pub const Layer = struct {
    children: ArrayList(*Layer),

    color: u32,
    name: []const u8,
    id: Id,

    enabled: bool = true,
};

const log = std.log.scoped(.layer);
pub const Context = struct {
    const Self = @This();
    layers: ArrayList(*Layer) = .{},
    map: std.AutoHashMap(Id, *Layer),

    /// Maps vmf vis groups to Id
    vmf_id_mapping: std.AutoHashMap(u8, Id),

    alloc: std.mem.Allocator,
    root: *Layer,

    layer_counter: Id = 0,

    /// Bitmask that can be directly tested for visibility.
    /// Toggling a parent layers "enabled" field doesn't affect child's "enabled" flag but does affect the 'disabled' state
    disabled: std.DynamicBitSetUnmanaged = .{},

    pub fn init(alloc: std.mem.Allocator) !Self {
        const root = try createLayer(alloc, 0, ROOT_LAYER_NAME);
        var ret = Self{
            .alloc = alloc,
            .root = root,
            .disabled = try std.DynamicBitSetUnmanaged.initEmpty(alloc, 1),
            .map = std.AutoHashMap(Id, *Layer).init(alloc),
            .vmf_id_mapping = std.AutoHashMap(u8, Id).init(alloc),
        };
        try ret.layers.append(alloc, root);
        try ret.map.put(0, root);

        return ret;
    }

    pub fn deinit(self: *Self) void {
        for (self.layers.items) |layer| {
            self.alloc.free(layer.name);
            layer.children.deinit(self.alloc);
            self.alloc.destroy(layer);
        }
        self.vmf_id_mapping.deinit();
        self.map.deinit();
        self.disabled.deinit(self.alloc);
        self.layers.deinit(self.alloc);
    }

    fn newLayerId(self: *Self) Id {
        self.layer_counter += 1;
        return self.layer_counter;
    }

    fn createLayer(alloc: std.mem.Allocator, id: Id, name: []const u8) !*Layer {
        const lay = try alloc.create(Layer);
        lay.* = .{
            .children = .{},
            .name = try alloc.dupe(u8, name),
            .color = 0xff,
            .id = id,
        };
        return lay;
    }

    pub fn newLayerUnattached(self: *Self, name: []const u8) !*Layer {
        const new_id = self.newLayerId();
        const new = try createLayer(self.alloc, new_id, name);
        try self.map.put(new_id, new);
        try self.layers.append(self.alloc, new);

        return new;
    }

    pub fn newLayer(self: *Self, name: []const u8, parent: Id, opts: struct { insert_at: ?usize = null }) !*Layer {
        const lay = self.getLayerFromId(parent) orelse return error.invalidParent;
        const new_id = self.newLayerId();
        const new = try createLayer(self.alloc, new_id, name);
        try self.map.put(new_id, new);
        try self.layers.append(self.alloc, new);

        const new_child_index = @min(opts.insert_at orelse lay.children.items.len, lay.children.items.len);

        try lay.children.insert(self.alloc, new_child_index, new);
        return new;
    }

    pub fn setName(self: *Self, id: Id, name: []const u8) !void {
        if (self.getLayerFromId(id)) |lay| {
            self.alloc.free(lay.name);
            lay.name = try self.alloc.dupe(u8, name);
        }
    }

    pub fn setEnabled(self: *Self, id: Id, enable: bool) !void {
        if (self.map.get(id)) |lay| {
            lay.enabled = enable;
            try self.calculateDisabled();
        }
    }

    //TODO this needs to start with all disabled so deleted are omitted
    fn calculateDisabled(self: *Self) !void {
        self.disabled.unsetAll();
        try self.recurDisabledSet(self.root, false);
    }

    fn recurDisabledSet(self: *Self, layer: *const Layer, force_disable: bool) !void {
        if (!layer.enabled or force_disable) {
            try self.setDisabled(layer.id);
            for (layer.children.items) |child| {
                try self.recurDisabledSet(child, true);
            }
        } else {
            for (layer.children.items) |child| {
                try self.recurDisabledSet(child, false);
            }
        }
    }

    pub fn isDisabled(self: *Self, id: Id) bool {
        if (id >= self.disabled.bit_length) return false;
        return self.disabled.isSet(id);
    }

    pub fn setDisabled(self: *Self, id: Id) !void {
        if (id >= self.disabled.count())
            try self.disabled.resize(self.alloc, @intCast(id + 1), false);
        self.disabled.set(id);
    }

    pub fn writeToJson(self: *Self, wr: anytype) !void {
        try self.writeGroupToJson(self.root, wr);
    }

    fn writeGroupToJson(self: *Self, layer: *const Layer, wr: anytype) !void {
        //if (group_id >= self.groups.items.len) return error.invalidVisgroup;
        //const group = self.groups.items[group_id];
        try wr.beginObject();
        try wr.objectField("name");
        try wr.write(layer.name);

        try wr.objectField("color");
        try wr.write(layer.color);

        try wr.objectField("enabled");
        try wr.write(layer.enabled);

        try wr.objectField("id");
        try wr.write(layer.id);
        try wr.objectField("children");
        try wr.beginArray();
        for (layer.children.items) |child|
            try self.writeGroupToJson(child, wr);
        try wr.endArray();
        try wr.endObject();
    }

    pub fn insertVisgroupsFromJson(self: *Self, json_vis: ?json_map.VisGroup) !void {
        const jv = json_vis orelse return;
        if (jv.id != 0) return; //Root must be 0

        // we omit insertion of the root node as the root is immutable.

        for (jv.children) |child| {
            try self.insertRecur(self.root, child);
        }
    }

    fn insertRecur(self: *Self, parent: *Layer, layer: json_map.VisGroup) !void {
        if (self.map.contains(layer.id)) {
            log.warn("layer with duplicate id: {d} {s}, omitting", .{ layer.id, layer.name });
            return;
        }

        //Ensure any new groups don't intersect with old
        self.layer_counter = @max(self.layer_counter, layer.id);

        const new = try createLayer(self.alloc, layer.id, layer.name);
        try self.layers.append(self.alloc, new);
        try self.map.put(layer.id, new);

        try parent.children.append(self.alloc, new);

        for (layer.children) |child| {
            try self.insertRecur(new, child);
        }
    }

    pub fn getOrPutTopLevelGroup(self: *Self, name: []const u8) !Id {
        for (self.root.children.items) |child| {
            if (std.mem.eql(u8, child.name, name))
                return child.id;
        }

        return (try self.newLayer(name, self.root.id, .{})).id;
    }

    pub fn buildMappingFromVmf(self: *Self, vmf_visgroups: []const vmf.VisGroup, parent: *Layer) !void {
        for (vmf_visgroups) |gr| {
            const vis_group_id: u8 = if (gr.visgroupid > MAX_VIS_GROUP_VMF or gr.visgroupid < 0) continue else @intCast(gr.visgroupid);
            if (!self.vmf_id_mapping.contains(vis_group_id)) {
                const new = try self.newLayer(gr.name, parent.id, .{});

                try self.vmf_id_mapping.put(vis_group_id, new.id);
                //std.debug.print("PUtting visgroup {s}\n", .{gr.name});
                try self.buildMappingFromVmf(gr.visgroup, new);
            } else {
                std.debug.print("Duplicate vis group {s} with id {d}, omitting\n", .{ gr.name, gr.visgroupid });
            }
        }
    }

    pub fn getIdFromEditorInfo(self: *Self, info: *const vmf.EditorInfo) ?Id {
        if (info.visgroupid.len < 1) return null;
        const id = info.visgroupid[0];
        if (id > MAX_VIS_GROUP_VMF or id < 0) return null;
        return self.vmf_id_mapping.get(@intCast(id));
    }

    pub fn printVis(self: *Self, layer: *Layer, depth: usize) void {
        for (0..depth) |_|
            std.debug.print(" ", .{});
        std.debug.print("{s} {d}\n", .{ layer.name, layer.id });
        for (layer.children.items) |child| {
            self.printVis(child, depth + 2);
        }
    }

    pub fn getLayerFromId(self: *const Self, id: Id) ?*Layer {
        return self.map.get(id);
    }

    /// Returns parent and index of id.
    pub fn getParent(self: *Self, node: *Layer, id: Id) ?struct { *Layer, usize } {
        for (node.children.items, 0..) |child, i| {
            if (child.id == id) {
                return .{ node, i };
            }
        }
        for (node.children.items) |child| {
            if (self.getParent(child, id)) |par| return par;
        }
        return null;
    }
};

const graph = @import("graph");
const guis = graph.RGui;
const Gui = guis.Gui;
const Wg = guis.Widget;
const iWindow = guis.iWindow;
const iArea = guis.iArea;
pub const GuiWidget = struct {
    const Self = @This();
    const bi = guis.Widget.BtnContextWindow.buttonId;
    const LayTemp = struct {
        ptr: *Layer,
        depth: Id,
    };
    ctx: *Context,
    editor: *edit.Context,
    vt: iArea = undefined,
    win: *iWindow,
    scroll_index: usize = 0,

    selected_ptr: *Id,

    pub fn init(ctx: *Context, selected_ptr: *Id, editor: *edit.Context, win: *iWindow) Self {
        return .{ .ctx = ctx, .selected_ptr = selected_ptr, .editor = editor, .win = win };
    }

    pub fn build(self: *Self, gui: *Gui, win: *iWindow, vt: *iArea, area: graph.Rect) !void {
        const item_h = gui.style.config.default_item_h;
        const bot_count = 3;
        const bot_h = item_h * bot_count;
        const sp = area.split(.horizontal, area.h - bot_h);
        {
            var ly = guis.VerticalLayout{ .item_height = item_h, .bounds = sp[1] };

            vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "New layer", .{
                .cb_vt = &self.vt,
                .cb_fn = btnCb,
                .id = bi("new_group"),
            }));
            vt.addChildOpt(gui, win, Wg.Textbox.buildOpts(gui, ly.getArea(), .{
                .commit_vt = &self.vt,
                .init_string = if (self.ctx.getLayerFromId(self.selected_ptr.*)) |l| l.name else "",
                .commit_cb = textCb,
                .user_id = bi("set_name"),
            }));
        }

        vt.addChildOpt(gui, win, Wg.VScroll.build(gui, sp[0], .{
            .build_cb = &buildList,
            .build_vt = &self.vt,
            .win = win,
            .count = self.ctx.layers.items.len,
            .item_h = gui.style.config.default_item_h,
            .index_ptr = &self.scroll_index,
        }));
    }

    fn buildList(vt: *iArea, ar: *iArea, index: usize, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));

        var list = std.ArrayList(LayTemp).init(gui.alloc);
        defer list.deinit();
        list.append(.{ .ptr = self.ctx.root, .depth = 0 }) catch return;
        countNodes(self.ctx.root, &list, 1) catch return;
        if (index >= list.items.len) return;
        const item_h = gui.style.config.default_item_h;
        var ly = guis.VerticalLayout{ .item_height = item_h, .bounds = ar.area };
        for (list.items[index..]) |item| {
            const ar_p = ly.getArea() orelse continue;
            const area = ar_p.split(.vertical, @as(f32, @floatFromInt(item.depth)) * item_h)[1];
            ar.addChildOpt(gui, win, LayerWidget.build(gui, area, .{
                .name = item.ptr.name,
                .win = win,
                .selected = (self.selected_ptr.* == item.ptr.id),
                .id = item.ptr.id,
                .parent = self,
                .enabled = item.ptr.enabled,
            }));
        }
    }

    fn textCb(vt: *iArea, _: *Gui, new: []const u8, id: guis.Uid) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (id) {
            bi("set_name") => {
                self.ctx.setName(self.selected_ptr.*, new) catch {};
                self.win.needs_rebuild = true;
            },
            else => {},
        }
    }

    fn btnCb(vt: *iArea, id: guis.Uid, _: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (id) {
            bi("new_group") => {
                if (action.createLayer(self.editor, self.selected_ptr.*, "new layer") catch null) |new_id| {
                    self.selected_ptr.* = new_id;
                    win.needs_rebuild = true;
                }
            },
            else => {},
        }
    }

    fn countNodes(layer: *Layer, list: *std.ArrayList(LayTemp), depth: Id) !void {
        for (layer.children.items) |child| {
            try list.append(.{ .ptr = child, .depth = depth });
            try countNodes(child, list, depth + 1);
        }
    }
};

/// How will entity groups and layers be handled?
/// Owner entitie's layers have no effect on owned entities layer.
///
/// So you could put half a func_detail in one layer, half in another.
///
const LayerWidget = struct {
    const Opts = struct {
        name: []const u8,
        win: *iWindow,
        id: Id,
        selected: bool,
        parent: *GuiWidget,
        color: u32 = 0xffff00ff,
        enabled: bool,
    };
    vt: iArea,

    opts: Opts,

    pub fn build(gui: *Gui, area_o: ?graph.Rect, opts: Opts) ?*iArea {
        const area = area_o orelse return null;
        const self = gui.create(@This());
        self.* = .{
            .vt = iArea.init(gui, area),
            .opts = opts,
        };
        self.vt.deinit_fn = &deinit;
        self.vt.draw_fn = &draw;
        self.vt.onclick = &onclick;

        const sp = area.split(.vertical, area.h);

        self.vt.addChildOpt(gui, opts.win, Wg.Checkbox.build(gui, sp[0], "", .{
            .style = .check,
            .cb_fn = check_cb,
            .cb_vt = &self.vt,
            .user_id = opts.id,
        }, opts.enabled));
        self.vt.addChildOpt(gui, opts.win, Wg.Text.buildStatic(gui, sp[1], opts.name, 0x0));

        return &self.vt;
    }

    pub fn draw(vt: *iArea, d: guis.DrawState) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const col: u32 = if (self.opts.selected) 0x6097dbff else d.style.config.colors.background;
        d.ctx.rect(vt.area, col);
        const thi = 2;
        const y = vt.area.y + vt.area.h - thi;
        d.ctx.line(.{ .x = vt.area.x, .y = y }, .{ .x = vt.area.x + vt.area.w, .y = y }, self.opts.color, thi);
    }

    pub fn deinit(vt: *iArea, gui: *Gui, window: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = window;
        gui.alloc.destroy(self);
    }

    pub fn check_cb(vt: *iArea, gui: *Gui, checked: bool, uid: guis.Uid) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.opts.parent.ctx.setEnabled(@intCast(uid), checked) catch return;
        self.opts.parent.editor.rebuildVisGroups() catch return;
        _ = gui;
    }

    pub fn onclick(vt: *iArea, cb: guis.MouseCbState, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (cb.btn) {
            else => {},
            .left => {
                self.opts.parent.selected_ptr.* = self.opts.id;
                win.needs_rebuild = true;
            },
            .right => {
                const bi = guis.Widget.BtnContextWindow.buttonId;
                const pos = graph.Vec2f{ .x = @round(cb.pos.x), .y = @round(cb.pos.y) };
                const r_win = guis.Widget.BtnContextWindow.create(cb.gui, pos, .{
                    .buttons = &.{
                        .{ bi("cancel"), "Cancel " },
                        .{ bi("move_selected"), "-> Put selected" },
                        .{ bi("select_all"), "<- Select contained" },
                        .{ bi("delete"), "Delete layer" },
                        .{ bi("merge"), "^ merge up" },
                        .{ bi("duplicate"), "Duplicate layer" },
                        .{ bi("add_child"), "new child" },
                    },
                    .btn_cb = rightClickMenuBtn,
                    .btn_vt = vt,
                }) catch return;
                cb.gui.setTransientWindow(r_win);
            },
        }
    }

    fn rightClickMenuBtn(vt: *iArea, id: guis.Uid, gui: *Gui, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        vt.dirty(gui);
        const ed = self.opts.parent.editor;
        const bi = guis.Widget.BtnContextWindow.buttonId;
        switch (id) {
            bi("select_all") => {
                ed.selection.setToMulti();

                var it = ed.editIterator(.layer);
                while (it.next()) |item| {
                    if (item.id == self.opts.id) {
                        ed.selection.tryAddMulti(it.i) catch return;
                    }
                }
            },
            bi("move_selected") => {
                action.addSelectionToLayer(ed, self.opts.id) catch return;
            },
            bi("add_child") => {
                if (action.createLayer(ed, self.opts.parent.selected_ptr.*, "new layer") catch null) |new_id| {
                    self.opts.parent.selected_ptr.* = new_id;
                }
            },
            bi("duplicate") => {
                action.dupeLayer(ed, self.opts.parent.selected_ptr.*) catch return;
            },
            bi("delete") => {
                if (action.deleteLayer(ed, self.opts.parent.selected_ptr.*) catch null) |new_selected| {
                    self.opts.parent.selected_ptr.* = new_selected;
                }
            },
            bi("merge") => {
                const lays = self.opts.parent.ctx;
                if (lays.getParent(lays.root, self.opts.parent.selected_ptr.*)) |parent| {
                    const merge_id = if (parent[1] > 0) parent[0].children.items[parent[1] - 1].id else parent[0].id;
                    action.mergeLayer(ed, self.opts.parent.selected_ptr.*, merge_id) catch {};
                    self.opts.parent.selected_ptr.* = merge_id;
                }
            },
            else => {},
        }
        self.opts.win.needs_rebuild = true;
    }
};

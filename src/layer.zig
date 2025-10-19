const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const vmf = @import("vmf.zig");
const ROOT_LAYER_NAME = "world";
const json_map = @import("json_map.zig");
const edit = @import("editor.zig");
const action = @import("actions.zig");
const Undo = @import("undo.zig");

//LAYER TODO
//Indicate children are hidden
//toggle child visiblity
//ensure disabled mask is correct with deleted layers

/// Rathammer supports up to 2**16 visgroups but hammer does not
pub const MAX_VIS_GROUP_VMF = 128;

pub const Id = enum(u16) {
    none,
    _,

    pub fn initFromJson(v: std.json.Value, _: anytype) !@This() {
        if (v != .integer) return error.expectedInt;

        if (v.integer < 0 or v.integer > std.math.maxInt(u16)) return error.layerIdOutOfRange;

        return @enumFromInt(@as(u16, @intCast(v.integer)));
    }

    pub fn serial(self: @This(), _: anytype, jw: anytype, _: anytype) !void {
        try jw.write(@as(u16, @intFromEnum(self)));
    }
};
pub const Layer = struct {
    children: ArrayList(*Layer),

    color: u32,
    name: []const u8,
    id: Id,

    enabled: bool = true,
    collapse: bool = false,
};

const log = std.log.scoped(.layer);
/// Layers are never destroyed. Deletion of a layer only removes the layer from the tree specifed by `root`.
pub const Context = struct {
    const Self = @This();
    layers: ArrayList(*Layer) = .{},
    map: std.AutoHashMap(Id, *Layer),

    /// Maps vmf vis groups to Id
    vmf_id_mapping: std.AutoHashMap(u8, Id),

    alloc: std.mem.Allocator,
    root: *Layer,

    layer_counter: u16 = 0,

    /// Bitmask that can be directly tested for visibility.
    /// Toggling a parent layers "enabled" field doesn't affect child's "enabled" flag but does affect the 'disabled' state
    disabled: std.DynamicBitSetUnmanaged = .{},

    pub fn init(alloc: std.mem.Allocator) !Self {
        const root = try createLayer(alloc, .none, ROOT_LAYER_NAME);
        var ret = Self{
            .alloc = alloc,
            .root = root,
            .disabled = try std.DynamicBitSetUnmanaged.initEmpty(alloc, 1),
            .map = std.AutoHashMap(Id, *Layer).init(alloc),
            .vmf_id_mapping = std.AutoHashMap(u8, Id).init(alloc),
        };
        try ret.layers.append(alloc, root);
        try ret.map.put(.none, root);

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
        return @enumFromInt(self.layer_counter);
    }

    /// Return bitset with ids below `lay` set. Caller must free result
    pub fn gatherChildren(self: *const Self, alloc: std.mem.Allocator, lay: *const Layer) !struct { std.DynamicBitSetUnmanaged, []const Id } {
        var ids = std.ArrayListUnmanaged(Id){};
        try gatherChildrenRecur(&ids, lay, alloc);
        var mask = try std.DynamicBitSetUnmanaged.initEmpty(alloc, self.layer_counter + 1);
        for (ids.items) |id|
            mask.set(@intFromEnum(id));
        return .{ mask, try ids.toOwnedSlice(alloc) };
    }

    fn gatherChildrenRecur(list: *std.ArrayListUnmanaged(Id), lay: *const Layer, alloc: std.mem.Allocator) !void {
        try list.append(alloc, lay.id);
        for (lay.children.items) |child|
            try gatherChildrenRecur(list, child, alloc);
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

    /// TODO set enabled state of a layer recursively apply to children
    pub fn setEnabledCascade(self: *Self, id: Id, enable: bool) !void {
        if (self.map.get(id)) |lay| {
            lay.enabled = enable;
            try self.recurDisable(lay, enable);
        }
    }

    pub fn setCollapse(self: *Self, id: Id, collapsed: bool) void {
        if (self.map.get(id)) |lay| {
            lay.collapse = collapsed;
        }
    }

    pub fn recurDisable(self: *Self, layer: *const Layer, enable: bool) !void {
        //always disable layers, only enable layers if they are enabled
        const en = if (enable) layer.enabled else false;
        try self.setDisabled(layer.id, en);
        for (layer.children.items) |child| {
            try self.recurDisable(child, enable);
        }
    }

    pub fn isDisabled(self: *Self, id: Id) bool {
        if (@intFromEnum(id) >= self.disabled.bit_length) return false;
        return self.disabled.isSet(@intFromEnum(id));
    }

    pub fn setDisabled(self: *Self, id: Id, enable: bool) !void {
        const idd: u16 = @intFromEnum(id);
        if (idd >= self.disabled.bit_length)
            try self.disabled.resize(self.alloc, @intCast(idd + 1), false);
        self.disabled.setValue(idd, !enable);
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
        try wr.write(@as(u16, @intFromEnum(layer.id)));
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
        if (self.map.contains(@enumFromInt(layer.id))) {
            log.warn("layer with duplicate id: {d} {s}, omitting", .{ layer.id, layer.name });
            return;
        }

        //Ensure any new groups don't intersect with old
        self.layer_counter = @max(self.layer_counter, layer.id);

        const new = try createLayer(self.alloc, @enumFromInt(layer.id), layer.name);
        try self.layers.append(self.alloc, new);
        try self.map.put(@enumFromInt(layer.id), new);

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

    /// Returns true if child is a child of parent or if child == parent
    pub fn isChildOf(self: *Self, parent: Id, child: Id) bool {
        const H = struct {
            fn isChildRecur(pa: *Layer, ch: *Layer) bool {
                if (pa.id == ch.id) return true;
                for (pa.children.items) |np| {
                    if (isChildRecur(np, ch))
                        return true;
                }
                return false;
            }
        };
        const p = self.getLayerFromId(parent) orelse return false;
        const ch = self.getLayerFromId(child) orelse return false;

        return H.isChildRecur(p, ch);
    }
};

const graph = @import("graph");
const guis = graph.RGui;
const Gui = guis.Gui;
const Wg = guis.Widget;
const iWindow = guis.iWindow;
const iArea = guis.iArea;
const CbHandle = guis.CbHandle;
pub const GuiWidget = struct {
    const Self = @This();
    const bi = guis.Widget.BtnContextWindow.buttonId;
    const LayTemp = struct {
        ptr: *Layer,
        depth: u16,
    };
    ctx: *Context,
    editor: *edit.Context,
    cbhandle: CbHandle = .{},
    win: *iWindow,
    scroll_index: usize = 0,

    selected_ptr: *Id,

    pub fn init(ctx: *Context, selected_ptr: *Id, editor: *edit.Context, win: *iWindow) Self {
        return .{ .ctx = ctx, .selected_ptr = selected_ptr, .editor = editor, .win = win };
    }

    pub fn build(self: *Self, gui: *Gui, win: *iWindow, vt: *iArea, area: graph.Rect) !void {
        const item_h = gui.dstate.style.config.default_item_h;
        const bot_count = 3;
        const bot_h = item_h * bot_count;
        const sp = area.split(.horizontal, area.h - bot_h);
        {
            var ly = gui.dstate.vLayout(sp[1]);

            _ = Wg.Button.build(vt, ly.getArea(), "New layer", .{
                .cb_vt = &self.cbhandle,
                .cb_fn = btnCb,
                .id = bi("new_group"),
            });
            _ = Wg.Textbox.buildOpts(vt, ly.getArea(), .{
                .commit_vt = &self.cbhandle,
                .init_string = if (self.ctx.getLayerFromId(self.selected_ptr.*)) |l| l.name else "",
                .commit_cb = textCb,
                .user_id = bi("set_name"),
            });
        }

        _ = Wg.VScroll.build(vt, sp[0], .{
            .build_cb = &buildList,
            .build_vt = &self.cbhandle,
            .win = win,
            .count = self.ctx.layers.items.len,
            .item_h = item_h,
            .index_ptr = &self.scroll_index,
        });
    }

    fn buildList(cb: *CbHandle, ar: *iArea, index: usize) void {
        const gui = ar.win_ptr.gui_ptr;
        const win = ar.win_ptr;

        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));

        var list = std.ArrayList(LayTemp).init(gui.alloc);
        defer list.deinit();
        list.append(.{ .ptr = self.ctx.root, .depth = 0 }) catch return;
        countNodes(self.ctx.root, &list, 1) catch return;
        if (index >= list.items.len) return;
        const item_h = gui.dstate.style.config.default_item_h;
        var ly = gui.dstate.vLayout(ar.area);
        for (list.items[index..]) |item| {
            const ar_p = ly.getArea() orelse continue;
            const area = ar_p.split(.vertical, @as(f32, @floatFromInt(item.depth)) * item_h)[1];
            _ = LayerWidget.build(ar, area, .{
                .name = item.ptr.name,
                .win = win,
                .selected = (self.selected_ptr.* == item.ptr.id),
                .id = item.ptr.id,
                .parent = self,
                .enabled = item.ptr.enabled,
                .collapse = item.ptr.collapse,
                .check_color = if (self.ctx.isDisabled(item.ptr.id)) 0x888888ff else 0xff,
            });
        }
    }

    fn textCb(vt: *CbHandle, _: *Gui, new: []const u8, id: guis.Uid) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", vt));
        switch (id) {
            bi("set_name") => {
                self.ctx.setName(self.selected_ptr.*, new) catch {};
                self.win.needs_rebuild = true;
            },
            else => {},
        }
    }

    fn btnCb(vt: *CbHandle, id: guis.Uid, _: guis.MouseCbState, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", vt));
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

    fn countNodes(layer: *Layer, list: *std.ArrayList(LayTemp), depth: u16) !void {
        if (layer.collapse) return;
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
        collapse: bool,
        check_color: u32 = 0xff,
    };
    vt: iArea,
    cbhandle: guis.CbHandle = .{},

    opts: Opts,
    right_click_id: ?Id = null,

    pub fn build(parent: *iArea, area_o: ?graph.Rect, opts: Opts) guis.WgStatus {
        const gui = parent.win_ptr.gui_ptr;

        const area = area_o orelse return .failed;
        const self = gui.create(@This());
        self.* = .{
            .vt = .UNINITILIZED,
            .opts = opts,
        };
        parent.addChild(&self.vt, .{ .area = area, .deinit_fn = deinit, .draw_fn = draw, .onclick = onclick });

        const needs_dropdown = if (opts.parent.ctx.getLayerFromId(opts.id)) |lay| lay.children.items.len > 0 else false;
        const sp = area.split(.vertical, area.h * if (needs_dropdown) @as(f32, 2) else @as(f32, 1));
        const ch = sp[0].split(.vertical, area.h);

        _ = Wg.Checkbox.build(&self.vt, ch[0], "", .{
            .style = .check,
            .cb_fn = check_cb,
            .cb_vt = &self.cbhandle,
            .user_id = @intFromEnum(opts.id),
            .cross_color = opts.check_color,
        }, opts.enabled);

        if (needs_dropdown)
            _ = Wg.Checkbox.build(&self.vt, ch[1], "", .{
                .style = .dropdown,
                .cb_fn = collapse_cb,
                .cb_vt = &self.cbhandle,
                .user_id = @intFromEnum(opts.id),
                .cross_color = gui.dstate.nstyle.color.drop_down_arrow,
            }, !opts.collapse);
        _ = Wg.Text.buildStatic(&self.vt, sp[1], opts.name, 0x0);
        return .good;
    }

    pub fn draw(vt: *iArea, _: *guis.Gui, d: *guis.DrawState) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const col: u32 = if (self.opts.selected) 0x6097dbff else d.nstyle.color.bg;
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

    pub fn check_cb(cb: *CbHandle, gui: *Gui, checked: bool, uid: guis.Uid) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.opts.parent.ctx.setEnabledCascade(@enumFromInt(@as(u16, @intCast(uid))), checked) catch return;
        self.opts.parent.editor.rebuildVisGroups() catch return;
        self.opts.win.needs_rebuild = true;
        _ = gui;
    }

    pub fn collapse_cb(cb: *CbHandle, gui: *Gui, checked: bool, uid: guis.Uid) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.opts.parent.ctx.setCollapse(@enumFromInt((uid)), !checked);
        self.opts.win.needs_rebuild = true;
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
                const aa = self.opts.parent.editor.frame_arena.allocator();
                var btns = ArrayList(guis.Widget.BtnContextWindow.ButtonMapping){};
                const allow_move = !self.opts.parent.ctx.isChildOf(self.opts.parent.selected_ptr.*, self.opts.id);

                btns.append(aa, .{ bi("cancel"), "cancel ", .btn }) catch {};
                btns.append(aa, .{ bi("move_selected"), "-> put", .btn }) catch {};
                btns.append(aa, .{ bi("select_all"), "<- select", .btn }) catch {};
                btns.append(aa, .{ bi("duplicate"), "duplicate", .btn }) catch {};
                btns.append(aa, .{ bi("add_child"), "new child", .btn }) catch {};
                btns.append(aa, .{ bi("noop"), "", .btn }) catch {};
                if (self.opts.id != .none) { //Root cannot be deleted or merged
                    btns.append(aa, .{ bi("delete"), "delete layer", .btn }) catch {};
                    btns.append(aa, .{ bi("merge"), "^ merge up", .btn }) catch {};
                    if (allow_move)
                        btns.append(aa, .{ bi("attach_sib"), "attach as sibling", .btn }) catch {};
                }
                if (allow_move)
                    btns.append(aa, .{ bi("attach_child"), "attach as child", .btn }) catch {};

                const r_win = guis.Widget.BtnContextWindow.create(cb.gui, pos, .{
                    .buttons = btns.items,
                    .btn_cb = rightClickMenuBtn,
                    .btn_vt = &self.cbhandle,
                }) catch return;
                self.right_click_id = self.opts.id;
                cb.gui.setTransientWindow(r_win);
            },
        }
    }

    fn rightClickMenuBtn(cb: *CbHandle, id: guis.Uid, dat: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.vt.dirty(dat.gui);
        const ed = self.opts.parent.editor;
        const sel_id = self.right_click_id orelse return;
        const bi = guis.Widget.BtnContextWindow.buttonId;
        switch (id) {
            bi("select_all") => {
                ed.selection.setToMulti();

                const aa = ed.frame_arena.allocator();
                const mask = (ed.layers.gatherChildren(aa, ed.layers.getLayerFromId(sel_id) orelse return) catch return)[0];

                var it = ed.editIterator(.layer);
                while (it.next()) |item| {
                    if (mask.isSet(@intFromEnum(item.id))) {
                        ed.selection.add(it.i, ed) catch return;
                    }
                }
            },
            bi("move_selected") => {
                action.addSelectionToLayer(ed, self.opts.id) catch return;
            },
            bi("add_child") => {
                if (action.createLayer(ed, sel_id, "new layer") catch null) |new_id| {
                    self.opts.parent.selected_ptr.* = new_id;
                }
            },
            bi("duplicate") => {
                action.dupeLayer(ed, sel_id) catch return;
            },
            bi("delete") => {
                if (action.deleteLayer(ed, sel_id) catch null) |new_selected| {
                    self.opts.parent.selected_ptr.* = new_selected;
                }
            },
            bi("merge") => {
                const lays = self.opts.parent.ctx;
                if (lays.getParent(lays.root, sel_id)) |parent| {
                    const merge_id = if (parent[1] > 0) parent[0].children.items[parent[1] - 1].id else parent[0].id;
                    action.mergeLayer(ed, sel_id, merge_id) catch {};
                    self.opts.parent.selected_ptr.* = merge_id;
                }
            },
            bi("attach_child") => {
                action.moveLayer(ed, self.opts.parent.selected_ptr.*, sel_id, 0) catch {};
            },
            bi("attach_sib") => {
                if (ed.layers.getParent(ed.layers.root, sel_id)) |parent| {
                    const moved_parent = ed.layers.getParent(ed.layers.root, self.opts.parent.selected_ptr.*) orelse return;

                    //Special case for movements within a layer,
                    //otherwise index calculation + 1 is incorrent because length changes when the layer is removed
                    const new_index = if (moved_parent[0].id == parent[0].id) parent[1] else parent[1] + 1;
                    action.moveLayer(ed, self.opts.parent.selected_ptr.*, parent[0].id, new_index) catch {};
                }
            },
            else => {},
        }
        self.opts.win.needs_rebuild = true;
    }
};

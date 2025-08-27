const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const vmf = @import("vmf.zig");
const ROOT_LAYER_NAME = "world";
const json_map = @import("json_map.zig");

/// Rathammer supports up to 2**16 visgroups but hammer does not
pub const MAX_VIS_GROUP_VMF = 128;

pub const Id = u16;
const Layer = struct {
    children: ArrayList(*Layer),

    color: u32,
    name: []const u8,
    id: Id,
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

    pub fn newLayer(self: *Self, name: []const u8, parent: Id) !*Layer {
        const lay = self.getLayerFromId(parent) orelse return error.invalidParent;
        const new_id = self.newLayerId();
        const new = try createLayer(self.alloc, new_id, name);
        try self.map.put(new_id, new);
        try self.layers.append(self.alloc, new);
        try lay.children.append(self.alloc, new);
        return new;
    }

    pub fn setName(self: *Self, id: Id, name: []const u8) !void {
        if (self.getLayerFromId(id)) |lay| {
            self.alloc.free(lay.name);
            lay.name = try self.alloc.dupe(u8, name);
        }
    }

    pub fn isDisabled(self: *Self, id: Id) bool {
        if (id >= self.disabled.bit_length) return false;
        return self.disabled.isSet(id);
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

        return (try self.newLayer(name, self.root.id)).id;
    }

    pub fn buildMappingFromVmf(self: *Self, vmf_visgroups: []const vmf.VisGroup, parent: *Layer) !void {
        for (vmf_visgroups) |gr| {
            const vis_group_id: u8 = if (gr.visgroupid > MAX_VIS_GROUP_VMF or gr.visgroupid < 0) continue else @intCast(gr.visgroupid);
            if (!self.vmf_id_mapping.contains(vis_group_id)) {
                const new = try self.newLayer(gr.name, parent.id);

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
    vt: iArea = undefined,

    selected_ptr: *Id,

    pub fn init(ctx: *Context, selected_ptr: *Id) Self {
        return .{ .ctx = ctx, .selected_ptr = selected_ptr };
    }

    pub fn build(self: *Self, gui: *Gui, win: *iWindow, vt: *iArea, area: graph.Rect) !void {
        const item_h = gui.style.config.default_item_h;
        const bot_count = 3;
        const bot_h = item_h * bot_count;
        const sp = area.split(.horizontal, area.h - bot_h);
        {
            var ly = guis.VerticalLayout{ .item_height = item_h, .bounds = sp[1] };

            vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "New group", .{
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
        }));
    }

    fn buildList(vt: *iArea, ar: *iArea, index: usize, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));

        var list = std.ArrayList(LayTemp).init(gui.alloc);
        defer list.deinit();
        countNodes(self.ctx.root, &list, 0) catch return;
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
            }));
        }
    }

    fn textCb(vt: *iArea, _: *Gui, new: []const u8, id: guis.Uid) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (id) {
            bi("set_name") => {
                self.ctx.setName(self.selected_ptr.*, new) catch {};
            },
            else => {},
        }
    }

    fn btnCb(vt: *iArea, id: guis.Uid, _: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (id) {
            bi("new_group") => {
                _ = self.ctx.newLayer("new layer", self.selected_ptr.*) catch {};

                win.needs_rebuild = true;
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

const LayerWidget = struct {
    const Opts = struct {
        name: []const u8,
        win: *iWindow,
        id: Id,
        selected: bool,
        parent: *GuiWidget,
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

        self.vt.addChildOpt(gui, opts.win, Wg.Text.buildStatic(gui, area, opts.name, 0x0));

        return &self.vt;
    }

    pub fn draw(vt: *iArea, d: guis.DrawState) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const col: u32 = if (self.opts.selected) 0x6097dbff else d.style.config.colors.background;
        d.ctx.rect(vt.area, col);
    }

    pub fn deinit(vt: *iArea, gui: *Gui, window: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = window;
        gui.alloc.destroy(self);
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
                const r_win = guis.Widget.BtnContextWindow.create(cb.gui, cb.pos, .{
                    .buttons = &.{
                        .{ bi("cancel"), "Cancel" },
                        .{ bi("move_selected"), "Move selected to layer" },
                        .{ bi("delete"), "Delete layer" },
                        .{ bi("select_all"), "Select contained" },
                        .{ bi("duplicate"), "Duplicate layer" },
                        .{ bi("add_child"), "add child group" },
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
        _ = self;
        vt.dirty(gui);
        const bi = guis.Widget.BtnContextWindow.buttonId;
        _ = bi;
        switch (id) {
            //bi("copy") => setClipboard(self.codepoints.allocator, self.getSelectionSlice()) catch return,
            //bi("paste") => self.paste() catch return,
            else => {},
        }
    }
};

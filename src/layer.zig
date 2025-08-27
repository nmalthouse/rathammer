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
        try self.map.put(0, new);

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

        const new_id = self.newLayerId();
        const new = try createLayer(self.alloc, new_id, name);

        try self.map.put(new_id, new);
        try self.layers.append(self.alloc, new);
        return new_id;
    }

    pub fn buildMappingFromVmf(self: *Self, vmf_visgroups: []const vmf.VisGroup, parent: *Layer) !void {
        for (vmf_visgroups) |gr| {
            const vis_group_id: u8 = if (gr.visgroupid > MAX_VIS_GROUP_VMF or gr.visgroupid < 0) continue else @intCast(gr.visgroupid);
            if (!self.vmf_id_mapping.contains(vis_group_id)) {
                const new_id = self.newLayerId();
                if (new_id > MAX_VIS_GROUP_VMF)
                    return error.tooManyVisgroups;
                try self.vmf_id_mapping.put(vis_group_id, new_id);

                const new = try createLayer(self.alloc, new_id, gr.name);

                try self.layers.append(self.alloc, new);
                try self.map.put(new_id, new);

                try parent.children.append(self.alloc, new);
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
};

const graph = @import("graph");
const guis = graph.RGui;
const Gui = guis.Gui;
const Wg = guis.Widget;
const iWindow = guis.iWindow;
const iArea = guis.iArea;
pub const GuiWidget = struct {
    const Self = @This();
    ctx: *Context,

    pub fn init(ctx: *Context) Self {
        return .{ .ctx = ctx };
    }

    pub fn build(self: *Self, gui: *Gui, win: *iWindow, vt: *iArea, area: graph.Rect) !void {
        const item_h = gui.style.config.default_item_h;
        const bot_count = 3;
        const bot_h = item_h * bot_count;
        const sp = area.split(.horizontal, area.h - bot_h);
        {
            var ly = guis.VerticalLayout{ .item_height = item_h, .bounds = sp[1] };

            vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "New group", .{}));
        }

        {
            var ly = guis.VerticalLayout{ .item_height = item_h, .bounds = sp[0] };
            self.labelRecur(gui, win, &ly, vt, self.ctx.root);
            //for (self.ctx.layers.items) |layer| {
            //    vt.addChildOpt(gui, win, Wg.Text.build(gui, ly.getArea(), "{s}", .{layer.name}));
            //}
        }
    }

    fn labelRecur(self: *Self, gui: *Gui, win: *iWindow, ly: anytype, vt: *iArea, lay: *Layer) void {
        for (lay.children.items) |layer| {
            vt.addChildOpt(gui, win, Wg.Text.build(gui, ly.getArea(), "{s}", .{layer.name}));
            self.labelRecur(gui, win, ly, vt, layer);
        }
    }
};

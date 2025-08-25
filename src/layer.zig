const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const ROOT_LAYER_NAME = "world";

const Layer = struct {
    children: ArrayList(*Layer),

    name: []const u8,
    id: usize,
};

pub const Context = struct {
    const Self = @This();
    layers: ArrayList(*Layer) = .{},
    alloc: std.mem.Allocator,

    layer_counter: usize = 0,

    pub fn init(alloc: std.mem.Allocator) !Self {
        var ret = Self{
            .alloc = alloc,
        };
        _ = try ret.newLayer(ROOT_LAYER_NAME);
        return ret;
    }

    pub fn deinit(self: *Self) void {
        for (self.layers.items) |layer| {
            self.alloc.free(layer.name);
            layer.children.deinit(self.alloc);
            self.alloc.destroy(layer);
        }
        self.layers.deinit(self.alloc);
    }

    fn newLayerId(self: *Self) usize {
        self.layer_counter += 1;
        return self.layer_counter;
    }

    pub fn newLayer(self: *Self, name: []const u8) !*Layer {
        const lay = try self.alloc.create(Layer);
        lay.* = .{
            .children = .{},
            .name = try self.alloc.dupe(u8, name),
            .id = self.newLayerId(),
        };
        try self.layers.append(self.alloc, lay);
        return lay;
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
            for (self.ctx.layers.items) |layer| {
                vt.addChildOpt(gui, win, Wg.Text.build(gui, ly.getArea(), "{s}", .{layer.name}));
            }
        }
    }
};

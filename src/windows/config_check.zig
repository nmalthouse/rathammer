const std = @import("std");
const graph = @import("graph");
const Gui = guis.Gui;
const Rec = graph.Rec;
const Rect = graph.Rect;
const DrawState = guis.DrawState;
const GuiHelp = guis.GuiHelp;
const guis = graph.RGui;
const iWindow = guis.iWindow;
const iArea = guis.iArea;
const Wg = guis.Widget;
const Context = @import("../editor.zig").Context;
const label = guis.label;
const util = @import("../util.zig");
const async_util = @import("../async.zig");
const Config = @import("../config.zig");
const CbHandle = guis.CbHandle;

pub const ConfigCheck = struct {
    cbhandle: CbHandle = .{},
    vt: iWindow,

    ed: *Context,

    pub fn create(gui: *Gui, editor: *Context) !*ConfigCheck {
        const self = gui.create(@This());
        self.* = .{
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, .{}, &self.vt),
            .ed = editor,
        };

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        vt.deinit(gui);
        gui.alloc.destroy(self); //second
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, _: *Gui, d: *DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
    }

    pub fn build(vt: *iWindow, gui: *Gui, new_area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        vt.area.area = new_area;
        vt.area.clearChildren(gui, vt);
        vt.area.dirty();
        const area = &vt.area;
        const inset = GuiHelp.insetAreaForWindowFrame(gui, vt.area.area);
        var ly = gui.dstate.vlayout(inset);
        _ = Wg.Text.build(
            area,
            ly.getArea(),
            "{s}",
            .{self.ed.dirs.games_dir.path},
        );
    }
};

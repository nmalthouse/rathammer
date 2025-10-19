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
const async_util = @import("../async.zig");
pub const NagWindow = struct {
    const Buttons = enum {
        quit,
        save,

        pub fn id(self: @This()) usize {
            return @intFromEnum(self);
        }
    };

    const Textboxes = enum {
        set_import_visgroup,
        set_skyname,
    };

    const HelpText = struct {
        text: std.ArrayList(u8),
        name: std.ArrayList(u8),
    };

    vt: iWindow,
    cbhandle: guis.CbHandle = .{},

    editor: *Context,
    should_exit: bool = false,

    pub fn create(gui: *Gui, editor: *Context) !*NagWindow {
        const self = gui.create(@This());
        self.* = .{
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, .{}, &self.vt),
            .editor = editor,
        };

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        //self.layout.deinit(gui, vt);
        vt.deinit(gui);
        gui.alloc.destroy(self); //second
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, _: *Gui, d: *DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
    }

    pub fn build(win: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", win));
        win.area.area = area;
        win.area.clearChildren(gui, win);
        win.area.dirty(gui);
        //self.layout.reset(gui, vt);
        //start a vlayout
        //var ly = Vert{ .area = vt.area };
        //const max_w = gui.style.config.default_item_h * 30;
        //const w = @min(max_w, inset.w);
        const inset = GuiHelp.insetAreaForWindowFrame(gui, win.area.area);
        //_ = self.area.addEmpty(gui, vt, graph.Rec(0, 0, 0, 0));
        var ly = gui.dstate.vLayout(inset);
        const Btn = Wg.Button.build;
        const ar = &win.area;
        _ = Wg.Text.buildStatic(ar, ly.getArea(), "Unsaved changes! ", null);
        _ = Btn(ar, ly.getArea(), "Save", .{ .cb_fn = &btnCb, .id = Buttons.id(.save), .cb_vt = &self.cbhandle });
        _ = Btn(ar, ly.getArea(), "Quit", .{ .cb_fn = &btnCb, .id = Buttons.id(.quit), .cb_vt = &self.cbhandle });
    }
    pub fn btnCb(cb: *guis.CbHandle, id: usize, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        switch (@as(Buttons, @enumFromInt(id))) {
            .quit => self.should_exit = true,
            .save => {
                self.vt.needs_rebuild = true;
                if (self.editor.loaded_map_name) |basename| {
                    self.editor.saveAndNotify(basename, self.editor.loaded_map_path orelse "") catch return;
                } else {
                    async_util.SdlFileData.spawn(self.editor.alloc, &self.editor.async_asset_load, .save_map) catch return;
                }
            },
        }
    }
};

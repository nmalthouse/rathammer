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
const L = @import("../locale.zig");

pub const NagWindow = struct {
    pub var nag_window_open: bool = false;
    const PostAction = enum {
        quit,
        close_map,
    };

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

    post: PostAction,

    vt: iWindow,
    cbhandle: guis.CbHandle = .{},

    editor: *Context,

    pub fn makeTransientWindow(gui: *Gui, ed: *Context, post_action: PostAction) !void {
        if (nag_window_open) return;
        const nag_win = try create(gui, ed, post_action);
        nag_win.vt.needs_rebuild = true;
        nag_win.vt.area.area = gui.getCenterArea(gui.dstate.nstyle.item_h * 80, gui.dstate.nstyle.item_h * 10);
        gui.setTransientWindow(&nag_win.vt, null);
    }

    pub fn create(gui: *Gui, editor: *Context, post_action: PostAction) !*NagWindow {
        const self = gui.create(@This());
        self.* = .{
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, .{}, &self.vt),
            .editor = editor,
            .post = post_action,
        };
        nag_window_open = true;

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        nag_window_open = false;
        vt.deinit(gui);
        gui.alloc.destroy(self);
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, _: *Gui, d: *DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
    }

    pub fn build(win: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", win));
        win.area.area = area;
        win.area.clearChildren(gui, win);
        win.area.dirty();
        //self.layout.reset(gui, vt);
        //start a vlayout
        //var ly = Vert{ .area = vt.area };
        //const max_w = gui.style.config.default_item_h * 30;
        //const w = @min(max_w, inset.w);
        const inset = GuiHelp.insetAreaForWindowFrame(gui, win.area.area);
        //_ = self.area.addEmpty(gui, vt, graph.Rec(0, 0, 0, 0));
        var ly = gui.dstate.vlayout(inset);
        const Btn = Wg.Button.build;
        const ar = &win.area;
        _ = Wg.Text.buildStatic(ar, ly.getArea(), L.lang.unsaved_changes, .{});
        _ = Btn(ar, ly.getArea(), L.lang.btn.save, .{ .cb_fn = &btnCb, .id = Buttons.id(.save), .cb_vt = &self.cbhandle });
        _ = Btn(ar, ly.getArea(), L.lang.btn.quit, .{ .cb_fn = &btnCb, .id = Buttons.id(.quit), .cb_vt = &self.cbhandle });
    }
    pub fn btnCb(cb: *guis.CbHandle, id: usize, mcb: guis.MouseCbState, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        mcb.gui.deferTransientClose(win);
        //Quit editor or close the map
        switch (@as(Buttons, @enumFromInt(id))) {
            .quit => {
                self.doPostAction() catch return;
            },
            .save => {
                self.vt.needs_rebuild = true;
                if (self.editor.loaded_map_name) |basename| {
                    self.editor.saveAndNotify(basename, self.editor.loaded_map_path orelse "", switch (self.post) {
                        .quit => .quit,
                        .close_map => .unload_map,
                    }) catch return;
                    self.doPostAction() catch return;
                } else {
                    async_util.SdlFileData.spawn(self.editor.alloc, &self.editor.async_asset_load, switch (self.post) {
                        .quit => .save_map_quit,
                        .close_map => .save_map_close,
                    }) catch return;
                }
            },
        }
    }

    fn doPostAction(self: *@This()) !void {
        switch (self.post) {
            .quit => {
                self.editor.gapp.main_window.should_exit = true;
                self.editor.should_exit = true;
            },
            .close_map => {
                try @import("../actions.zig").unloadMap(self.editor);
            },
        }
    }
};

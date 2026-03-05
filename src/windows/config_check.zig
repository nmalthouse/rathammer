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
const action = @import("../actions.zig");
const CbHandle = guis.CbHandle;
const colors = @import("../colors.zig").colors;

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

        _ = Wg.Text.build(area, ly.getArea(), "steam path: {s}", .{self.ed.dirs.games_dir.path}, .{});
        _ = Wg.Button.build(area, ly.getArea(), "edit config", .{ .cb_vt = &self.cbhandle, .cb_fn = btnCb });

        var numgood: usize = 0;
        for (self.ed.games.list.values()) |val| {
            _ = Wg.Text.build(area, ly.getArea(), "{s}", .{val.name}, .{ .col = if (val.good) colors.good else colors.bad });
            if (val.good) numgood += 1;
        }
        _ = Wg.Text.build(area, ly.getArea(), "{d} good games", .{numgood}, .{});
    }

    fn btnCb(cb: *CbHandle, _: guis.Uid, mcb: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        const pop = ConfigEdit.create(mcb.gui, mcb.gui.clamp_window, self.ed, self) catch return;
        mcb.gui.setTransientWindow(pop, null);
    }
};

pub const ConfigEdit = struct {
    const Btn = enum(guis.Uid) {
        cancel,
        pick_steam_dir,
        save,
        _,
    };
    vt: iWindow,

    ed: *Context,

    cbhandle: guis.CbHandle = .{},
    parent: *ConfigCheck,

    pub fn create(gui: *Gui, area: Rect, ed: *Context, parent: *ConfigCheck) !*iWindow {
        const self = gui.create(@This());

        self.* = .{
            .ed = ed,
            .vt = iWindow.init(build, gui, deinit, .{ .area = area }, &self.vt),
            .parent = parent,
        };

        build(&self.vt, gui, self.vt.area.area);
        return &self.vt;
    }

    pub fn build(vt: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        vt.area.area = area;
        vt.area.clearChildren(gui, vt);
        const MW = gui.dstate.minWidgetWidth("big dog cancel this save that");
        const column = Rec(area.x, area.y, @min(MW, area.w), area.h);
        var ly = gui.dstate.vlayout(column);
        {
            var hl = gui.dstate.hlayout(ly.getArea() orelse return, 2);
            _ = Wg.Button.build(&vt.area, hl.getArea(), "Cancel", .{
                .id = @intFromEnum(Btn.cancel),
                .cb_vt = &self.cbhandle,
                .cb_fn = btnCb,
            });

            _ = Wg.Button.build(&vt.area, hl.getArea(), "Save", .{
                .id = @intFromEnum(Btn.save),
                .cb_vt = &self.cbhandle,
                .cb_fn = btnCb,
            });
        }
        _ = ly.getArea();

        _ = Wg.Button.build(&vt.area, ly.getArea(), "pick steam dir", .{
            .id = @intFromEnum(Btn.pick_steam_dir),
            .cb_vt = &self.cbhandle,
            .cb_fn = btnCb,
        });

        ly.bounds.w = area.w;

        _ = Wg.Text.build(&vt.area, ly.getArea(), "The rest of the config edit hasen't been added yet :(", .{}, .{});
        _ = Wg.Text.build(&vt.area, ly.getArea(), "You will have to manually edit the json file for now", .{}, .{});
        _ = Wg.Text.build(&vt.area, ly.getArea(), "{s}/config.json", .{
            self.ed.dirs.config.path,
        }, .{});
    }

    fn btnCb(cb: *CbHandle, id: guis.Uid, mcb: guis.MouseCbState, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));

        switch (@as(Btn, @enumFromInt(id))) {
            else => {},
            .cancel => {
                mcb.gui.deferTransientClose(win);
            },
            .pick_steam_dir => {
                async_util.SdlFileData.spawn(self.ed.alloc, &self.ed.async_asset_load, .pick_steam_dir) catch {};
            },
            .save => {
                mcb.gui.deferTransientClose(win);

                action.writeConfig(self.ed) catch {};
            },
        }
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.parent.vt.needs_rebuild = true;
        vt.deinit(gui);

        gui.alloc.destroy(self); //second
    }

    pub fn draw(vt: *iArea, _: *guis.Gui, d: *guis.DrawState) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", vt));
        _ = self;
        _ = d;
    }
};

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
    pub var __cbhandle = guis.cbReg("cbhandle");
    cbhandle: CbHandle = .init(@This()),
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
            if (val.good) numgood += 1;
        }
        _ = Wg.Text.build(area, ly.getArea(), "{d}/{d} games good", .{ numgood, self.ed.games.list.values().len }, .{});

        for (self.ed.games.list.values()) |val| {
            _ = Wg.Text.build(area, ly.getArea(), "{s}", .{val.name}, .{ .col = if (val.good) colors.good else colors.bad });
        }
    }

    fn btnCb(cb: *CbHandle, _: guis.Uid, mcb: guis.MouseCbState, _: *iWindow) void {
        const self = cb.cast(ConfigCheck);
        const pop = ConfigEdit.create(mcb.gui, mcb.gui.clamp_window, self.ed, self) catch return;
        mcb.gui.setTransientWindow(pop, null);
    }
};

pub const ConfigEdit = struct {
    pub var __cbhandle = guis.cbReg("cbhandle");
    const Btn = enum(guis.Uid) {
        cancel,
        pick_steam_dir,
        save,
        _,
    };
    vt: iWindow,

    ed: *Context,
    tab_index: usize = 0,

    cbhandle: guis.CbHandle = .init(@This()),
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

        ly.pushRemaining();
        _ = Wg.Tabs.build(&vt.area, ly.getArea(), &.{ "nothing", "keys", "other" }, vt, .{ .build_cb = &buildTabs, .cb_vt = &self.cbhandle, .index_ptr = &self.tab_index });
    }

    fn buildTabs(cb: *CbHandle, vt: *iArea, tab_name: []const u8, _: usize, gui: *Gui, win: *iWindow) void {
        const self = cb.cast(@This());
        const eql = std.mem.eql;
        if (eql(u8, tab_name, "keys")) {
            _ = Wg.FloatScroll.build(vt, vt.area, .{
                .build_cb = buildKeyList,
                .build_vt = &self.cbhandle,
                .win = win,
                .scroll_mul = gui.dstate.nstyle.item_h * 4,
                .scroll_y = true,
                .scroll_x = false,
            });
            return;
        }
    }

    fn buildKeyList(cb: *CbHandle, lay: *iArea, gui: *Gui, win: *iWindow, scr: *Wg.FloatScroll) void {
        const self = cb.cast(@This());
        var ly = gui.dstate.vlayout(lay.area);
        ly.padding.left = 10;
        ly.padding.right = 10;
        ly.padding.top = 0;
        defer scr.hintBounds(ly.getUsed());

        const info = @typeInfo(Config.Keys).@"struct";
        _ = win;

        inline for (info.fields) |field| {
            _ = Wg.Text.buildStatic(lay, ly.getArea(), field.name, .{});
            ly.padding.left += 20;
            defer ly.padding.left -= 20;
            const in = @typeInfo(field.type).@"struct";
            inline for (in.fields) |fi| {
                const k = @field(@field(self.ed.config.keys, field.name), fi.name);
                var buf: [32]u8 = undefined;
                _ = Wg.Button.build(lay, ly.getArea(), gui.printScratch("{s}: {s}", .{
                    fi.name,
                    k.nameFull(&buf),
                }), .{});
            }
        }
    }

    fn btnCb(cb: *CbHandle, id: guis.Uid, mcb: guis.MouseCbState, win: *iWindow) void {
        const self = cb.cast(@This());

        switch (@as(Btn, @enumFromInt(id))) {
            else => {},
            .cancel => {
                mcb.gui.deferTransientClose(win);
                self.ed.conf.config = self.ed.config; //Restore to previous state
            },
            .pick_steam_dir => {
                async_util.SdlFileData.spawn(self.ed.alloc, &self.ed.async_asset_load, .pick_steam_dir) catch {};
            },
            .save => {
                mcb.gui.deferTransientClose(win);

                action.writeConfig(self.ed) catch {};
                if (!std.mem.eql(u8, self.ed.config.paths.steam_dir, self.ed.conf.config.paths.steam_dir)) {
                    action.setGameDir(self.ed, self.ed.conf.config.paths.steam_dir) catch {};
                }
                self.ed.config = self.ed.conf.config;
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

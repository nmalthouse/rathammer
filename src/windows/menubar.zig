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
const async_util = @import("../async.zig");
const label = guis.label;
const action = @import("../actions.zig");
const version = @import("../version.zig");
const colors = @import("../colors.zig").colors;
const app = @import("../app.zig");

const MenuBtn = enum(guis.Uid) {
    save,
    saveas,
    save_selection,
    import_map,
    build_map,
    build_map_user,
    quit,
    undo,
    redo,
    open_help_url,
    open_project_url,
    draw_sprite,
    draw_mod,
    draw_debug,
    todo,
    _,
};
pub fn btn_id(id: MenuBtn) guis.Uid {
    return @intFromEnum(id);
}
const btn_strid = Wg.BtnContextWindow.buttonId;

const BtnMap = Wg.BtnContextWindow.ButtonMapping;
const TodoBtns = [_]BtnMap{
    .{ btn_id(.todo), "TODO. This menu is a placeholder!", .btn },
};

const menus = [_][]const u8{
    "file", "edit", "view", "options", "help",
};

pub const MenuBar = struct {
    vt: iWindow,
    cbhandle: guis.CbHandle = .{},
    ev_vt: app.iEvent = .{ .cb = event_cb },

    ed: *Context,

    pub fn create(gui: *Gui, editor: *Context) !*iWindow {
        const self = gui.create(@This());
        self.* = .{
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, .{
                .bg = .{ .color = gui.dstate.nstyle.color.bg },
            }, &self.vt),
            .ed = editor,
        };

        if (editor.eventctx.registerListener(&self.ev_vt)) |listener| {
            editor.eventctx.subscribe(listener, @intFromEnum(app.EventKind.menubar_dirty)) catch {};
        } else |_| {}

        return &self.vt;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        vt.deinit(gui);
        gui.alloc.destroy(self);
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, _: *Gui, d: *DrawState) void {
        d.ctx.rect(vt.area, d.nstyle.color.bg);
    }

    pub fn build(win: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", win));
        win.area.area = area;
        win.area.clearChildren(gui, win);
        win.area.dirty();

        var ar = win.area.area;
        if (win.area.children.items.len != 0) @panic("fucked up"); // code assumes
        const pad = gui.dstate.minWidgetWidth("  ");
        for (menus, 0..) |menu, i| {
            const b = gui.dstate.minWidgetWidth(menu);

            _ = Wg.Button.build(&win.area, ar.replace(null, null, b + pad, null), menu, .{
                .cb_vt = &self.cbhandle,
                .cb_fn = btnCb,
                .id = @intCast(i),
            });
            ar.x += b + pad;
        }

        {
            const name = "ignore groups";
            const b = Wg.Checkbox.getWidth(gui, name, .{});

            _ = Wg.Checkbox.build(&win.area, ar.replace(null, null, b + pad, null), name, .{
                .bool_ptr = &self.ed.selection.ignore_groups,
            }, null);
            ar.x += b + pad;

            _ = Wg.Combo.build(&win.area, ar.replace(null, null, b + pad, null), &self.ed.renderer.mode, .{});
            ar.x += b + pad;

            const ww = gui.dstate.minWidgetWidth(version.version_short);
            _ = Wg.Text.build(&win.area, ar.replace(null, null, ww + pad, null), "{s}", .{version.version_short});
            ar.x += ww + pad;
        }
    }

    pub fn event_cb(ev_vt: *app.iEvent, ev: app.Event) void {
        const self: *@This() = @alignCast(@fieldParentPtr("ev_vt", ev_vt));

        switch (ev) {
            .menubar_dirty => {
                self.vt.needs_rebuild = true;
            },
            else => {},
        }
    }

    fn btnCb(cb: *guis.CbHandle, uid: guis.Uid, dat: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        const child = self.vt.area.children.items[uid];
        const r_win = Wg.BtnContextWindow.create(
            dat.gui,
            child.area.pos().add(.{ .x = 0, .y = self.vt.area.area.h }),
            .{
                .buttons = self.getMenu(menus[uid]) catch return,
                .btn_cb = rightClickMenuBtn,
                .checkbox_cb = checkbox_cb,
                .btn_vt = &self.cbhandle,
            },
        ) catch return;
        dat.gui.setTransientWindow(r_win);
    }

    fn rightClickMenuBtn(cb: *guis.CbHandle, id: guis.Uid, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        switch (@as(MenuBtn, @enumFromInt(id))) {
            .save => action.trySave(self.ed) catch {},
            .saveas => async_util.SdlFileData.spawn(self.ed.alloc, &self.ed.async_asset_load, .save_map) catch return,
            .quit => self.ed.win.should_exit = true,
            .undo => action.undo(self.ed),
            .redo => action.redo(self.ed),
            .open_help_url => {
                _ = graph.c.SDL_OpenURL(version.help_url);
            },
            .open_project_url => {
                _ = graph.c.SDL_OpenURL(version.project_url);
            },
            .build_map => action.buildMap(self.ed, false) catch {},
            .build_map_user => action.buildMap(self.ed, true) catch {},

            else => self.ed.notify("TODO. item not implemented", .{}, colors.bad) catch {},
        }
    }

    pub fn checkbox_cb(cb: *guis.CbHandle, _: *Gui, val: bool, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        switch (id) {
            btn_id(.draw_sprite) => self.ed.draw_state.tog.sprite = val,
            btn_id(.draw_mod) => self.ed.draw_state.tog.models = val,
            btn_id(.draw_debug) => self.ed.draw_state.tog.debug_stats = val,
            else => {},
        }
    }

    fn getMenu(self: *MenuBar, menu: []const u8) !Wg.BtnContextWindow.ButtonList {
        const aa = self.ed.frame_arena.allocator();
        switch (Wg.BtnContextWindow.buttonIdRuntime(menu)) {
            btn_strid("view") => {
                const tog = self.ed.draw_state.tog;
                return try aa.dupe(BtnMap, &[_]BtnMap{
                    .{ btn_id(.draw_sprite), "Draw Sprites", .{ .checkbox = tog.sprite } },
                    .{ btn_id(.draw_mod), "Draw Models", .{ .checkbox = tog.models } },
                    .{ btn_id(.draw_debug), "Draw debug stats", .{ .checkbox = tog.debug_stats } },
                });
            },
            btn_strid("file") => {
                return try aa.dupe(BtnMap, &[_]BtnMap{
                    .{ btn_id(.save), "save", .btn },
                    .{ btn_id(.saveas), "save-as", .btn },
                    //.{ btn_id(.save_selection), "save-selection-as", .btn },
                    //.{ btn_id(.import_map), "import-map", .btn },
                    .{ btn_id(.build_map), "build", .btn },
                    .{ btn_id(.build_map_user), "build-user", .btn },
                    .{ btn_id(.quit), "quit", .btn },
                });
            },
            btn_strid("edit") => {
                return try aa.dupe(BtnMap, &[_]BtnMap{
                    .{ btn_id(.undo), "undo", .btn },
                    .{ btn_id(.redo), "redo", .btn },
                });
            },
            btn_strid("help") => {
                return try aa.dupe(BtnMap, &[_]BtnMap{
                    .{ btn_id(.open_project_url), "Open Github", .btn },
                    .{ btn_id(.open_help_url), "Open Help", .btn },
                });
            },
            else => return &TodoBtns,
        }
    }
};

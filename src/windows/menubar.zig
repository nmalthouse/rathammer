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

const buttons = [_][]const u8{
    "File",
    "Edit",
    "View",
    "Options",
    "Tools",
    "Help",
};

const btn_id = Wg.BtnContextWindow.buttonId;
const BtnMap = Wg.BtnContextWindow.ButtonMapping;
const FileBtns = [_]BtnMap{
    .{ btn_id("copy"), "All of this is placeholder!" },
    .{ btn_id("copy"), "It does not work yet." },
    .{ btn_id("copy"), "new" },
    .{ btn_id("copy"), "save" },
    .{ btn_id("copy"), "save as" },
    .{ btn_id("copy"), "other stuff" },
    .{ btn_id("paste"), "Quit" },
};

pub const MenuBar = struct {
    vt: iWindow,
    cbhandle: guis.CbHandle = .{},
    area: iArea,

    editor: *Context,

    pub fn create(gui: *Gui, editor: *Context) !*iWindow {
        const self = gui.create(@This());
        self.* = .{
            .area = .{ .area = .{}, .draw_fn = draw, .deinit_fn = area_deinit },
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, &self.area),
            .editor = editor,
        };

        return &self.vt;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        vt.deinit(gui);
        gui.alloc.destroy(self);
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, d: DrawState) void {
        d.ctx.rect(vt.area, d.nstyle.color.bg);
    }

    pub fn build(win: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", win));
        self.area.area = area;
        self.area.clearChildren(gui, win);
        self.area.dirty(gui);

        var ar = self.area.area;
        if (self.area.children.items.len != 0) @panic("fucked up"); // code assumes
        const p = gui.font.textBounds("  ", gui.style.config.text_h);
        for (buttons, 0..) |btn, i| {
            const b = gui.font.textBounds(btn, gui.style.config.text_h);
            const pad = p.x;

            self.area.addChildOpt(gui, win, Wg.Button.build(gui, ar.replace(null, null, b.x + pad, null), btn, .{
                .cb_vt = &self.cbhandle,
                .cb_fn = btnCb,
                .id = @intCast(i),
            }));
            ar.x += b.x + pad;
        }
    }

    fn btnCb(cb: *guis.CbHandle, uid: guis.Uid, dat: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        const child = self.area.children.items[uid];
        const r_win = Wg.BtnContextWindow.create(
            dat.gui,
            child.area.pos().add(.{ .x = 0, .y = self.area.area.h }),
            .{
                .buttons = &FileBtns,
                .btn_cb = rightClickMenuBtn,
                .btn_vt = &self.cbhandle,
            },
        ) catch return;
        dat.gui.setTransientWindow(r_win);
    }

    fn rightClickMenuBtn(cb: *guis.CbHandle, id: guis.Uid, _: guis.MouseCbState, _: *iWindow) void {
        _ = cb;
        _ = id;
    }
};

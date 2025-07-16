const graph = @import("graph");
const g = graph.RGui;
const Gui = g.Gui;
const iArea = g.iArea;
const std = @import("std");
const Rect = g.Rect;
const Rec = g.Rec;
const iWindow = g.iWindow;
const Color = graph.Colori;
const VScroll = g.Widget.VScroll;
const Widget = g.Widget;
const vpk = @import("../vpk.zig");
const edit = @import("../editor.zig");

pub const PollingTexture = struct {
    pub const Opts = struct {
        tint: u32 = 0xffff_ffff,

        cb_vt: ?*iArea = null,
        cb_fn: ?Widget.Button.ButtonCallbackT = null,
        id: usize = 0,
    };
    vt: iArea,

    ed: *edit.Context,
    vpk_id: vpk.VpkResId,
    opts: Opts,
    text: []const u8,

    pub fn build(gui: *Gui, area_o: ?Rect, ed: *edit.Context, vpk_id: vpk.VpkResId, comptime fmt: []const u8, args: anytype, opts: Opts) ?*iArea {
        const area = area_o orelse return null;
        const self = gui.create(@This());
        var str = std.ArrayList(u8).init(gui.alloc);
        str.writer().print(fmt, args) catch return null;

        self.* = .{
            .vt = iArea.init(gui, area),
            .text = str.toOwnedSlice() catch return null,
            .vpk_id = vpk_id,
            .opts = opts,
            .ed = ed,
        };
        self.vt.draw_fn = &draw;
        self.vt.deinit_fn = &deinit;
        self.vt.onclick = &onclick;
        const missing = edit.missingTexture();
        const tex = self.ed.getTexture(self.vpk_id) catch return &self.vt;
        if (tex.id == missing.id) {
            self.vt.onpoll = &pollForTexture;
        }

        return &self.vt;
    }

    pub fn pollForTexture(vt: *iArea, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const missing = edit.missingTexture();
        const tex = self.ed.getTexture(self.vpk_id) catch return;
        if (tex.id != missing.id) {
            win.unregisterPoll(vt);
            vt.dirty(gui);
        }
    }

    pub fn deinit(vt: *iArea, gui: *Gui, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        gui.alloc.free(self.text);
        gui.alloc.destroy(self);
    }

    pub fn draw(vt: *iArea, d: g.DrawState) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const tex = self.ed.getTexture(self.vpk_id) catch return;
        const r = vt.area;
        d.ctx.rectTexTint(r, tex.rect(), self.opts.tint, tex);
        if (self.text.len > 0) {
            const h = @min(d.gui.style.config.default_item_h, r.h);
            const tr = graph.Rec(r.x, r.y + r.h - h, r.w, h);
            d.ctx.rect(tr, 0xff);
            d.ctx.textClipped(tr, "{s}", .{self.text}, d.textP(0xffff_ffff), .left);
        }
    }

    pub fn onclick(vt: *iArea, cb: g.MouseCbState, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));

        vt.dirty(cb.gui);
        if (self.opts.cb_fn) |cbfn|
            cbfn(self.opts.cb_vt orelse return, self.opts.id, cb.gui, win);
    }
};

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
const CbHandle = guis.CbHandle;
pub const LaunchWindow = struct {
    const Buttons = enum {
        quit,
        new_map,
        pick_map,

        pub fn id(self: @This()) usize {
            return @intFromEnum(self);
        }
    };

    pub const Recent = struct {
        name: []const u8,
        tex: ?graph.Texture,
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
    cbhandle: CbHandle = .{},

    editor: *Context,
    should_exit: bool = false,

    recents: std.ArrayList(Recent),

    pub fn create(gui: *Gui, editor: *Context) !*LaunchWindow {
        const self = gui.create(@This());
        self.* = .{
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, .{}, &self.vt),
            .editor = editor,
            .recents = std.ArrayList(Recent).init(editor.alloc),
        };

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        for (self.recents.items) |*rec| {
            self.recents.allocator.free(rec.name);
            if (rec.tex) |*t|
                t.deinit();
        }
        self.recents.deinit();
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
        _ = Wg.Text.buildStatic(ar, ly.getArea(), "Welcome ", null);
        _ = Btn(ar, ly.getArea(), "New", .{ .cb_fn = &btnCb, .id = Buttons.id(.new_map), .cb_vt = &self.cbhandle });
        _ = Btn(ar, ly.getArea(), "Load", .{ .cb_fn = &btnCb, .id = Buttons.id(.pick_map), .cb_vt = &self.cbhandle });

        ly.pushRemaining();
        const SZ = 5;
        _ = Wg.VScroll.build(ar, ly.getArea(), .{
            .count = self.recents.items.len,
            .item_h = gui.dstate.style.config.default_item_h * SZ,
            .build_cb = buildScroll,
            .build_vt = &self.cbhandle,
            .win = win,
        });
    }

    pub fn buildScroll(cb: *CbHandle, area: *iArea, index: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        const gui = area.win_ptr.gui_ptr;
        var scrly = guis.VerticalLayout{ .padding = .{}, .item_height = gui.dstate.style.config.default_item_h * 5, .bounds = area.area };
        if (index >= self.recents.items.len) return;
        const text_bound = gui.dstate.font.textBounds("_Load_", gui.dstate.style.config.text_h);
        for (self.recents.items[index..], 0..) |rec, i| {
            const ar = scrly.getArea() orelse return;
            const sp = ar.split(.vertical, ar.h);

            var ly = gui.dstate.vLayout(sp[1]);
            _ = Wg.Text.buildStatic(area, ly.getArea(), rec.name, null);
            if (rec.tex) |tex|
                _ = Wg.GLTexture.build(area, sp[0], tex, tex.rect(), .{});
            const ld_btn = ly.getArea() orelse return;
            const ld_ar = ld_btn.replace(null, null, @min(text_bound.x, ld_btn.w), null);

            _ = Wg.Button.build(area, ld_ar, "Load", .{ .cb_fn = &loadBtn, .id = i + index, .cb_vt = &self.cbhandle });
        }
    }

    pub fn loadBtn(cb: *CbHandle, id: usize, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        if (id >= self.recents.items.len) return;

        const mname = self.recents.items[id].name;
        const name = self.editor.printScratch("{s}.ratmap", .{mname}) catch return;
        self.editor.loadMap(self.editor.dirs.app_cwd.dir, name, self.editor.loadctx) catch |err| {
            std.debug.print("Can't load map {s} with {!}\n", .{ name, err });
            return;
        };
        self.editor.paused = false;
    }

    pub fn btnCb(cb: *CbHandle, id: usize, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        switch (@as(Buttons, @enumFromInt(id))) {
            .quit => self.should_exit = true,
            .new_map => {
                self.vt.needs_rebuild = true;
                const ed = self.editor;
                ed.initNewMap("sky_day01_01") catch {
                    std.debug.print("ERROR INIT NEW MAP\n", .{});
                };
                self.editor.paused = false;
            },
            .pick_map => {
                self.vt.needs_rebuild = true;
                async_util.SdlFileData.spawn(self.editor.alloc, &self.editor.async_asset_load, .pick_map) catch return;
            },
        }
    }
};

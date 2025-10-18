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
const CbHandle = guis.CbHandle;
const vpk = @import("../vpk.zig");
const ArrayList = std.ArrayListUnmanaged;
const ptext = @import("widget_texture.zig");
const VpkId = vpk.VpkResId;
const inspector = @import("inspector.zig");

const log = std.log.scoped(.asset);

pub const AssetBrowser = struct {
    pub const tabs = [_][]const u8{ "texture", "vpk", "fgd", "undo" };
    const Self = @This();

    vt: iWindow,
    cbhandle: guis.CbHandle = .{},
    area: iArea,

    tex_browse: TextureBrowser,
    vpk_browse: VpkBrowser,
    alloc: std.mem.Allocator,

    tab_index: usize = 0,

    ed: *Context,

    pub fn create(gui: *Gui, editor: *Context) !*AssetBrowser {
        const self = gui.create(@This());
        self.* = .{
            .area = .{ .area = Rec(0, 0, 0, 0), .draw_fn = draw, .deinit_fn = area_deinit },
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, &self.area),
            .ed = editor,
            .alloc = gui.alloc,
            .tex_browse = .{ .alloc = gui.alloc, .ed = editor, .win = &self.vt },
            .vpk_browse = .{ .list = .{
                .alloc = gui.alloc,
                .search_vt = &self.vpk_browse.lscb,
                .win = &self.vt,
            }, .ed = editor, .win = &self.vt },
        };

        return self;
    }

    pub fn populate(
        self: *Self,
        vpkctx: *vpk.Context,
        exclude_prefix: []const u8,
        material_exclude_list: []const []const u8,
        mod_browse: *ModelBrowser,
    ) !void {
        vpkctx.mutex.lock();
        defer vpkctx.mutex.unlock();
        const vmt = try vpkctx.extension_map.getPut("vmt");
        const mdl = try vpkctx.extension_map.getPut("mdl");
        const png = try vpkctx.extension_map.getPut("png");
        var it = vpkctx.entries.iterator();
        var excluded: usize = 0;
        outer: while (it.next()) |item| {
            const id = item.key_ptr.* >> 48;
            if (id == vmt) {
                if (std.mem.startsWith(u8, item.value_ptr.path, exclude_prefix)) {
                    const substr = item.value_ptr.path[exclude_prefix.len..];
                    if (substr.len > 0) {
                        for (material_exclude_list) |ex| {
                            if (std.mem.startsWith(u8, substr, ex)) {
                                excluded += 1;
                                continue :outer;
                            }
                        }
                    }
                }
                try self.tex_browse.mat_list.append(self.alloc, item.key_ptr.*);
            } else if (id == mdl) {
                try mod_browse.list.appendMaster(&.{item.key_ptr.*});
            } else if (id == png) {
                try self.tex_browse.mat_list.append(self.alloc, item.key_ptr.*);
            }
        }
        self.vpk_browse.list.appendMaster(self.ed.vpkctx.entries.keys()) catch {};
        log.info("excluded {d} materials", .{excluded});
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.tex_browse.deinit();
        self.vpk_browse.deinit();
        vt.deinit(gui);
        gui.alloc.destroy(self); //second
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, _: *Gui, d: *DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
    }

    pub fn build(win: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", win));
        self.area.area = area;
        self.area.clearChildren(gui, win);
        self.area.dirty(gui);
        self.tex_browse.reset();
        self.vpk_browse.reset();
        const inset = GuiHelp.insetAreaForWindowFrame(gui, win.area.area);
        const lay = &self.area;

        lay.addChildOpt(gui, win, Wg.Tabs.build(gui, inset, &tabs, win, .{ .build_cb = &buildTabs, .cb_vt = &self.area, .index_ptr = &self.tab_index }));
    }

    fn buildTabs(user_vt: *iArea, vt: *iArea, tab_name: []const u8, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", user_vt));
        const eql = std.mem.eql;
        if (eql(u8, tab_name, "texture")) {
            self.tex_browse.build(vt, win, gui, vt.area);
            return;
        }
        if (eql(u8, tab_name, "vpk")) {
            self.vpk_browse.build(vt, win, gui, vt.area);
            return;
        }
    }

    fn btnCb(cb: *CbHandle, id: usize, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        _ = id;
        self.ed.asset_browser.applyDialogState(self.ed) catch {};
    }
};

const VpkBrowser = struct {
    const Self = @This();
    ed: *Context,
    win: *iWindow,

    cbhandle: guis.CbHandle = .{},

    lscb: ListSearchCb = .{
        .search_cb = searchCb,
    },

    list: ListSearch,

    pub fn deinit(self: *@This()) void {
        self.list.deinit();
    }

    pub fn reset(self: *@This()) void {
        self.list.reset();
    }

    pub fn build(self: *@This(), lay: *iArea, win: *iWindow, gui: *Gui, area: Rect) void {
        const sp = area.split(.vertical, area.w / 2);
        var ly = gui.dstate.vLayout(sp[0]);
        if (ly.getArea()) |header| {
            const header_col = 4;
            var hy = guis.HorizLayout{ .bounds = header, .count = header_col };
            if (guis.label(lay, gui, win, hy.getArea(), "Search", .{})) |ar|
                self.list.addTextbox(lay, gui, win, ar);
            if (guis.label(lay, gui, win, hy.getArea(), "Results: ", .{})) |ar| {
                lay.addChildOpt(gui, win, Wg.NumberDisplay.build(gui, ar, &self.list.num_result));
            }
        }
        _ = ly.getArea(); //break

        ly.pushRemaining();
        if (Wg.VScroll.build(gui, ly.getArea(), .{
            .build_cb = buildVpkList,
            .build_vt = &self.cbhandle,
            .win = win,
            .count = self.list.count(),
            .item_h = gui.dstate.style.config.default_item_h,
        })) |scr| {
            lay.addChildOpt(gui, win, scr);
            self.list.scr_ptr = @alignCast(@fieldParentPtr("vt", scr.vt));
        }
    }

    fn buildVpkList(cb: *CbHandle, vt: *iArea, index: usize, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        const list = self.list.getSlice();
        if (index >= list.len) return;
        var ly = gui.dstate.vLayout(vt.area);
        for (list[index..]) |item| {
            const tt = self.ed.vpkctx.entries.get(item) orelse return;
            const dd = vpk.decodeResourceId(item);
            const ext = self.ed.vpkctx.extension_map.getName(@intCast(dd.ext)) orelse "";
            vt.addChildOpt(gui, win, Wg.Text.build(
                gui,
                ly.getArea(),
                "{s}/{s}.{s}",
                .{ tt.path, tt.name, ext },
            ));
        }
    }

    fn searchCb(lscb: *ListSearchCb, id: VpkId, search: []const u8) bool {
        const self: *@This() = @alignCast(@fieldParentPtr("lscb", lscb));
        const tt = self.ed.vpkctx.entries.get(id) orelse return false;
        const io = std.mem.indexOf;
        return (io(u8, tt.path, search) != null or io(u8, tt.name, search) != null);
    }
};

pub const ModelBrowser = struct {
    const Self = @This();

    vt: iWindow,
    area: iArea,

    cbhandle: guis.CbHandle = .{},
    selected_index: usize = 0,

    lscb: ListSearchCb = .{
        .search_cb = searchCb,
    },
    ed: *Context,

    list: ListSearch,
    scroll_index: usize = 0,

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.list.deinit();
        vt.deinit(gui);
        gui.alloc.destroy(self);
    }

    pub fn reset(self: *@This()) void {
        self.list.reset();
    }

    pub fn create(gui: *Gui, editor: *Context) !*ModelBrowser {
        const self = gui.create(@This());
        self.* = .{
            .area = .{ .area = Rec(0, 0, 0, 0), .draw_fn = draw, .deinit_fn = area_deinit },
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, &self.area),
            .ed = editor,
            .list = .{
                .search_vt = &self.lscb,
                .alloc = gui.alloc,
                .win = &self.vt,
            },
        };

        self.vt.update_fn = update;
        return self;
    }

    pub fn update(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));

        if (gui.sdl_win.isBindState(self.ed.config.keys.up_line.b, .rising) and self.selected_index > 0) {
            if (self.scroll_index > 0)
                self.scroll_index -= 1;
            self.setSelected(self.selected_index - 1);
            vt.needs_rebuild = true;
        }
        if (gui.sdl_win.isBindState(self.ed.config.keys.down_line.b, .rising) and self.selected_index + 1 < self.list.count()) {
            self.setSelected(self.selected_index + 1);
            self.scroll_index += 1;
            vt.needs_rebuild = true;
        }
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, _: *Gui, d: *DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
    }

    pub fn build(win: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", win));
        self.area.area = area;
        self.area.clearChildren(gui, win);
        self.area.dirty(gui);
        const lay = &self.area;
        const inset = GuiHelp.insetAreaForWindowFrame(gui, win.area.area);
        self.list.reset();

        var ly = gui.dstate.vLayout(inset);
        if (ly.getArea()) |header| {
            const header_col = 4;
            var hy = guis.HorizLayout{ .bounds = header, .count = header_col };
            if (guis.label(lay, gui, win, hy.getArea(), "Search", .{})) |ar|
                self.list.addTextbox(lay, gui, win, ar);
            if (guis.label(lay, gui, win, hy.getArea(), "Results: ", .{})) |ar| {
                lay.addChildOpt(gui, win, Wg.NumberDisplay.build(gui, ar, &self.list.num_result));
            }

            {
                var buf: [32]u8 = undefined;
                const spa = hy.getArea() orelse return;
                const sp = spa.split(.vertical, spa.w / 2);
                lay.addChildOpt(gui, win, Wg.Text.build(gui, sp[0], "up: {s}", .{
                    self.ed.config.keys.up_line.b.nameFull(&buf),
                }));
                lay.addChildOpt(gui, win, Wg.Text.build(gui, sp[1], "down: {s}", .{
                    self.ed.config.keys.down_line.b.nameFull(&buf),
                }));
            }
            lay.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "accept", .{ .cb_vt = &self.cbhandle, .cb_fn = btnAcceptCb, .id = 0 }));
        }
        _ = ly.getArea(); //break

        ly.pushRemaining();
        const main_area = ly.getArea() orelse return;

        if (Wg.VScroll.build(gui, main_area, .{
            .build_cb = buildModList,
            .build_vt = &self.cbhandle,
            .win = win,
            .count = self.list.count(),
            .item_h = gui.dstate.style.config.default_item_h,
            .index_ptr = &self.scroll_index,
            .current_index = self.selected_index,
        })) |scr| {
            lay.addChildOpt(gui, win, scr);
            self.list.scr_ptr = @alignCast(@fieldParentPtr("vt", scr.vt));
        }
    }

    fn buildModList(cb: *CbHandle, vt: *iArea, index: usize, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        const list = self.list.getSlice();
        if (index >= list.len) return;
        var ly = gui.dstate.vLayout(vt.area);
        for (list[index..], index..) |item, i| {
            const tt = self.ed.vpkctx.entries.get(item) orelse return;

            vt.addChildOpt(gui, win, Wg.Button.build(
                gui,
                ly.getArea(),
                self.ed.printScratch("{s}/{s}", .{ tt.path, tt.name }) catch "err",
                .{
                    .id = i,
                    .cb_vt = &self.cbhandle,
                    .cb_fn = btnCb,
                    .custom_draw = inspector.customButtonDraw,
                    .user_1 = if (self.selected_index == i) 1 else 0,
                },
            ));
        }
    }

    fn searchCb(lscb: *ListSearchCb, id: VpkId, search: []const u8) bool {
        const self: *@This() = @alignCast(@fieldParentPtr("lscb", lscb));
        const tt = self.ed.vpkctx.entries.get(id) orelse return false;
        const io = std.mem.indexOf;
        return (io(u8, tt.path, search) != null or io(u8, tt.name, search) != null);
    }

    fn btnCb(cb: *CbHandle, id: usize, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.setSelected(id);
    }

    fn setSelected(self: *@This(), id: usize) void {
        self.selected_index = id;
        if (id < self.list.list_a.items.len) {
            const vpkid = self.list.list_a.items[id];
            self.ed.edit_state.selected_model_vpk_id = vpkid;
        }
        self.vt.needs_rebuild = true;
    }

    fn btnAcceptCb(cb: *CbHandle, id: usize, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        _ = id;
        self.ed.asset_browser.applyDialogState(self.ed) catch {};
    }
};

pub const ModelPreview = struct {
    const Vec3 = graph.za.Vec3;
    vt: iWindow,
    area: iArea,

    drawctx: *graph.ImmediateDrawingContext,
    ed: *Context,
    model_cam: graph.Camera3D = .{ .pos = Vec3.new(0, -100, 0), .up = .z, .move_speed = 20 },

    pub fn create(ed: *Context, gui: *Gui, drawctx: *graph.ImmediateDrawingContext) !*iWindow {
        var self = try gui.alloc.create(@This());
        self.* = .{
            .area = .{ .area = graph.Rec(0, 0, 0, 0), .deinit_fn = area_deinit, .draw_fn = drawfn },
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, &self.area),
            .drawctx = drawctx,
            .ed = ed,
        };
        self.vt.update_fn = update;

        return &self.vt;
    }

    pub fn update(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const win = gui.sdl_win;
        const mdown = win.mouse.left == .high;
        const grabit = gui.canGrabMouseOverride(vt) and mdown;
        self.ed.stack_owns_input = grabit;
        defer self.ed.stack_owns_input = false;
        const selected_mod = self.ed.edit_state.selected_model_vpk_id orelse return;
        const sp = self.area.area;

        gui.setGrabOverride(vt, grabit, .{ .hide_pointer = grabit });
        self.model_cam.updateDebugMove(self.ed.getCam3DMove(grabit));

        const screen_area = self.area.area;
        const x: i32 = @intFromFloat(screen_area.x);
        const y: i32 = @intFromFloat(screen_area.y);
        const w: i32 = @intFromFloat(screen_area.w);
        const h: i32 = @intFromFloat(screen_area.h);

        graph.c.glViewport(x, y, w, h);
        graph.c.glScissor(x, y, w, h);
        graph.c.glEnable(graph.c.GL_SCISSOR_TEST);
        defer graph.c.glDisable(graph.c.GL_SCISSOR_TEST);

        if (self.ed.models.get(selected_mod)) |mod| {
            if (mod.mesh) |mm| {
                const view = self.model_cam.getMatrix(sp.w / sp.h, 1, 64 * 512);
                const mat = graph.za.Mat4.identity();
                mm.drawSimple(view, mat, self.ed.draw_state.basic_shader);
            }
        } else {
            if (self.ed.vpkctx.entries.get(selected_mod)) |tt| {
                const name = self.ed.printScratch("{s}/{s}.mdl", .{ tt.path, tt.name }) catch return;
                _ = self.ed.loadModel(name) catch return;
            }
        }
        self.drawctx.flush(null, self.model_cam) catch {};
    }

    pub fn build(vt: *iWindow, gui: *Gui, area: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = gui;
        self.area.area = area;
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn drawfn(_: *iArea, _: *Gui, _: *DrawState) void {}

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        vt.deinit(gui);
        gui.alloc.destroy(self);
    }
};

const TextureBrowser = struct {
    const MAX_COL = 16;
    const MIN_COL = 4;
    const DEF_COL = 12;
    const Self = @This();
    alloc: std.mem.Allocator,
    ed: *Context,
    win: *iWindow,

    cbhandle: guis.CbHandle = .{},

    mat_list: ArrayList(VpkId) = .{},
    mod_list: ArrayList(VpkId) = .{},

    mat_list_search_a: ArrayList(VpkId) = .{},
    mat_list_search_b: ArrayList(VpkId) = .{},

    mod_list_search: ArrayList(VpkId) = .{},

    num_column: usize = DEF_COL,
    num_result: usize = 0,

    prev_search: ArrayList(u8) = .{},

    scr_ptr: ?*Wg.VScroll = null,
    pub fn deinit(self: *@This()) void {
        self.mod_list.deinit(self.alloc);
        self.mat_list.deinit(self.alloc);
        self.mat_list_search_a.deinit(self.alloc);
        self.mat_list_search_b.deinit(self.alloc);
        self.prev_search.deinit(self.alloc);
    }

    pub fn reset(self: *@This()) void {
        self.scr_ptr = null;
    }

    pub fn build(self: *@This(), lay: *iArea, win: *iWindow, gui: *Gui, area: Rect) void {
        var ly = gui.dstate.vLayout(area);
        if (ly.getArea()) |header| {
            const header_col = 4;
            var hy = guis.HorizLayout{ .bounds = header, .count = header_col };
            if (guis.label(lay, gui, win, hy.getArea(), "Search", .{})) |ar| {
                if (Wg.Textbox.buildOpts(gui, ar, .{
                    .user_id = 0,
                    .commit_vt = &self.cbhandle,
                    .commit_cb = cb_commitTextbox,
                    .commit_when = .on_change,
                })) |tbvt| {
                    lay.addChildOpt(gui, win, tbvt);
                    gui.grabFocus(tbvt.vt, win);
                }
            }
            if (guis.label(lay, gui, win, hy.getArea(), "Results: ", .{})) |ar| {
                lay.addChildOpt(gui, win, Wg.NumberDisplay.build(gui, ar, &self.num_result));
            }
            if (guis.label(lay, gui, win, hy.getArea(), "Columns", .{})) |ar| {
                lay.addChildOpt(gui, win, Wg.StaticSlider.build(gui, ar, null, .{
                    .min = MIN_COL,
                    .max = MAX_COL,
                    .default = @floatFromInt(self.num_column),
                    .clamp_edits = true,
                    .commit_cb = slide_commit,
                    .commit_vt = &self.cbhandle,
                }));
            }
            lay.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "accept", .{ .cb_vt = &self.cbhandle, .cb_fn = btnCb, .id = 0 }));
        }
        _ = ly.getArea(); //break

        self.mat_list_search_a.clearRetainingCapacity();
        self.mat_list_search_a.appendSlice(self.alloc, self.mat_list.items) catch {};
        self.num_result = self.mat_list_search_a.items.len;

        ly.pushRemaining();
        if (ly.getArea()) |tview| {
            if (Wg.VScroll.build(gui, tview, .{
                .build_cb = buildTextureView,
                .build_vt = &self.cbhandle,
                .win = win,
                .count = self.getTextureRowCount(),
                .item_h = self.getTextureRowHeight(tview.w),
            })) |scr| {
                lay.addChildOpt(gui, win, scr);
                self.scr_ptr = @alignCast(@fieldParentPtr("vt", scr.vt));
            }
        }

        // Main view
        // info about matches
        // maybe toggles or something
        // search bar

    }

    fn slide_commit(cb: *CbHandle, _: *Gui, num: f32, _: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        if (num > MAX_COL or num < MIN_COL) return;
        self.num_column = @intFromFloat(num);

        self.win.needs_rebuild = true;
    }

    fn getTextureRowCount(self: *const Self) usize {
        return @divTrunc(self.mat_list_search_a.items.len, self.num_column) + 1;
    }

    fn getTextureRowHeight(self: *Self, view_width: f32) f32 {
        return view_width / @as(f32, @floatFromInt(self.num_column));
    }

    fn cb_commitTextbox(cb: *CbHandle, gui: *Gui, string: []const u8, _: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        if (std.mem.eql(u8, string, self.prev_search.items))
            return;
        defer {
            self.prev_search.clearRetainingCapacity();
            self.prev_search.appendSlice(self.alloc, string) catch {};
        }

        var search_list = self.mat_list.items;

        if (std.mem.startsWith(u8, string, self.prev_search.items)) {
            self.mat_list_search_b.clearRetainingCapacity();
            self.mat_list_search_b.appendSlice(self.alloc, self.mat_list_search_a.items) catch return;
            search_list = self.mat_list_search_b.items;
        }
        const io = std.mem.indexOf;
        self.mat_list_search_a.clearRetainingCapacity();
        for (search_list) |item| {
            const tt = self.ed.vpkctx.entries.get(item) orelse continue;
            if (io(u8, tt.path, string) != null or io(u8, tt.name, string) != null)
                self.mat_list_search_a.append(self.alloc, item) catch return;
        }
        self.num_result = self.mat_list_search_a.items.len;
        if (self.scr_ptr) |scr| {
            scr.updateCount(self.getTextureRowCount());
            scr.index_ptr.* = 0;
            scr.rebuild(gui, self.win);
        }
    }

    fn buildTextureView(cb: *CbHandle, vt: *iArea, index: usize, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        const adj_index = index * self.num_column;
        if (adj_index >= self.mat_list_search_a.items.len) return;
        var tly = guis.TableLayout{
            .columns = @intCast(self.num_column),
            .item_height = self.getTextureRowHeight(vt.area.w),
            .bounds = vt.area,
        };
        for (self.mat_list_search_a.items[adj_index..]) |mat| {
            const tt = self.ed.vpkctx.entries.get(mat) orelse return;
            const tint: u32 = if (mat == self.ed.edit_state.selected_texture_vpk_id) 0xff8888_ff else 0xffff_ffff;
            vt.addChildOpt(gui, win, ptext.PollingTexture.build(gui, tly.getArea(), self.ed, mat, "{s}/{s}", .{
                tt.path, tt.name,
            }, .{
                .cb_vt = cb,
                .cb_fn = cb_tex_btn,
                .id = mat,
                .tint = tint,
            }));
        }
    }

    fn cb_tex_btn(cb: *CbHandle, id: usize, dat: guis.MouseCbState, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.ed.edit_state.selected_texture_vpk_id = id;
        self.ed.asset_browser.recent_mats.put(id) catch {};
        if (self.scr_ptr) |scr| {
            scr.rebuild(dat.gui, win);
        }
    }

    fn btnCb(cb: *CbHandle, id: usize, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        _ = id;
        self.ed.asset_browser.applyDialogState(self.ed) catch {};
    }
};

const ListSearchCb = struct {
    search_cb: *const fn (*ListSearchCb, VpkId, []const u8) bool,
};
const ListSearch = struct {
    list_a: ArrayList(VpkId) = .{},
    list_b: ArrayList(VpkId) = .{},
    master: ArrayList(VpkId) = .{},
    prev_search: ArrayList(u8) = .{},
    alloc: std.mem.Allocator,

    list_a_built_with_hash: u64 = 0,

    num_result: usize = 0,

    cbhandle: CbHandle = .{},

    scr_ptr: ?*Wg.VScroll = null,
    win: *iWindow,

    search_vt: *ListSearchCb,
    selected_index: usize = 0,

    pub fn reset(self: *@This()) void {
        self.scr_ptr = null;

        if (self.list_a_built_with_hash != getHash(self.prev_search.items)) {
            self.list_a.clearRetainingCapacity();
            self.list_a.appendSlice(self.alloc, self.master.items) catch {};
        }
        self.num_result = self.list_a.items.len;
        return;
    }

    fn getHash(str: []const u8) u64 {
        const ha = std.hash.Wyhash.hash;
        return ha(0, str);
    }

    pub fn appendMaster(self: *@This(), slice: []const VpkId) !void {
        try self.master.appendSlice(self.alloc, slice);
    }

    pub fn count(self: *const @This()) usize {
        return self.list_a.items.len;
    }

    pub fn getSlice(self: *const @This()) []const VpkId {
        return self.list_a.items;
    }

    pub fn deinit(self: *@This()) void {
        self.list_a.deinit(self.alloc);
        self.list_b.deinit(self.alloc);
        self.master.deinit(self.alloc);
        self.prev_search.deinit(self.alloc);
    }

    pub fn addTextbox(self: *@This(), lay: *iArea, gui: *Gui, win: *iWindow, area: Rect) void {
        if (Wg.Textbox.buildOpts(gui, area, .{
            .user_id = 0,
            .commit_vt = &self.cbhandle,
            .commit_cb = ListSearch.cb_commitTextbox,
            .commit_when = .on_change,
            .init_string = self.prev_search.items,
        })) |tbvt| {
            lay.addChildOpt(gui, win, tbvt);
            gui.grabFocus(tbvt.vt, win);
        }
    }

    fn cb_commitTextbox(cb: *CbHandle, gui: *Gui, string: []const u8, _: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        if (std.mem.eql(u8, string, self.prev_search.items))
            return;
        defer {
            self.prev_search.clearRetainingCapacity();
            self.prev_search.appendSlice(self.alloc, string) catch {};
            self.list_a_built_with_hash = getHash(self.prev_search.items);
        }

        var search_list = self.master.items;

        if (std.mem.startsWith(u8, string, self.prev_search.items)) {
            self.list_b.clearRetainingCapacity();
            self.list_b.appendSlice(self.alloc, self.list_a.items) catch return;
            search_list = self.list_b.items;
        }
        self.list_a.clearRetainingCapacity();
        for (search_list) |item| {
            if (self.search_vt.search_cb(self.search_vt, item, string))
                self.list_a.append(self.alloc, item) catch return;
        }
        self.num_result = self.list_a.items.len;
        if (self.scr_ptr) |scr| {
            scr.updateCount(self.list_a.items.len);
            scr.index_ptr.* = 0;
            scr.rebuild(gui, self.win);
        }
    }

    fn btnCb(cb: *CbHandle, id: usize, _: *Gui, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.selected_index = id;
    }
};

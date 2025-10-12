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

const log = std.log.scoped(.asset);

pub const AssetBrowser = struct {
    const Self = @This();

    vt: iWindow,
    cbhandle: guis.CbHandle = .{},
    area: iArea,

    tex_browse: TextureBrowser,
    alloc: std.mem.Allocator,

    ed: *Context,

    pub fn create(gui: *Gui, editor: *Context) !*AssetBrowser {
        const self = gui.create(@This());
        self.* = .{
            .area = .{ .area = Rec(0, 0, 0, 0), .draw_fn = draw, .deinit_fn = area_deinit },
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, &self.area),
            .ed = editor,
            .alloc = gui.alloc,
            .tex_browse = .{ .alloc = gui.alloc, .ed = editor, .win = &self.vt },
        };

        return self;
    }

    pub fn populate(
        self: *Self,
        vpkctx: *vpk.Context,
        exclude_prefix: []const u8,
        material_exclude_list: []const []const u8,
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
                try self.tex_browse.mod_list.append(self.alloc, item.key_ptr.*);
            } else if (id == png) {
                try self.tex_browse.mat_list.append(self.alloc, item.key_ptr.*);
            }
        }
        log.info("excluded {d} materials", .{excluded});
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.tex_browse.deinit();
        vt.deinit(gui);
        gui.alloc.destroy(self); //second
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, d: DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
    }

    pub fn build(win: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", win));
        self.area.area = area;
        self.area.clearChildren(gui, win);
        self.area.dirty(gui);
        self.tex_browse.reset();
        const inset = GuiHelp.insetAreaForWindowFrame(gui, win.area.area);
        const lay = &self.area;

        self.tex_browse.build(lay, win, gui, inset);
    }
};

const VpkBrowser = struct {
    const Self = @This();
    alloc: std.mem.Allocator,
    ed: *Context,
    win: *iWindow,

    cbhandle: guis.CbHandle = .{},

    list_search_a: ArrayList(VpkId) = .{},
    list_search_b: ArrayList(VpkId) = .{},

    prev_search: ArrayList(u8) = .{},
    scr_ptr: ?*Wg.VScroll = null,

    pub fn deinit(self: *@This()) void {
        self.list_search_a.deinit(self.alloc);
        self.list_search_b.deinit(self.alloc);
        self.prev_search.deinit(self.alloc);
    }

    pub fn reset(self: *@This()) void {
        self.scr_ptr = null;
    }

    pub fn build(self: *@This(), lay: *iArea, win: *iWindow, gui: *Gui, area: Rect) void {
        const sp = area.split(.vertical, area.w / 2);
        var ly = guis.VerticalLayout{ .padding = .{}, .item_height = gui.style.config.default_item_h, .bounds = sp[0] };
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
        }
        _ = ly.getArea(); //break

        self.list_search_a.clearRetainingCapacity();
        self.list_search_a.appendSlice(self.alloc, self.mat_list.items) catch {};

        ly.pushRemaining();
        if (ly.getArea()) |tview| {
            if (Wg.VScroll.build(gui, tview, .{
                .build_cb = buildVpkList,
                .build_vt = &self.cbhandle,
                .win = win,
                .count = self.list_search_a.items.len,
                .item_h = gui.style.config.default_item_h,
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
        if (self.scr_ptr) |scr| {
            scr.updateCount(self.getTextureRowCount());
            scr.index_ptr.* = 0;
            scr.rebuild(gui, self.win);
        }
    }

    fn buildVpkList(cb: *CbHandle, vt: *iArea, index: usize, gui: *Gui, win: *iWindow) void {
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
            const tint: u32 = if (mat == self.ed.asset_browser.selected_mat_vpk_id) 0xff8888_ff else 0xffff_ffff;
            vt.addChildOpt(gui, win, ptext.PollingTexture.build(gui, tly.getArea(), self.ed, mat, "{s}/{s}", .{
                tt.path, tt.name,
            }, .{
                .cb_vt = cb,
                .cb_fn = void,
                .id = mat,
                .tint = tint,
            }));
        }
    }
};

const TextureBrowser = struct {
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

    num_column: usize = 12,

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
        var ly = guis.VerticalLayout{ .padding = .{}, .item_height = gui.style.config.default_item_h, .bounds = area };
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
        }
        _ = ly.getArea(); //break

        self.mat_list_search_a.clearRetainingCapacity();
        self.mat_list_search_a.appendSlice(self.alloc, self.mat_list.items) catch {};

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
            const tint: u32 = if (mat == self.ed.asset_browser.selected_mat_vpk_id) 0xff8888_ff else 0xffff_ffff;
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

    fn cb_tex_btn(cb: *CbHandle, id: usize, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.ed.asset_browser.selected_mat_vpk_id = id;
        self.ed.asset_browser.recent_mats.put(id) catch {};
        if (self.scr_ptr) |scr| {
            scr.rebuild(gui, win);
        }
    }
};

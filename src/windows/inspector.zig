const std = @import("std");
const graph = @import("graph");
const Gui = guis.Gui;
const ecs = @import("../ecs.zig");
const Rec = graph.Rec;
const Rect = graph.Rect;
const DrawState = guis.DrawState;
const GuiHelp = guis.GuiHelp;
const guis = graph.RGui;
const iWindow = guis.iWindow;
const iArea = guis.iArea;
const undo = @import("../undo.zig");
const Wg = guis.Widget;
const edit = @import("../editor.zig");
const Context = edit.Context;
const ptext = @import("widget_texture.zig");
const fgd = @import("../fgd.zig");
const Layer = @import("../layer.zig");
//TODO
// to get this to work we need to first add a getptr cb to all existing
// widgets and use that to obtain our values.
// second, we need an 'onUpdate' that lets us check if we need to rebuild by comparing
// old selection to new for example.
// or, we have the editor.selection emit an event.
pub const InspectorWindow = struct {
    pub const tabs = [_][]const u8{ "props", "io", "tool", "layer" };
    const Self = @This();
    const MiscBtn = enum {
        ungroup,
    };

    vt: iWindow,
    area: iArea,

    editor: *Context,
    selected_kv_index: usize = 0,
    kv_scroll_index: usize = 0,

    id_kv_map: std.StringHashMap(usize),
    kv_id_map: std.AutoHashMap(usize, []const u8),
    kv_id_index: usize = 0,

    selected_class_id: ?usize = null,

    tab_index: usize = 0,

    str: []const u8 = "ass",

    io_columns_width: [5]f32 = .{ 0.2, 0.4, 0.6, 0.8, 0.9 },
    selected_io_index: usize = 0,
    io_scroll_index: usize = 0,

    layer_widget: Layer.GuiWidget,

    pub fn create(gui: *Gui, editor: *Context) *InspectorWindow {
        const self = gui.create(@This());
        self.* = .{
            .area = iArea.init(gui, Rec(0, 0, 0, 0)),
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, &self.area),
            .editor = editor,
            .layer_widget = Layer.GuiWidget.init(&editor.layers, &editor.edit_state.selected_layer, editor),
            .kv_id_map = std.AutoHashMap(usize, []const u8).init(gui.alloc),
            .id_kv_map = std.StringHashMap(usize).init(gui.alloc),
        };
        self.area.draw_fn = &draw;
        self.area.deinit_fn = &area_deinit;

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        //self.layout.deinit(gui, vt);
        self.kv_id_map.deinit();
        self.id_kv_map.deinit();
        vt.deinit(gui);
        gui.alloc.destroy(self); //second
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, d: DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
    }

    pub fn setTab(self: *Self, tab_index: usize) void {
        if (self.tab_index != tab_index)
            self.vt.needs_rebuild = true;
        self.tab_index = tab_index;
    }

    fn resetIds(self: *Self) void {
        self.kv_id_map.clearRetainingCapacity();
        self.id_kv_map.clearRetainingCapacity();
        self.kv_id_index = 0;
    }

    /// name must be owned by someone else, probably editor.stringstorage
    fn getId(self: *Self, name: []const u8) usize {
        if (self.id_kv_map.get(name)) |item| return item;
        const id = self.kv_id_index;
        self.kv_id_index += 1;
        self.kv_id_map.put(id, name) catch return id;
        self.id_kv_map.put(name, id) catch return id;
        return id;
    }

    fn getNameFromId(self: *Self, id: usize) ?[]const u8 {
        return self.kv_id_map.get(id);
    }

    pub fn build(vt: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.area.area = area;
        self.area.clearChildren(gui, vt);
        self.area.dirty(gui);
        //self.layout.reset(gui, vt);
        //start a vlayout
        //var ly = Vert{ .area = vt.area };
        //const max_w = gui.style.config.default_item_h * 30;
        const sp1 = vt.area.area;
        //const sp1 = vt.area.area.split(.horizontal, vt.area.area.h * 0.5);
        const inset = GuiHelp.insetAreaForWindowFrame(gui, sp1);
        const w = inset.w;
        var ly = guis.VerticalLayout{
            .padding = .{},
            .item_height = gui.style.config.default_item_h,
            .bounds = Rec(inset.x, inset.y, w, inset.h),
        };
        ly.padding.left = 10;
        ly.padding.right = 10;
        ly.padding.top = 10;
        const a = &self.area;

        const ds = &self.editor.draw_state;
        {
            var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 4 };
            const CB = Wg.Checkbox.build;
            a.addChildOpt(gui, vt, CB(gui, hy.getArea(), "draw sprite", .{ .bool_ptr = &ds.tog.sprite }, null));
            a.addChildOpt(gui, vt, CB(gui, hy.getArea(), "draw models", .{ .bool_ptr = &ds.tog.models }, null));
            a.addChildOpt(gui, vt, CB(gui, hy.getArea(), "ignore groups", .{ .bool_ptr = &self.editor.selection.ignore_groups }, null));
        }
        ly.pushRemaining();
        a.addChildOpt(gui, vt, Wg.Tabs.build(gui, ly.getArea(), &tabs, vt, .{ .build_cb = &buildTabs, .cb_vt = &self.area, .index_ptr = &self.tab_index }));
    }

    fn buildTabs(user_vt: *iArea, vt: *iArea, tab_name: []const u8, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", user_vt));
        const eql = std.mem.eql;
        if (eql(u8, tab_name, "layer")) {
            const sp2 = vt.area.split(.horizontal, vt.area.h / 2);
            self.layer_widget.build(gui, win, vt, sp2[0]) catch {};

            var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = sp2[1] };

            for (self.editor.autovis.filters.items, 0..) |filter, i| {
                vt.addChildOpt(
                    gui,
                    win,
                    Wg.Checkbox.build(gui, ly.getArea(), filter.name, .{
                        .cb_fn = &checkbox_cb_auto_vis,
                        .cb_vt = win.area,
                        .user_id = i,
                    }, self.editor.autovis.enabled.items[i]),
                );
            }

            //var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = vt.area };
            //vt.addChildOpt(gui, win, Wg.Text.buildStatic(gui, ly.getArea(), "Welcome to visgroup", null));
        }
        if (eql(u8, tab_name, "props")) {
            const sp = vt.area.split(.horizontal, vt.area.h * 0.5);
            {
                var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = sp[0] };
                ly.padding.left = 10;
                ly.padding.right = 10;
                ly.padding.top = 10;
                self.buildProps(gui, &ly, vt) catch {};
            }

            {
                var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = sp[1] };
                ly.padding.left = 10;
                ly.padding.right = 10;
                ly.padding.top = 10;
                self.buildValueEditor(gui, &ly, vt) catch {};
            }
            return;
        }
        if (eql(u8, tab_name, "io")) {
            const sp = vt.area.split(.horizontal, vt.area.h * 0.5);
            var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = sp[1] };
            ly.padding.left = 10;
            ly.padding.right = 10;
            ly.padding.top = 10;

            const names = [6][]const u8{ "Listen", "target", "input", "value", "delay", "fc" };
            const BetterNames = [names.len][]const u8{ "My output named", "Target entities named", "Via this input", "With a parameter of", "After a delay is seconds of", "Limit to this many fires" };
            vt.addChildOpt(gui, win, Wg.DynamicTable.build(gui, sp[0], win, .{
                .column_positions = &self.io_columns_width,
                .column_names = &names,
                .build_cb = &buildIo,
                .build_vt = win.area,
            }));

            vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "Add new", .{
                .cb_vt = &self.area,
                .cb_fn = &ioBtnCbAdd,
            }));
            const cons = self.getConsPtr() orelse return;
            if (self.selected_io_index < cons.list.items.len) {
                const li = &cons.list.items[self.selected_io_index];
                for (BetterNames, 0..) |n, i| {
                    const ar = ly.getArea() orelse break;
                    const sp1 = ar.split(.vertical, ar.w / 2);

                    vt.addChildOpt(gui, win, Wg.Text.buildStatic(gui, sp1[0], n, null));
                    switch (i) {
                        0 => self.buildOutputCombo(vt, gui, win, sp1[1]),
                        1 => vt.addChildOpt(gui, win, Wg.Textbox.buildOpts(gui, sp1[1], .{
                            .init_string = li.target.items,
                            .user_id = 1,
                            .commit_vt = &self.area,
                            .commit_cb = &ioTextboxCb,
                        })),
                        2 => self.buildInputCombo(vt, gui, win, sp1[1]),
                        3 => vt.addChildOpt(gui, win, Wg.Textbox.buildOpts(gui, sp1[1], .{
                            .init_string = li.value.items,
                            .user_id = 3,
                            .commit_vt = &self.area,
                            .commit_cb = &ioTextboxCb,
                        })),
                        4 => vt.addChildOpt(gui, win, Wg.TextboxNumber.build(gui, sp1[1], li.delay, win, .{
                            .user_id = 4,
                            .commit_vt = &self.area,
                            .commit_cb = &ioTextboxCb,
                        })),
                        5 => vt.addChildOpt(gui, win, Wg.TextboxNumber.build(gui, sp1[1], li.fire_count, win, .{
                            .user_id = 5,
                            .commit_vt = &self.area,
                            .commit_cb = &ioTextboxCb,
                        })),
                        else => {},
                    }
                }
            }
        }
        if (eql(u8, tab_name, "tool")) {
            const tool = self.editor.getCurrentTool() orelse return;
            const cb_fn = tool.gui_build_cb orelse return;

            cb_fn(tool, self, vt, gui, win);
        }
    }

    pub fn checkbox_cb_auto_vis(user: *iArea, _: *Gui, val: bool, id: usize) void {
        const self: *InspectorWindow = @alignCast(@fieldParentPtr("area", user));
        if (id >= self.editor.autovis.enabled.items.len) return;
        self.editor.autovis.enabled.items[id] = val;
        self.editor.rebuildAutoVis() catch return;
    }
    fn misc_btn_cb(vt: *iArea, btn_id: usize, _: *Gui, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", vt));
        self.misc_btn_cbErr(btn_id) catch return;
    }
    fn misc_btn_cbErr(self: *@This(), btn_id: usize) !void {
        switch (@as(MiscBtn, @enumFromInt(btn_id))) {
            .ungroup => {
                const selection = self.editor.selection.getSlice();
                if (selection.len > 0) {
                    const ustack = try self.editor.undoctx.pushNewFmt("ungrouping of {d} objects", .{selection.len});
                    for (selection) |id| {
                        const old = if (try self.editor.ecs.getOpt(id, .group)) |g| g.id else 0;
                        try ustack.append(
                            try undo.UndoChangeGroup.create(self.editor.undoctx.alloc, old, 0, id),
                        );
                    }
                    undo.applyRedo(ustack.items, self.editor);
                    try self.editor.notify("ungrouped {d} objects", .{selection.len}, 0x00ff00ff);
                }
            },
        }
    }

    fn buildProps(self: *@This(), gui: *Gui, ly: anytype, lay: *iArea) !void {
        const ed = self.editor;
        const a = &self.area;
        const win = &self.vt;
        self.selected_class_id = null;
        {
            var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 4 };
            lay.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "Ungroup", .{
                .cb_vt = &self.area,
                .cb_fn = &misc_btn_cb,
                .id = @intFromEnum(MiscBtn.ungroup),
            }));
        }
        if (ed.selection.getGroupOwnerExclusive(&ed.groups)) |sel_id| {
            if (try ed.ecs.getOptPtr(sel_id, .entity)) |ent| {
                const aa = ly.getArea() orelse return;
                const Lam = struct {
                    fn commit(vtt: *iArea, id: usize, _: void) void {
                        const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));
                        const fields = lself.editor.fgd_ctx.ents.items;
                        lself.vt.needs_rebuild = true;
                        if (id >= fields.len) return;
                        const led = lself.editor;
                        if (led.selection.getGroupOwnerExclusive(&led.groups)) |lsel_id| {
                            if (led.ecs.getOptPtr(lsel_id, .entity) catch null) |lent| {
                                lent.setClass(led, fields[id].name, lsel_id) catch return;
                            }
                        }
                    }

                    fn name(vtt: *iArea, id: usize, _: *Gui, _: void) []const u8 {
                        const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));
                        const fields = lself.editor.fgd_ctx.ents.items;
                        if (id >= fields.len) return "BROKEN";
                        return fields[id].name;
                    }
                };
                self.selected_class_id = ed.fgd_ctx.getId(ent.class);
                if (guis.label(lay, gui, win, aa, "Ent Class", .{})) |ar|
                    lay.addChildOpt(gui, win, Wg.ComboUser(void).build(gui, ar, .{
                        .user_vt = &self.area,
                        .commit_cb = &Lam.commit,
                        .name_cb = &Lam.name,
                        .current = self.selected_class_id orelse 0,
                        .count = self.editor.fgd_ctx.ents.items.len,
                    }, {}));
                lay.addChildOpt(gui, win, Wg.Textbox.buildOpts(gui, ly.getArea(), .{ .init_string = ent.class }));
                const eclass = ed.fgd_ctx.getPtr(ent.class) orelse return;
                const fields = eclass.field_data.items;
                if (eclass.doc.len > 0) { //Doc string
                    ly.pushHeight(Wg.TextView.heightForN(gui, 4));
                    lay.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{eclass.doc}, win, .{
                        .mode = .split_on_space,
                    }));
                }
                ly.pushRemaining();
                lay.addChildOpt(gui, win, Wg.VScroll.build(gui, ly.getArea(), .{
                    .build_cb = &buildScrollItems,
                    .build_vt = a,
                    .win = win,
                    .count = fields.len,
                    .item_h = gui.style.config.default_item_h,
                    .index_ptr = &self.kv_scroll_index,
                }));
            }
            if (try ed.ecs.getOptPtr(sel_id, .solid)) |sol| {
                _ = sol;
                lay.addChildOpt(gui, &self.vt, Wg.Text.build(gui, ly.getArea(), "selected_solid: {d}", .{sel_id}));
            }
        }
    }

    // If a kv is selected, this edits it
    fn buildValueEditor(self: *@This(), gui: *Gui, ly: anytype, lay: *iArea) !void {
        const ed = self.editor;
        const win = &self.vt;
        if (self.selected_class_id) |cid| {
            const class = &ed.fgd_ctx.ents.items[cid];
            if (self.selected_kv_index >= class.field_data.items.len) return;
            const field = &class.field_data.items[self.selected_kv_index];

            lay.addChildOpt(gui, &self.vt, Wg.Text.buildStatic(gui, ly.getArea(), field.name, null));
            if (field.doc_string.len > 0) {
                ly.pushHeight(Wg.TextView.heightForN(gui, 4));
                lay.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{field.doc_string}, win, .{
                    .mode = .split_on_space,
                }));
            }
            const kvs = self.getKvsPtr() orelse return;
            const val = kvs.map.getPtr(field.name) orelse return;
            const cb_id = self.getId(field.name);
            const ar = ly.getArea();
            lay.addChildOpt(gui, win, Wg.Textbox.buildOpts(gui, ar, .{
                .init_string = val.slice(),
                .user_id = cb_id,
                .commit_vt = win.area,
                .commit_cb = &cb_commitTextbox,
            }));
            //Extra stuff for typed fields TODO put in a scroll
            switch (field.type) {
                .flags => |flags| {
                    const mask = std.fmt.parseInt(u32, val.slice(), 10) catch null;
                    for (flags.items) |flag| {
                        const is_set = if (mask) |m| flag.mask & m > 0 else flag.on;
                        const packed_id: u64 = @as(u64, @intCast(flag.mask)) << 32 | cb_id;
                        lay.addChildOpt(gui, win, Wg.Checkbox.build(gui, ly.getArea(), flag.name, .{
                            .cb_fn = &cb_commitCheckbox,
                            .cb_vt = win.area,
                            .user_id = packed_id,
                        }, is_set));
                    }
                },
                .material => {},
                else => {},
            }
        }
    }

    pub fn buildScrollItems(window_area: *iArea, vt: *iArea, index: usize, gui: *Gui, win: *iWindow) void {
        buildScrollItemsErr(window_area, vt, index, gui, win) catch return;
    }

    pub fn getSelId(self: *Self) ?ecs.EcsT.Id {
        return (self.editor.selection.getGroupOwnerExclusive(&self.editor.groups));
    }

    pub fn getKvsPtr(self: *Self) ?*ecs.KeyValues {
        const ed = self.editor;
        if (ed.selection.getGroupOwnerExclusive(&ed.groups)) |sel_id|
            return (ed.ecs.getOptPtr(sel_id, .key_values) catch null);
        return null;
    }

    pub fn getEntDef(self: *@This()) ?*fgd.EntClass {
        const ed = self.editor;
        if (ed.selection.getGroupOwnerExclusive(&ed.groups)) |sel_id| {
            if (ed.ecs.getOptPtr(sel_id, .entity) catch null) |ent| {
                return ed.fgd_ctx.getPtr(ent.class);
            }
        }
        return null;
    }

    pub fn getConsPtr(self: *Self) ?*ecs.Connections {
        const ed = self.editor;
        if (ed.selection.getGroupOwnerExclusive(&ed.groups)) |sel_id|
            return (ed.ecs.getOptPtr(sel_id, .connections) catch null);
        return null;
    }

    pub fn buildScrollItemsErr(window_area: *iArea, vt: *iArea, index: usize, gui: *Gui, _: *iWindow) !void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", window_area));
        self.resetIds();
        var ly = guis.TableLayout{ .item_height = gui.style.config.default_item_h, .bounds = vt.area, .columns = 2 };
        const ed = self.editor;
        const a = vt;
        const win = &self.vt;
        if (ed.selection.getGroupOwnerExclusive(&ed.groups)) |sel_id| {
            if (ed.ecs.getOptPtr(sel_id, .entity) catch null) |ent| {
                const eclass = ed.fgd_ctx.getPtr(ent.class) orelse return;
                const class_i = ed.fgd_ctx.base.get(ent.class) orelse return;
                const fields = eclass.field_data.items;
                if (index >= fields.len) return;
                const kvs = if (try ed.ecs.getOptPtr(sel_id, .key_values)) |kv| kv else blk: {
                    try ed.ecs.attach(sel_id, .key_values, ecs.KeyValues.init(ed.alloc));
                    break :blk try ed.ecs.getPtr(sel_id, .key_values);
                };
                for (fields[index..], index..) |req_f, f_i| {
                    const cb_id = self.getId(req_f.name);
                    a.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), req_f.name, .{
                        .cb_vt = window_area,
                        .cb_fn = &select_kv_cb,
                        .id = f_i,
                        .custom_draw = &customButtonDraw,
                        .user_1 = if (self.selected_kv_index == f_i) 1 else 0,
                    }));
                    const value = try kvs.getOrPutDefault(&ed.ecs, sel_id, req_f.name, req_f.default);
                    //const res = try kvs.map.getOrPut(req_f.name);
                    //if (!res.found_existing) {
                    //    res.value_ptr.* = try ecs.KeyValues.initDefault(&ed.ecs, sel_id, req_f.name, req_f.default);
                    //    //var new_list = std.ArrayList(u8).init(ed.alloc);
                    //    //try new_list.appendSlice(req_f.default);
                    //    //res.value_ptr.* = .{ ._string = new_list };
                    //}
                    switch (req_f.type) {
                        .model, .material => {
                            const H = struct {
                                fn btn_cb(win_ar: *iArea, id: u64, _: *Gui, _: *iWindow) void {
                                    // if msb of id is set, its a texture not model
                                    // hacky yea.
                                    const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", win_ar));
                                    const idd = id << 1 >> 1; //clear msb;

                                    const is_mat = (id & (1 << 63) != 0);
                                    std.debug.print("is mat {any}\n", .{is_mat});
                                    lself.editor.asset_browser.dialog_state = .{
                                        .target_id = @intCast(idd),
                                        .previous_pane_index = lself.editor.draw_state.tab_index,
                                        .kind = if (is_mat) .texture else .model,
                                    };
                                    const ds = &lself.editor.draw_state;
                                    lself.editor.draw_state.tab_index = if (is_mat) ds.texture_browser_tab_index else ds.model_browser_tab_index;
                                }
                            };
                            const mask: u64 = if (req_f.type == .material) 1 << 63 else 0;
                            const idd: u64 = sel_id | mask;
                            a.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "Select", .{
                                .cb_vt = window_area,
                                .cb_fn = &H.btn_cb,
                                .id = idd,
                            }));
                        },
                        .choices => |ch| {
                            const ar = ly.getArea();
                            if (ch.items.len == 0) continue;
                            if (ch.items.len == 2 and std.mem.eql(u8, ch.items[0][0], "0")) {
                                const checked = !std.mem.eql(u8, value.slice(), ch.items[0][0]);
                                a.addChildOpt(gui, win, Wg.Checkbox.build(gui, ar, "", .{
                                    .cb_fn = &cb_commitCheckbox,
                                    .cb_vt = win.area,
                                    .user_id = cb_id,
                                }, checked));
                            } else {
                                var found: usize = 0;
                                for (ch.items, 0..) |choice, i| {
                                    if (std.mem.eql(u8, value.slice(), choice[0])) {
                                        found = i;
                                        break;
                                    }
                                }
                                self.buildChoice(.{ .class_i = class_i, .field_i = f_i, .count = ch.items.len, .current = found }, ar, gui, win, a);
                            }
                        },
                        .color255 => {
                            const floats = value.getFloats(4);
                            const ar = ly.getArea() orelse return;
                            const sp = ar.split(.vertical, ar.w / 2);
                            const color = graph.ptypes.intColorFromVec3(graph.za.Vec3.new(floats[0], floats[1], floats[2]), 1);
                            a.addChildOpt(gui, win, Wg.Colorpicker.build(gui, sp[0], color, .{
                                .user_id = cb_id,
                                .commit_vt = win.area,
                                .commit_cb = &cb_commitColor,
                            }));

                            a.addChildOpt(gui, win, Wg.TextboxNumber.build(gui, sp[1], floats[3], win, .{
                                .user_id = cb_id,
                                .commit_cb = &setBrightness,
                                .commit_vt = win.area,
                                //.init_string = ed.printScratch("{d}", .{c[3]}) catch "100",
                            }));
                        },
                        else => {
                            const ar = ly.getArea();
                            a.addChildOpt(gui, win, Wg.Textbox.buildOpts(gui, ar, .{
                                .init_string = value.slice(),
                                .user_id = cb_id,
                                .commit_vt = win.area,
                                .commit_cb = &cb_commitTextbox,
                            }));
                        },
                    }
                }
            }
        }
    }

    fn setBrightness(this_w: *iArea, _: *Gui, value: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", this_w));
        if (self.getNameFromId(id)) |field_name| {
            const ent_id = self.getSelId() orelse return;
            const kvs = self.getKvsPtr() orelse return;

            if (kvs.map.getPtr(field_name)) |ptr| {
                var floats = ptr.getFloats(4);
                floats[3] = std.fmt.parseFloat(f32, value) catch return;
                const ustack = self.editor.undoctx.pushNewFmt("Set brightness {s}: {d}", .{ field_name, floats[3] }) catch return;
                const old = kvs.getString(field_name) orelse "";
                ustack.append(undo.UndoSetKeyValue.createFloats(
                    self.editor.undoctx.alloc,
                    ent_id,
                    field_name,
                    old,
                    4,
                    floats,
                ) catch return) catch return;
                undo.applyRedo(ustack.items, self.editor);
            }
        }
    }

    fn setKvStr(self: *Self, field_id: usize, value: []const u8) void {
        if (self.getNameFromId(field_id)) |field_name| {
            const ustack = self.editor.undoctx.pushNewFmt("Set kv {s}:{s}", .{ field_name, value }) catch return;

            const ent_id = self.getSelId() orelse return;
            const kvs = self.getKvsPtr() orelse return;
            const old = kvs.getString(field_name) orelse "";
            ustack.append(undo.UndoSetKeyValue.create(
                self.editor.undoctx.alloc,
                ent_id,
                field_name,
                old,
                value,
            ) catch return) catch return;
            undo.applyRedo(ustack.items, self.editor);
        }
    }

    fn setKvFloat(self: *Self, id: usize, floats: []const f32) void {
        if (floats.len > 4) return;
        if (self.getNameFromId(id)) |field_name| {
            const kvs = self.getKvsPtr() orelse return;
            if (kvs.map.getPtr(field_name)) |ptr| {
                switch (ptr.*) {
                    .string => {},
                    .floats => {
                        ptr.floats.count = @intCast(floats.len);
                        @memcpy(ptr.floats.d[0..floats.len], floats);
                    },
                }
            }
        }
    }

    pub fn cb_commitColor(this_w: *iArea, _: *Gui, val: u32, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", this_w));
        const charc = graph.ptypes.intToColor(val);
        if (self.getNameFromId(id)) |field_name| {
            const ent_id = self.getSelId() orelse return;
            const kvs = self.getKvsPtr() orelse return;

            if (kvs.map.getPtr(field_name)) |ptr| {
                var floats = ptr.getFloats(4);
                floats[0] = @floatFromInt(charc.r);
                floats[1] = @floatFromInt(charc.g);
                floats[2] = @floatFromInt(charc.b);

                const ustack = self.editor.undoctx.pushNewFmt("Set {s} {d} {d} {d}", .{
                    field_name,
                    floats[0],
                    floats[1],
                    floats[2],
                }) catch return;
                const old = kvs.getString(field_name) orelse "";
                ustack.append(undo.UndoSetKeyValue.createFloats(
                    self.editor.undoctx.alloc,
                    ent_id,
                    field_name,
                    old,
                    4,
                    floats,
                ) catch return) catch return;
                undo.applyRedo(ustack.items, self.editor);
            }
        }
    }

    pub fn cb_commitCheckbox(this_window: *iArea, _: *Gui, val: bool, id: u64) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", this_window));
        const upper: u32 = @intCast(id >> 32);
        if (upper != 0) { //we store flags in upper 32
            const lower = id << 32 >> 32; //Clear upper
            const kvs = self.getKvsPtr() orelse return;
            const name = self.getNameFromId(lower) orelse return;
            const old_str = kvs.getString(name) orelse return;
            var mask = std.fmt.parseInt(u32, old_str, 10) catch 0;
            if (val) {
                mask = mask | upper; //add bit
            } else {
                mask = mask & ~upper; //remove bit
            }
            self.setKvStr(lower, self.editor.printScratch("{d}", .{mask}) catch return);
        } else {
            self.setKvStr(id, if (val) "1" else "0");
        }
    }

    pub fn cb_commitTextbox(this_window: *iArea, _: *Gui, string: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", this_window));
        self.setKvStr(id, string);
    }

    pub fn select_kv_cb(this_window: *iArea, id: usize, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", this_window));
        _ = gui;
        win.needs_rebuild = true;
        self.selected_kv_index = id;
        //We need to rebuild buttons to show the selected mark
    }

    pub fn buildChoice(self: *@This(), info: anytype, area: ?Rect, gui: *Gui, win: *iWindow, vt: *iArea) void {
        //const ed = self.editor;
        const aa = area orelse return;
        const Lam = struct {
            fgd_class_index: usize,
            fgd_field_index: usize,

            fn commit(vtt: *iArea, id: usize, lam: @This()) void {
                const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));

                const fields = lself.editor.fgd_ctx.ents.items;
                const f = fields[lam.fgd_class_index];
                const fie = f.field_data.items[lam.fgd_field_index];

                lself.setKvStr(lam.fgd_field_index, fie.type.choices.items[id][0]);
            }

            fn name(vtt: *iArea, id: usize, _: *Gui, lam: @This()) []const u8 {
                const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));
                const class = lself.editor.fgd_ctx.ents.items[lam.fgd_class_index];
                const field = class.field_data.items[lam.fgd_field_index];
                if (field.type == .choices) {
                    if (id < field.type.choices.items.len)
                        return field.type.choices.items[id][1];
                }
                return "not a choice";
            }
        };
        vt.addChildOpt(gui, win, Wg.ComboUser(Lam).build(
            gui,
            aa,
            .{
                .user_vt = &self.area,
                .commit_cb = &Lam.commit,
                .name_cb = &Lam.name,
                .current = info.current,
                .count = info.count,
            },
            .{ .fgd_class_index = info.class_i, .fgd_field_index = info.field_i },
        ));
    }

    fn buildIo(user_vt: *iArea, area_vt: *iArea, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", user_vt));
        const cons = self.getConsPtr() orelse return;
        area_vt.addChildOpt(gui, win, Wg.VScroll.build(gui, area_vt.area, .{
            .build_cb = &buildIoScrollCb,
            .build_vt = user_vt,
            .win = win,
            .count = cons.list.items.len,
            .item_h = gui.style.config.default_item_h,
            .index_ptr = &self.io_scroll_index,
        }));
    }

    fn buildIoScrollCb(window_area: *iArea, vt: *iArea, index: usize, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", window_area));
        _ = win;
        self.buildIoTab(gui, vt.area, vt, index) catch return;
    }

    fn io_btn_cb(window_area: *iArea, id: usize, _: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", window_area));
        self.selected_io_index = id;
        win.needs_rebuild = true;
    }

    fn buildIoTab(self: *@This(), gui: *Gui, area: Rect, lay: *iArea, index: usize) !void {
        const cons = self.getConsPtr() orelse return;
        const win = &self.vt;
        //const th = gui.style.config.text_h;
        //const num_w = th * 2;
        //const rem4 = @trunc((area.w - num_w * 2) / 4);
        var widths: [6]f32 = undefined;
        //const col_ws = [6]f32{ rem4, rem4, rem4, rem4, num_w, num_w };
        var tly = Wg.DynamicTable.calcLayout(&self.io_columns_width, &widths, area, gui) orelse return;
        //var tly1 = guis.TableLayoutCustom{ .item_height = gui.style.config.default_item_h, .bounds = area, .column_widths = &col_ws };
        if (index >= cons.list.items.len) return;
        for (cons.list.items[index..], index..) |con, ind| {
            const opts = Wg.Button.Opts{
                .custom_draw = &customButtonDraw,
                .id = ind,
                .cb_fn = &io_btn_cb,
                .cb_vt = &self.area,
                .user_1 = if (self.selected_io_index == ind) 1 else 0,
            };
            const strs = [4][]const u8{ con.listen_event, con.target.items, con.input, con.value.items };
            //con.delay, con.fire_count };
            for (strs) |str|
                lay.addChildOpt(gui, win, Wg.Button.build(gui, tly.getArea(), str, opts));
            //TODO make these buttons too
            lay.addChildOpt(gui, win, Wg.Text.build(gui, tly.getArea(), "{d}", .{con.delay}));
            lay.addChildOpt(gui, win, Wg.Text.build(gui, tly.getArea(), "{d}", .{con.fire_count}));
        }
    }

    fn ioBtnCbAdd(vt: *iArea, _: usize, _: *Gui, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", vt));
        const cons = self.getConsPtr() orelse blk: {
            if (self.editor.selection.getGroupOwnerExclusive(&self.editor.groups)) |sel_id| {
                self.editor.ecs.attach(sel_id, .connections, ecs.Connections.init(self.editor.alloc)) catch return;
                break :blk self.getConsPtr() orelse return;
            }
            return;
        };
        const index = cons.list.items.len;
        cons.addEmpty() catch return;
        self.selected_io_index = index;
        self.vt.needs_rebuild = true;
    }

    fn ioTextboxCb(this_window: *iArea, _: *Gui, string: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", this_window));
        const cons = self.getConsPtr() orelse return;
        if (self.selected_io_index >= cons.list.items.len) return;
        const con = &cons.list.items[self.selected_io_index];

        //Numbers are indexes into the table "names"
        switch (id) {
            1 => { //Target
                con.target.clearRetainingCapacity();
                con.target.appendSlice(string) catch return;
            },
            3 => {
                con.value.clearRetainingCapacity();
                con.value.appendSlice(string) catch return;
            },
            4 => { //delay
                const num = std.fmt.parseFloat(f32, string) catch return;
                con.delay = num;
            },
            5 => {
                const num = std.fmt.parseInt(i32, string, 10) catch return;
                con.fire_count = num;
            },
            else => {},
        }
    }

    pub fn buildOutputCombo(self: *@This(), lay: *iArea, gui: *Gui, win: *iWindow, aa: graph.Rect) void {
        const cons = self.getConsPtr() orelse return;
        if (self.selected_io_index >= cons.list.items.len) return;

        const Lam = struct {
            fn commit(vtt: *iArea, id: usize, _: void) void {
                const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));
                const lcons = lself.getConsPtr() orelse return;
                if (lself.selected_io_index >= lcons.list.items.len) return;

                const class = lself.getEntDef() orelse return;
                if (id >= class.outputs.items.len) return;
                const ind = class.outputs.items[id];
                const lname = class.io_data.items[ind].name;
                lcons.list.items[lself.selected_io_index].listen_event = lname;
            }

            fn name(vtt: *iArea, id: usize, _: *Gui, _: void) []const u8 {
                const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));
                const class = lself.getEntDef() orelse return "broken";
                if (id >= class.outputs.items.len) return "BROKEN";
                const ind = class.outputs.items[id];
                return class.io_data.items[ind].name;
            }
        };

        const current_item = cons.list.items[self.selected_io_index].listen_event;
        const class = self.getEntDef() orelse return;
        var index: usize = 0;
        for (class.outputs.items, 0..) |out_i, i| {
            const out = class.io_data.items[out_i];
            if (std.mem.eql(u8, out.name, current_item)) {
                index = i;
                break;
            }
        }

        lay.addChildOpt(gui, win, Wg.ComboUser(void).build(gui, aa, .{
            .user_vt = &self.area,
            .commit_cb = &Lam.commit,
            .name_cb = &Lam.name,
            .current = index,
            //.current = self.selected_class_id orelse 0,
            .count = class.outputs.items.len,
        }, {}));
    }

    pub fn buildInputCombo(self: *@This(), lay: *iArea, gui: *Gui, win: *iWindow, aa: graph.Rect) void {
        const Lam = struct {
            fn commit(vtt: *iArea, id: usize, _: void) void {
                const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));
                const lcons = lself.getConsPtr() orelse return;
                if (lself.selected_io_index >= lcons.list.items.len) return;

                const list = lself.editor.fgd_ctx.all_inputs.items;
                if (id >= list.len) return;
                lcons.list.items[lself.selected_io_index].input = list[id].name;
            }

            fn name(vtt: *iArea, id: usize, _: *Gui, _: void) []const u8 {
                const lself: *InspectorWindow = @alignCast(@fieldParentPtr("area", vtt));
                const list = lself.editor.fgd_ctx.all_inputs.items;
                if (id >= list.len) return "BROKEN";
                return list[id].name;
            }
        };

        const cons = self.getConsPtr() orelse return;
        if (self.selected_io_index >= cons.list.items.len) return;
        const current_item = cons.list.items[self.selected_io_index].input;

        const index = if (self.editor.fgd_ctx.all_input_map.get(current_item)) |io| io else 0;
        lay.addChildOpt(gui, win, Wg.ComboUser(void).build(gui, aa, .{
            .user_vt = &self.area,
            .commit_cb = &Lam.commit,
            .name_cb = &Lam.name,
            .current = index,
            .count = self.editor.fgd_ctx.all_inputs.items.len,
        }, {}));
    }

    pub fn selectedTextureWidget(self: *Self, lay: *iArea, gui: *Gui, win: *iWindow, area: graph.Rect) void {
        const ed = self.editor;
        const sp = area.split(.vertical, area.w / 2);
        if (ed.asset_browser.selected_mat_vpk_id) |id| {
            const tt = ed.vpkctx.entries.get(id) orelse return;
            lay.addChildOpt(gui, win, ptext.PollingTexture.build(gui, sp[0], ed, id, "{s}/{s}", .{
                tt.path, tt.name,
            }, .{}));
        }
        {
            const max = 16;
            var tly = guis.TableLayout{ .columns = 4, .item_height = sp[1].h / 4, .bounds = sp[1] };
            const recent_list = ed.asset_browser.recent_mats.list.items;
            for (recent_list[0..@min(max, recent_list.len)], 0..) |rec, id| {
                lay.addChildOpt(gui, win, ptext.PollingTexture.build(gui, tly.getArea(), ed, rec, "", .{}, .{
                    .cb_vt = &self.area,
                    .cb_fn = recent_texture_btn_cb,
                    .id = id,
                }));
            }
        }
    }

    pub fn recent_texture_btn_cb(vt: *guis.iArea, id: usize, _: *Gui, _: *guis.iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", vt));
        const asb = &self.editor.asset_browser;
        if (id >= asb.recent_mats.list.items.len) return;
        const missing = edit.missingTexture();
        const vpk_id = asb.recent_mats.list.items[id];
        const tex = self.editor.getTexture(vpk_id) catch return;
        if (tex.id == missing.id) return;
        asb.selected_mat_vpk_id = vpk_id;
        self.vt.needs_rebuild = true;
    }
};

/// This should only be passed to Wg.Button !
pub fn customButtonDraw(vt: *iArea, d: DrawState) void {
    const self: *Wg.Button = @alignCast(@fieldParentPtr("vt", vt));
    d.ctx.rect(vt.area, 0xffff_ffff);
    if (self.opts.user_1 == 1) {
        const SELECTED_FIELD_COLOR = 0x6097dbff;
        d.ctx.rect(vt.area, SELECTED_FIELD_COLOR);
    }
    const ta = vt.area.inset(3 * d.scale);
    d.ctx.textClipped(ta, "{s}", .{self.text}, d.textP(0xff), .center);
}

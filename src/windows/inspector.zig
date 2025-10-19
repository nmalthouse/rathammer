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
const app = @import("../app.zig");
const Layer = @import("../layer.zig");
const CbHandle = guis.CbHandle;
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
    cbhandle: CbHandle = .{},

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

    show_help: bool = true,

    ev_vt: app.iEvent = .{ .cb = event_cb },

    pub fn create(gui: *Gui, editor: *Context) *InspectorWindow {
        const self = gui.create(@This());
        self.* = .{
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, .{}, &self.vt),
            .editor = editor,
            .layer_widget = Layer.GuiWidget.init(&editor.layers, &editor.edit_state.selected_layer, editor, &self.vt),
            .kv_id_map = std.AutoHashMap(usize, []const u8).init(gui.alloc),
            .id_kv_map = std.StringHashMap(usize).init(gui.alloc),
        };

        if (editor.eventctx.registerListener(&self.ev_vt)) |listener| {
            editor.eventctx.subscribe(listener, @intFromEnum(app.EventKind.undo)) catch {};
            editor.eventctx.subscribe(listener, @intFromEnum(app.EventKind.redo)) catch {};
            editor.eventctx.subscribe(listener, @intFromEnum(app.EventKind.tool_changed)) catch {};
        } else |_| {}

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

    pub fn event_cb(ev_vt: *app.iEvent, ev: app.Event) void {
        const self: *@This() = @alignCast(@fieldParentPtr("ev_vt", ev_vt));

        switch (ev) {
            .undo, .redo, .tool_changed => {
                self.vt.needs_rebuild = true;
            },
            else => {},
        }
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, _: *Gui, d: *DrawState) void {
        //GuiHelp.drawWindowFrame(d, vt.area);
        d.ctx.rect(vt.area, d.nstyle.color.bg);
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
        vt.area.area = area;
        vt.area.clearChildren(gui, vt);
        vt.area.dirty(gui);
        //self.layout.reset(gui, vt);
        //start a vlayout
        //var ly = Vert{ .area = vt.area };
        //const max_w = gui.style.config.default_item_h * 30;
        const sp1 = vt.area.area;
        //const sp1 = vt.area.area.split(.horizontal, vt.area.area.h * 0.5);
        const inset = GuiHelp.insetAreaForWindowFrame(gui, sp1);
        const w = inset.w;
        var ly = gui.dstate.vLayout(Rec(inset.x, inset.y, w, inset.h));
        ly.padding.left = 10;
        ly.padding.right = 10;
        ly.padding.top = 10;
        const a = &vt.area;
        ly.pushRemaining();
        _ = Wg.Tabs.build(a, ly.getArea(), &tabs, vt, .{ .build_cb = &buildTabs, .cb_vt = &self.cbhandle, .index_ptr = &self.tab_index });
    }

    fn buildTabs(cb: *CbHandle, vt: *iArea, tab_name: []const u8, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        const eql = std.mem.eql;
        if (eql(u8, tab_name, "layer")) {
            const sp2 = vt.area.split(.horizontal, vt.area.h / 2);
            self.layer_widget.build(gui, win, vt, sp2[0]) catch {};

            var ly = gui.dstate.vLayout(sp2[1]);

            for (self.editor.autovis.filters.items, 0..) |filter, i| {
                _ = Wg.Checkbox.build(vt, ly.getArea(), filter.name, .{
                    .cb_fn = &checkbox_cb_auto_vis,
                    .cb_vt = &self.cbhandle,
                    .user_id = i,
                }, self.editor.autovis.enabled.items[i]);
            }

            //var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = vt.area };
        }
        if (eql(u8, tab_name, "props")) {
            const sp = vt.area.split(.horizontal, vt.area.h * 0.5);
            {
                var ly = gui.dstate.vLayout(sp[0]);
                ly.padding.left = 10;
                ly.padding.right = 10;
                ly.padding.top = 10;
                self.buildProps(gui, &ly, vt) catch {};
            }

            _ = Wg.FloatScroll.build(vt, sp[1], .{
                .build_cb = buildValueEditor,
                .build_vt = &self.cbhandle,
                .win = win,
                .scroll_mul = gui.dstate.style.config.default_item_h * 4,
                .scroll_y = true,
                .scroll_x = false,
            });
            return;
        }
        if (eql(u8, tab_name, "io")) {
            const sp = vt.area.split(.horizontal, vt.area.h * 0.5);
            var ly = gui.dstate.vLayout(sp[1]);
            ly.padding.left = 10;
            ly.padding.right = 10;
            ly.padding.top = 10;

            const names = [6][]const u8{ "Listen", "target", "input", "value", "delay", "fc" };
            const BetterNames = [names.len][]const u8{ "My output named", "Target entities named", "Via this input", "With a parameter of", "After a delay is seconds of", "Limit to this many fires" };
            _ = Wg.DynamicTable.build(vt, sp[0], win, .{
                .column_positions = &self.io_columns_width,
                .column_names = &names,
                .build_cb = &buildIo,
                .build_vt = &self.cbhandle,
            });

            _ = Wg.Button.build(vt, ly.getArea(), "Add new", .{
                .cb_vt = &self.cbhandle,
                .cb_fn = &ioBtnCbAdd,
            });
            const cons = self.getConsPtr() orelse return;
            if (self.selected_io_index < cons.list.items.len) {
                const li = &cons.list.items[self.selected_io_index];
                for (BetterNames, 0..) |n, i| {
                    const ar = ly.getArea() orelse break;
                    const sp1 = ar.split(.vertical, ar.w / 2);

                    _ = Wg.Text.buildStatic(vt, sp1[0], n, null);
                    _ = switch (i) {
                        0 => self.buildOutputCombo(vt, sp1[1]),
                        1 => Wg.Textbox.buildOpts(vt, sp1[1], .{
                            .init_string = li.target.items,
                            .user_id = 1,
                            .commit_vt = &self.cbhandle,
                            .commit_cb = &ioTextboxCb,
                        }),
                        2 => self.buildInputCombo(vt, sp1[1]),
                        3 => Wg.Textbox.buildOpts(vt, sp1[1], .{
                            .init_string = li.value.items,
                            .user_id = 3,
                            .commit_vt = &self.cbhandle,
                            .commit_cb = &ioTextboxCb,
                        }),
                        4 => Wg.TextboxNumber.build(vt, sp1[1], li.delay, .{
                            .user_id = 4,
                            .commit_vt = &self.cbhandle,
                            .commit_cb = &ioTextboxCb,
                        }),
                        5 => Wg.TextboxNumber.build(vt, sp1[1], li.fire_count, .{
                            .user_id = 5,
                            .commit_vt = &self.cbhandle,
                            .commit_cb = &ioTextboxCb,
                        }),
                        else => {},
                    };
                }
            }
        }
        if (eql(u8, tab_name, "tool")) {
            const tool = self.editor.getCurrentTool() orelse return;
            const cb_fn = tool.gui_build_cb orelse return;

            cb_fn(tool, self, vt, gui, win);
        }
    }

    pub fn checkbox_cb_auto_vis(cb: *CbHandle, _: *Gui, val: bool, id: usize) void {
        const self: *InspectorWindow = @alignCast(@fieldParentPtr("cbhandle", cb));
        if (id >= self.editor.autovis.enabled.items.len) return;
        self.editor.autovis.enabled.items[id] = val;
        self.editor.rebuildAutoVis() catch return;
    }
    fn misc_btn_cb(cb: *CbHandle, btn_id: usize, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.misc_btn_cbErr(btn_id) catch return;
    }
    fn misc_btn_cbErr(self: *@This(), btn_id: usize) !void {
        switch (@as(MiscBtn, @enumFromInt(btn_id))) {
            .ungroup => {
                const selection = self.editor.getSelected();
                if (selection.len > 0) {
                    const ustack = try self.editor.undoctx.pushNewFmt("ungrouping of {d} objects", .{selection.len});
                    for (selection) |id| {
                        const old = if (try self.editor.ecs.getOpt(id, .group)) |g| g.id else 0;
                        try ustack.append(.{
                            .change_group = try .create(self.editor.undoctx.alloc, old, 0, id),
                        });
                    }
                    ustack.apply(self.editor);
                    try self.editor.notify("ungrouped {d} objects", .{selection.len}, 0x00ff00ff);
                }
            },
        }
    }

    fn buildProps(self: *@This(), gui: *Gui, ly: anytype, lay: *iArea) !void {
        const ed = self.editor;
        const win = &self.vt;
        self.selected_class_id = null;
        {
            var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 4 };
            _ = Wg.Button.build(lay, hy.getArea(), "Ungroup", .{
                .cb_vt = &self.cbhandle,
                .cb_fn = &misc_btn_cb,
                .id = @intFromEnum(MiscBtn.ungroup),
            });
            _ = Wg.Checkbox.build(lay, hy.getArea(), "show help", .{ .bool_ptr = &self.show_help }, null);
        }
        if (ed.selection.getGroupOwnerExclusive(&ed.groups)) |sel_id| {
            if (try ed.ecs.getOptPtr(sel_id, .entity)) |ent| {
                const aa = ly.getArea() orelse return;
                const Lam = struct {
                    fn commit(cb: *CbHandle, id: usize, _: void) void {
                        const lself: *InspectorWindow = @alignCast(@fieldParentPtr("cbhandle", cb));
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

                    fn name(vtt: *CbHandle, id: usize, _: *Gui, _: void) []const u8 {
                        const lself: *InspectorWindow = @alignCast(@fieldParentPtr("cbhandle", vtt));
                        const fields = lself.editor.fgd_ctx.ents.items;
                        if (id >= fields.len) return "BROKEN";
                        return fields[id].name;
                    }
                };
                self.selected_class_id = ed.fgd_ctx.getId(ent.class);
                if (guis.label(lay, aa, "Ent Class", .{})) |ar|
                    _ = Wg.ComboUser(void).build(lay, ar, .{
                        .user_vt = &self.cbhandle,
                        .commit_cb = &Lam.commit,
                        .name_cb = &Lam.name,
                        .current = self.selected_class_id orelse 0,
                        .count = self.editor.fgd_ctx.ents.items.len,
                    }, {});
                const eclass = ed.fgd_ctx.getPtr(ent.class) orelse return;
                const fields = eclass.field_data.items;
                const min_left_to_show_help = 10;
                const left = ly.countLeft();
                if (self.show_help and eclass.doc.len > 0 and left > min_left_to_show_help) { //Doc string
                    ly.pushHeight(Wg.TextView.heightForN(gui, 4));
                    _ = Wg.TextView.build(lay, ly.getArea(), &.{eclass.doc}, win, .{
                        .mode = .split_on_space,
                    });
                }
                ly.pushRemaining();
                _ = Wg.VScroll.build(lay, ly.getArea(), .{
                    .build_cb = &buildScrollItems,
                    .build_vt = &self.cbhandle,
                    .win = win,
                    .count = fields.len,
                    .item_h = gui.dstate.style.config.default_item_h,
                    .index_ptr = &self.kv_scroll_index,
                });
            }
            if (try ed.ecs.getOptPtr(sel_id, .solid)) |sol| {
                _ = sol;
                _ = Wg.Text.build(lay, ly.getArea(), "selected_solid: {d}", .{sel_id});
            }
        }
    }

    fn buildValueEditor(cb: *CbHandle, lay: *iArea, gui: *Gui, win: *iWindow, scr: *Wg.FloatScroll) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        buildValueEditorErr(self, lay, gui, win, scr) catch {};
    }

    // If a kv is selected, this edits it
    fn buildValueEditorErr(self: *@This(), lay: *iArea, gui: *Gui, win: *iWindow, scr: *Wg.FloatScroll) !void {
        var ly = gui.dstate.vLayout(lay.area);
        ly.padding.left = 10;
        ly.padding.right = 10;
        ly.padding.top = 0;
        defer scr.hintBounds(ly.getUsed());
        const ed = self.editor;
        if (self.selected_class_id) |cid| {
            const class = &ed.fgd_ctx.ents.items[cid];
            if (self.selected_kv_index >= class.field_data.items.len) return;
            const field = &class.field_data.items[self.selected_kv_index];

            _ = Wg.Text.buildStatic(lay, ly.getArea(), field.name, null);
            if (self.show_help and field.doc_string.len > 0) {
                ly.pushHeight(Wg.TextView.heightForN(gui, 4));
                _ = Wg.TextView.build(lay, ly.getArea(), &.{field.doc_string}, win, .{
                    .mode = .split_on_space,
                });
            }
            const kvs = self.getKvsPtr() orelse return;
            const val = kvs.map.getPtr(field.name) orelse return;
            const cb_id = self.getId(field.name);
            const ar = ly.getArea();
            _ = Wg.Textbox.buildOpts(lay, ar, .{
                .init_string = val.slice(),
                .user_id = cb_id,
                .commit_vt = &self.cbhandle,
                .commit_cb = &cb_commitTextbox,
            });
            //Extra stuff for typed fields TODO put in a scroll
            switch (field.type) {
                .flags => |flags| {
                    const mask = std.fmt.parseInt(u32, val.slice(), 10) catch null;
                    for (flags.items) |flag| {
                        const is_set = if (mask) |m| flag.mask & m > 0 else flag.on;
                        const packed_id: u64 = @as(u64, @intCast(flag.mask)) << 32 | cb_id;
                        _ = Wg.Checkbox.build(lay, ly.getArea(), flag.name, .{
                            .cb_fn = &cb_commitCheckbox,
                            .cb_vt = &self.cbhandle,
                            .user_id = packed_id,
                        }, is_set);
                    }
                },
                .material => {},
                else => {},
            }
        }
    }

    pub fn buildScrollItems(cb: *CbHandle, vt: *iArea, index: usize) void {
        buildScrollItemsErr(cb, vt, index) catch return;
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

    pub fn buildScrollItemsErr(cb: *CbHandle, vt: *iArea, index: usize) !void {
        const gui = vt.win_ptr.gui_ptr;
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.resetIds();
        var ly = guis.TableLayout{ .item_height = gui.dstate.style.config.default_item_h, .bounds = vt.area, .columns = 2 };
        const ed = self.editor;
        const a = vt;
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
                    _ = Wg.Button.build(a, ly.getArea(), req_f.name, .{
                        .cb_vt = &self.cbhandle,
                        .cb_fn = &select_kv_cb,
                        .id = f_i,
                        .custom_draw = &customButtonDraw,
                        .user_1 = if (self.selected_kv_index == f_i) 1 else 0,
                    });
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
                                fn btn_cb(cbb: *CbHandle, id: u64, _: guis.MouseCbState, _: *iWindow) void {
                                    // if msb of id is set, its a texture not model
                                    // hacky yea.
                                    const lself: *InspectorWindow = @alignCast(@fieldParentPtr("cbhandle", cbb));
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
                            _ = Wg.Button.build(a, ly.getArea(), "Select", .{
                                .cb_vt = &self.cbhandle,
                                .cb_fn = &H.btn_cb,
                                .id = idd,
                            });
                        },
                        .choices => |ch| {
                            const ar = ly.getArea();
                            if (ch.items.len == 0) continue;
                            if (ch.items.len == 2 and std.mem.eql(u8, ch.items[0][0], "0")) {
                                const checked = !std.mem.eql(u8, value.slice(), ch.items[0][0]);
                                _ = Wg.Checkbox.build(a, ar, "", .{
                                    .cb_fn = &cb_commitCheckbox,
                                    .cb_vt = &self.cbhandle,
                                    .user_id = cb_id,
                                }, checked);
                            } else {
                                var found: usize = 0;
                                for (ch.items, 0..) |choice, i| {
                                    if (std.mem.eql(u8, value.slice(), choice[0])) {
                                        found = i;
                                        break;
                                    }
                                }
                                self.buildChoice(.{ .class_i = class_i, .field_i = f_i, .count = ch.items.len, .current = found }, ar, a);
                            }
                        },
                        .color255 => {
                            const floats = value.getFloats(4);
                            const ar = ly.getArea() orelse return;
                            const sp = ar.split(.vertical, ar.w / 2);
                            const color = graph.ptypes.intColorFromVec3(graph.za.Vec3.new(floats[0], floats[1], floats[2]), 1);
                            _ = Wg.Colorpicker.build(a, sp[0], color, .{
                                .user_id = cb_id,
                                .commit_vt = &self.cbhandle,
                                .commit_cb = &cb_commitColor,
                            });

                            _ = Wg.TextboxNumber.build(a, sp[1], floats[3], .{
                                .user_id = cb_id,
                                .commit_cb = &setBrightness,
                                .commit_vt = &self.cbhandle,
                                //.init_string = ed.printScratch("{d}", .{c[3]}) catch "100",
                            });
                        },
                        else => {
                            const ar = ly.getArea();
                            _ = Wg.Textbox.buildOpts(a, ar, .{
                                .init_string = value.slice(),
                                .user_id = cb_id,
                                .commit_vt = &self.cbhandle,
                                .commit_cb = &cb_commitTextbox,
                            });
                        },
                    }
                }
            }
        }
    }

    fn setBrightness(cb: *CbHandle, _: *Gui, value: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        if (self.getNameFromId(id)) |field_name| {
            const ent_id = self.getSelId() orelse return;
            const kvs = self.getKvsPtr() orelse return;

            if (kvs.map.getPtr(field_name)) |ptr| {
                var floats = ptr.getFloats(4);
                floats[3] = std.fmt.parseFloat(f32, value) catch return;
                const ustack = self.editor.undoctx.pushNewFmt("Set brightness {s}: {d}", .{ field_name, floats[3] }) catch return;
                const old = kvs.getString(field_name) orelse "";
                ustack.append(.{ .set_kv = undo.UndoSetKeyValue.createFloats(
                    self.editor.undoctx.alloc,
                    ent_id,
                    field_name,
                    old,
                    4,
                    floats,
                ) catch return }) catch return;
                ustack.apply(self.editor);
            }
        }
    }

    fn setKvStr(self: *Self, field_id: usize, value: []const u8) void {
        if (self.getNameFromId(field_id)) |field_name| {
            const ustack = self.editor.undoctx.pushNewFmt("Set kv {s}:{s}", .{ field_name, value }) catch return;

            const ent_id = self.getSelId() orelse return;
            const kvs = self.getKvsPtr() orelse return;
            const old = kvs.getString(field_name) orelse "";
            ustack.append(.{ .set_kv = undo.UndoSetKeyValue.create(
                self.editor.undoctx.alloc,
                ent_id,
                field_name,
                old,
                value,
            ) catch return }) catch return;
            ustack.apply(self.editor);
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

    pub fn cb_commitColor(this_w: *CbHandle, _: *Gui, val: u32, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", this_w));
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
                ustack.append(.{ .set_kv = undo.UndoSetKeyValue.createFloats(
                    self.editor.undoctx.alloc,
                    ent_id,
                    field_name,
                    old,
                    4,
                    floats,
                ) catch return }) catch return;
                ustack.apply(self.editor);
            }
        }
    }

    pub fn cb_commitCheckbox(cb: *CbHandle, _: *Gui, val: bool, id: u64) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
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

    pub fn cb_commitTextbox(cb: *CbHandle, _: *Gui, string: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.setKvStr(id, string);
    }

    pub fn select_kv_cb(cb: *CbHandle, id: usize, _: guis.MouseCbState, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        win.needs_rebuild = true;
        self.selected_kv_index = id;
        //We need to rebuild buttons to show the selected mark
    }

    pub fn buildChoice(self: *@This(), info: anytype, area: ?Rect, vt: *iArea) void {
        //const ed = self.editor;
        const aa = area orelse return;
        const Lam = struct {
            fgd_class_index: usize,
            fgd_field_index: usize,

            fn commit(vtt: *CbHandle, id: usize, lam: @This()) void {
                const lself: *InspectorWindow = @alignCast(@fieldParentPtr("cbhandle", vtt));

                const fields = lself.editor.fgd_ctx.ents.items;
                const f = fields[lam.fgd_class_index];
                const fie = f.field_data.items[lam.fgd_field_index];

                lself.setKvStr(lam.fgd_field_index, fie.type.choices.items[id][0]);
            }

            fn name(vtt: *CbHandle, id: usize, _: *Gui, lam: @This()) []const u8 {
                const lself: *InspectorWindow = @alignCast(@fieldParentPtr("cbhandle", vtt));
                const class = lself.editor.fgd_ctx.ents.items[lam.fgd_class_index];
                const field = class.field_data.items[lam.fgd_field_index];
                if (field.type == .choices) {
                    if (id < field.type.choices.items.len)
                        return field.type.choices.items[id][1];
                }
                return "not a choice";
            }
        };
        _ = Wg.ComboUser(Lam).build(
            vt,
            aa,
            .{
                .user_vt = &self.cbhandle,
                .commit_cb = &Lam.commit,
                .name_cb = &Lam.name,
                .current = info.current,
                .count = info.count,
            },
            .{ .fgd_class_index = info.class_i, .fgd_field_index = info.field_i },
        );
    }

    fn buildIo(user_vt: *CbHandle, area_vt: *iArea, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", user_vt));
        const cons = self.getConsPtr() orelse return;
        _ = Wg.VScroll.build(area_vt, area_vt.area, .{
            .build_cb = &buildIoScrollCb,
            .build_vt = &self.cbhandle,
            .win = win,
            .count = cons.list.items.len,
            .item_h = gui.dstate.style.config.default_item_h,
            .index_ptr = &self.io_scroll_index,
        });
    }

    fn buildIoScrollCb(cb: *CbHandle, vt: *iArea, index: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.buildIoTab(vt.area, vt, index) catch return;
    }

    fn io_btn_cb(cb: *CbHandle, id: usize, _: guis.MouseCbState, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.selected_io_index = id;
        win.needs_rebuild = true;
    }

    fn buildIoTab(self: *@This(), area: Rect, lay: *iArea, index: usize) !void {
        const gui = lay.win_ptr.gui_ptr;
        const cons = self.getConsPtr() orelse return;
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
                .cb_vt = &self.cbhandle,
                .user_1 = if (self.selected_io_index == ind) 1 else 0,
            };
            const strs = [4][]const u8{ con.listen_event, con.target.items, con.input, con.value.items };
            //con.delay, con.fire_count };
            for (strs) |str|
                _ = Wg.Button.build(lay, tly.getArea(), str, opts);
            //TODO make these buttons too
            _ = Wg.Text.build(lay, tly.getArea(), "{d}", .{con.delay});
            _ = Wg.Text.build(lay, tly.getArea(), "{d}", .{con.fire_count});
        }
    }

    fn ioBtnCbAdd(cb: *CbHandle, _: usize, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
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

    fn ioTextboxCb(cb: *CbHandle, _: *Gui, string: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        const cons = self.getConsPtr() orelse return;
        if (self.selected_io_index >= cons.list.items.len) return;
        const con = &cons.list.items[self.selected_io_index];

        //Numbers are indexes into the table "names"
        switch (id) {
            1 => { //Target
                con.target.clearRetainingCapacity();
                con.target.appendSlice(con._alloc, string) catch return;
            },
            3 => {
                con.value.clearRetainingCapacity();
                con.value.appendSlice(con._alloc, string) catch return;
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

    pub fn buildOutputCombo(self: *@This(), lay: *iArea, aa: graph.Rect) void {
        const cons = self.getConsPtr() orelse return;
        if (self.selected_io_index >= cons.list.items.len) return;

        const Lam = struct {
            fn commit(vtt: *CbHandle, id: usize, _: void) void {
                const lself: *InspectorWindow = @alignCast(@fieldParentPtr("cbhandle", vtt));
                const lcons = lself.getConsPtr() orelse return;
                if (lself.selected_io_index >= lcons.list.items.len) return;

                const class = lself.getEntDef() orelse return;
                if (id >= class.outputs.items.len) return;
                const ind = class.outputs.items[id];
                const lname = class.io_data.items[ind].name;
                lcons.list.items[lself.selected_io_index].listen_event = lname;
            }

            fn name(vtt: *CbHandle, id: usize, _: *Gui, _: void) []const u8 {
                const lself: *InspectorWindow = @alignCast(@fieldParentPtr("cbhandle", vtt));
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

        _ = Wg.ComboUser(void).build(lay, aa, .{
            .user_vt = &self.cbhandle,
            .commit_cb = &Lam.commit,
            .name_cb = &Lam.name,
            .current = index,
            //.current = self.selected_class_id orelse 0,
            .count = class.outputs.items.len,
        }, {});
    }

    pub fn buildInputCombo(self: *@This(), lay: *iArea, aa: graph.Rect) void {
        const Lam = struct {
            fn commit(vtt: *CbHandle, id: usize, _: void) void {
                const lself = vtt.cast(InspectorWindow, "cbhandle");
                const lcons = lself.getConsPtr() orelse return;
                if (lself.selected_io_index >= lcons.list.items.len) return;

                const list = lself.editor.fgd_ctx.all_inputs.items;
                if (id >= list.len) return;
                lcons.list.items[lself.selected_io_index].input = list[id].name;
            }

            fn name(vtt: *CbHandle, id: usize, _: *Gui, _: void) []const u8 {
                const lself = vtt.cast(InspectorWindow, "cbhandle");
                const list = lself.editor.fgd_ctx.all_inputs.items;
                if (id >= list.len) return "BROKEN";
                return list[id].name;
            }
        };

        const cons = self.getConsPtr() orelse return;
        if (self.selected_io_index >= cons.list.items.len) return;
        const current_item = cons.list.items[self.selected_io_index].input;

        const index = if (self.editor.fgd_ctx.all_input_map.get(current_item)) |io| io else 0;
        _ = Wg.ComboUser(void).build(lay, aa, .{
            .user_vt = &self.cbhandle,
            .commit_cb = &Lam.commit,
            .name_cb = &Lam.name,
            .current = index,
            .count = self.editor.fgd_ctx.all_inputs.items.len,
        }, {});
    }

    pub fn selectedTextureWidget(self: *Self, lay: *iArea, area: graph.Rect) void {
        const ed = self.editor;
        const sp = area.split(.vertical, area.w / 2);
        if (ed.edit_state.selected_texture_vpk_id) |id| {
            const tt = ed.vpkctx.entries.get(id) orelse return;
            _ = ptext.PollingTexture.build(lay, sp[0], ed, id, "{s}/{s}", .{
                tt.path, tt.name,
            }, .{});
        }
        {
            const max = 16;
            var tly = guis.TableLayout{ .columns = 4, .item_height = sp[1].h / 4, .bounds = sp[1] };
            const recent_list = ed.asset_browser.recent_mats.list.items;
            for (recent_list[0..@min(max, recent_list.len)], 0..) |rec, id| {
                _ = ptext.PollingTexture.build(lay, tly.getArea(), ed, rec, "", .{}, .{
                    .cb_vt = &self.cbhandle,
                    .cb_fn = recent_texture_btn_cb,
                    .id = id,
                });
            }
        }
    }

    pub fn recent_texture_btn_cb(cb: *CbHandle, id: usize, _: guis.MouseCbState, _: *guis.iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        const asb = &self.editor.asset_browser;
        if (id >= asb.recent_mats.list.items.len) return;
        const missing = edit.missingTexture();
        const vpk_id = asb.recent_mats.list.items[id];
        const tex = self.editor.getTexture(vpk_id) catch return;
        if (tex.id == missing.id) return;
        self.editor.edit_state.selected_texture_vpk_id = vpk_id;
        self.vt.needs_rebuild = true;
    }
};

/// This should only be passed to Wg.Button !
pub fn customButtonDraw(vt: *iArea, _: *Gui, d: *DrawState) void {
    const self: *Wg.Button = @alignCast(@fieldParentPtr("vt", vt));
    d.ctx.rect(vt.area, 0xffff_ffff);
    if (self.opts.user_1 == 1) {
        const SELECTED_FIELD_COLOR = 0x6097dbff;
        d.ctx.rect(vt.area, SELECTED_FIELD_COLOR);
    }
    const ta = vt.area.inset(3 * d.scale);
    d.ctx.textClipped(ta, "{s}", .{self.text}, d.textP(0xff), .center);
}

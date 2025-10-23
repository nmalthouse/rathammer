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
const Layer = @import("../layer.zig");
const CbHandle = guis.CbHandle;

pub const PauseWindow = struct {
    const Buttons = enum {
        unpause,
        quit,
        force_autosave,
        new_map,
        pick_map,
        save_as,

        pub fn id(self: @This()) usize {
            return @intFromEnum(self);
        }
    };

    const Textboxes = enum {
        set_import_visgroup,
        set_skyname,
    };

    const HelpText = struct {
        text: []const u8,
        name: []const u8,
    };

    cbhandle: CbHandle = .{},
    vt: iWindow,

    editor: *Context,
    should_exit: bool = false,
    ent_select: u32 = 0,

    texts: std.ArrayList(HelpText),
    selected_text_i: usize = 0,

    tab_index: usize = 0,

    layer_widget: Layer.GuiWidget,

    pub fn create(gui: *Gui, editor: *Context, app_cwd: std.fs.Dir) !*PauseWindow {
        const self = gui.create(@This());
        self.* = .{
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, .{}, &self.vt),
            .editor = editor,
            .layer_widget = Layer.GuiWidget.init(&editor.layers, &editor.edit_state.selected_layer, editor, &self.vt),
            .texts = .{},
        };

        if (app_cwd.openDir("doc/en", .{ .iterate = true })) |doc_dir| {
            var dd = doc_dir;
            defer dd.close();
            var walker = try dd.walk(gui.alloc);
            defer walker.deinit();

            while (try walker.next()) |entry| {
                switch (entry.kind) {
                    .file => {
                        if (std.mem.endsWith(u8, entry.basename, ".txt")) {
                            var vec = std.ArrayList(u8){};
                            try vec.appendSlice(gui.alloc, entry.basename[0 .. entry.basename.len - 4]);

                            const text = try util.readFile(gui.alloc, entry.dir, entry.basename);

                            try self.texts.append(gui.alloc, .{ .text = text, .name = try vec.toOwnedSlice(gui.alloc) });
                        }
                    },
                    else => {},
                }
            }
            std.sort.insertion(HelpText, self.texts.items, {}, SortHelpText.lessThan);
        } else |_| {}

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        //self.layout.deinit(gui, vt);
        vt.deinit(gui);
        for (self.texts.items) |*text| {
            gui.alloc.free(text.text);
            gui.alloc.free(text.name);
        }
        self.texts.deinit(gui.alloc);
        gui.alloc.destroy(self); //second
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(vt: *iArea, _: *Gui, d: *DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
    }

    pub fn btnCb(cb: *CbHandle, id: usize, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        switch (@as(Buttons, @enumFromInt(id))) {
            .unpause => self.editor.paused = false,
            .quit => self.should_exit = true,
            .force_autosave => self.editor.autosaver.force = true,
            .new_map => {
                self.vt.needs_rebuild = true;
                const ed = self.editor;
                ed.initNewMap("sky_day01_01") catch {
                    std.debug.print("ERROR INIT NEW MAP\n", .{});
                };
                self.editor.paused = false;
            },
            .save_as => {
                self.vt.needs_rebuild = true;
                async_util.SdlFileData.spawn(self.editor.alloc, &self.editor.async_asset_load, .save_map) catch return;
            },
            .pick_map => {
                self.vt.needs_rebuild = true;
                async_util.SdlFileData.spawn(self.editor.alloc, &self.editor.async_asset_load, .pick_map) catch return;
            },
        }
    }

    pub fn commitCb(vt: *iArea, _: *Gui, _: []const u8, _: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("area", vt));
        self.editor.selection.setToSingle(@intCast(self.ent_select)) catch return;
    }

    pub fn build(vt: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        vt.area.area = area;
        vt.area.clearChildren(gui, vt);
        vt.area.dirty();
        const inset = GuiHelp.insetAreaForWindowFrame(gui, vt.area.area);
        _ = vt.area.addEmpty(graph.Rec(0, 0, 0, 0));

        _ = Wg.Tabs.build(&vt.area, inset, &.{
            "main",
            "keybinds",
            "graphics",
            "mapprops",
        }, vt, .{ .build_cb = &buildTabs, .cb_vt = &self.cbhandle, .index_ptr = &self.tab_index });
    }

    fn buildTabs(win_vt: *CbHandle, vt: *iArea, tab: []const u8, gui: *Gui, win: *iWindow) void {
        const self = win_vt.cast(@This(), "cbhandle");
        const eql = std.mem.eql;
        const St = Wg.StaticSlider.build;
        if (eql(u8, tab, "keybinds")) {
            const info = @typeInfo(@TypeOf(self.editor.config.keys));
            var ly = gui.dstate.vlayout(vt.area);
            var buf: [64]u8 = undefined;
            inline for (info.@"struct".fields) |field| {
                const key = @field(self.editor.config.keys, field.name);
                if (@TypeOf(key) == Config.Keybind) {
                    _ = Wg.Text.build(vt, ly.getArea(), "{s}: {s}", .{
                        field.name,
                        key.b.nameFull(&buf),
                    });
                }
            }
        }
        if (eql(u8, tab, "mapprops")) {
            var ly = gui.dstate.vlayout(vt.area);
            if (guis.label(vt, ly.getArea(), "Set skybox: ", .{})) |ar|
                _ = Wg.Textbox.buildOpts(vt, ar, .{
                    .init_string = "",
                    .commit_cb = &textbox_cb,
                    .commit_vt = &self.cbhandle,
                    .user_id = @intFromEnum(Textboxes.set_skyname),
                });
        }
        if (eql(u8, tab, "graphics")) {
            var ly = gui.dstate.vlayout(vt.area);
            const ps = &self.editor.draw_state.planes;
            const ed = self.editor;
            const max = 512 * 64;
            if (guis.label(vt, ly.getArea(), "p0", .{})) |ar|
                _ = St(vt, ar, &ps[0], .{ .min = 0.1, .max = max, .default = 462 });
            if (guis.label(vt, ly.getArea(), "p1", .{})) |ar|
                _ = St(vt, ar, &ps[1], .{ .min = 0.1, .max = max, .default = 1300 });
            if (guis.label(vt, ly.getArea(), "p2", .{})) |ar|
                _ = St(vt, ar, &ps[2], .{ .min = 0.1, .max = max, .default = 4200 });
            if (guis.label(vt, ly.getArea(), "p3", .{})) |ar|
                _ = St(vt, ar, &ps[3], .{ .min = 4096, .max = max, .default = 16400 });
            if (guis.label(vt, ly.getArea(), "pad", .{})) |ar|
                _ = Wg.Slider.build(vt, ar, &ed.draw_state.pad, 1, 4096, .{});
            if (guis.label(vt, ly.getArea(), "index", .{})) |ar|
                _ = Wg.Slider.build(vt, ar, &ed.draw_state.index, 0, 5, .{});
            if (guis.label(vt, ly.getArea(), "gamma", .{})) |ar|
                _ = St(vt, ar, &ed.renderer.gamma, .{ .min = 0.1, .max = 3, .default = 1.45, .slide = .{ .snap = 0.1 } });
            if (guis.label(vt, ly.getArea(), "exposure", .{})) |ar|
                _ = St(vt, ar, &ed.renderer.exposure, .{ .min = 0.1, .max = 10, .default = 1, .slide = .{ .snap = 0.1 } });
            if (guis.label(vt, ly.getArea(), "pitch", .{})) |ar|
                _ = St(vt, ar, &ed.renderer.pitch, .{ .min = 0, .max = 90, .default = -30 });
            if (guis.label(vt, ly.getArea(), "yaw", .{})) |ar|
                _ = St(vt, ar, &ed.renderer.yaw, .{ .min = 0, .max = 360, .default = 0 });
            if (guis.label(vt, ly.getArea(), "lightMul", .{})) |ar|
                _ = St(vt, ar, &ed.draw_state.light_mul, .{ .min = 0.01, .max = 1, .default = 0.11 });
            if (guis.label(vt, ly.getArea(), "const add", .{})) |ar|
                _ = St(vt, ar, &ed.draw_state.const_add, .{ .min = -1, .max = 1, .default = 0 });
            if (guis.label(vt, ly.getArea(), "ambient scale", .{})) |ar|
                _ = St(vt, ar, &ed.renderer.ambient_scale, .{ .min = -10, .max = 100, .default = 1 });
            if (guis.label(vt, ly.getArea(), "res scale", .{})) |ar|
                _ = Wg.StaticSlider.build(vt, ar, &ed.renderer.res_scale, .{
                    .min = 0.1,
                    .max = 1,
                    .default = 1,
                    .slide = .{ .snap = 0.1 },
                });
            if (guis.label(vt, ly.getArea(), "light render dist", .{})) |ar|
                _ = Wg.StaticSlider.build(vt, ar, &ed.renderer.light_render_dist, .{
                    .min = 16,
                    .max = 4096,
                    .default = 1024,
                    .slide = .{ .snap = 64 },
                });
            if (guis.label(vt, ly.getArea(), "Gui Tint", .{})) |ar|
                _ = Wg.Colorpicker.build(vt, ar, gui.dstate.tint, .{
                    .commit_vt = &self.cbhandle,
                    .commit_cb = &commitColor,
                });

            _ = Wg.Checkbox.build(vt, ly.getArea(), "draw skybox", .{ .bool_ptr = &ed.draw_state.tog.skybox }, null);
            _ = Wg.Checkbox.build(vt, ly.getArea(), "lighting", .{ .bool_ptr = &ed.renderer.do_lighting }, null);
            _ = Wg.Checkbox.build(vt, ly.getArea(), "copy depth", .{ .bool_ptr = &ed.renderer.copy_depth }, null);
            _ = Wg.Checkbox.build(vt, ly.getArea(), "light debug", .{ .bool_ptr = &ed.renderer.debug_light_coverage }, null);
            _ = Wg.Checkbox.build(vt, ly.getArea(), "do hdr", .{ .bool_ptr = &ed.renderer.do_hdr_buffer }, null);
            _ = Wg.Checkbox.build(vt, ly.getArea(), "Draw outline", .{ .bool_ptr = &ed.draw_state.draw_outlines }, null);
            _ = Wg.Checkbox.build(vt, ly.getArea(), "Draw displacement solid", .{ .bool_ptr = &ed.draw_state.draw_displacment_solid }, null);
            if (guis.label(vt, ly.getArea(), "far clip", .{})) |ar|
                _ = St(vt, ar, &ed.draw_state.cam_far_plane, .{ .min = 512 * 64, .max = 512 * 512, .default = 512 * 64, .slide = .{ .snap = 64 } });
            if (guis.label(vt, ly.getArea(), "near clip", .{})) |ar|
                _ = St(vt, ar, &ed.draw_state.cam_near_plane, .{ .min = 1, .max = 512, .default = 1, .slide = .{ .snap = 1 } });
        }
        if (eql(u8, tab, "main")) {
            var ly = gui.dstate.vlayout(vt.area);
            ly.padding.left = 10;
            ly.padding.right = 10;
            ly.padding.top = 10;

            const Btn = Wg.Button.build;
            const ds = &self.editor.draw_state;
            if (self.editor.has_loaded_map) {
                {
                    var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 2 };
                    _ = Btn(vt, hy.getArea(), "Unpause", .{ .cb_fn = &btnCb, .id = Buttons.id(.unpause), .cb_vt = &self.cbhandle });
                    _ = Btn(vt, hy.getArea(), "save as", .{ .cb_fn = &btnCb, .id = Buttons.id(.save_as), .cb_vt = &self.cbhandle });
                }
                {
                    var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 3 };
                    if (guis.label(vt, hy.getArea(), "Import under visgroup: ", .{})) |ar|
                        _ = Wg.Textbox.buildOpts(vt, ar, .{
                            .init_string = self.editor.hacky_extra_vmf.override_vis_group orelse "",
                            .commit_cb = &textbox_cb,
                            .commit_vt = &self.cbhandle,
                            .user_id = @intFromEnum(Textboxes.set_import_visgroup),
                        });
                    _ = Btn(vt, hy.getArea(), "Import vmf", .{ .cb_fn = &btnCb, .id = Buttons.id(.pick_map), .cb_vt = &self.cbhandle });
                }
            } else {
                var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 2 };
                _ = Btn(vt, hy.getArea(), "New map", .{ .cb_fn = &btnCb, .id = Buttons.id(.new_map), .cb_vt = &self.cbhandle });
                _ = Btn(vt, hy.getArea(), "Load map", .{ .cb_fn = &btnCb, .id = Buttons.id(.pick_map), .cb_vt = &self.cbhandle });
            }

            if (false) {
                var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 4 };
                _ = Wg.Checkbox.build(vt, hy.getArea(), "draw sprite", .{ .bool_ptr = &ds.tog.sprite }, null);
                _ = Wg.Checkbox.build(vt, hy.getArea(), "draw models", .{ .bool_ptr = &ds.tog.models }, null);
                _ = Wg.Checkbox.build(vt, hy.getArea(), "ignore groups", .{ .bool_ptr = &self.editor.selection.ignore_groups }, null);
            }

            if (guis.label(vt, ly.getArea(), "Camera move kind", .{})) |ar|
                _ = Wg.Combo.build(vt, ar, &ds.cam3d.fwd_back_kind, .{});
            if (guis.label(vt, ly.getArea(), "renderer", .{})) |ar|
                _ = Wg.Combo.build(vt, ar, &self.editor.renderer.mode, .{});
            if (guis.label(vt, ly.getArea(), "New group type", .{})) |ar|
                _ = Wg.Combo.build(vt, ar, &self.editor.edit_state.default_group_entity, .{});
            if (guis.label(vt, ly.getArea(), "Entity render distance", .{})) |ar|
                _ = St(vt, ar, &ds.tog.model_render_dist, .{ .min = 64, .max = 1024 * 10, .default = 1024 });
            if (false) {
                var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 2 };
                _ = Wg.Slider.build(vt, hy.getArea(), &ds.cam_near_plane, 1, 512, .{ .nudge = 1 });
                _ = Wg.Slider.build(vt, hy.getArea(), &ds.cam_far_plane, 512 * 64, 512 * 512, .{ .nudge = 1 });
            }

            //ly.pushHeight(Wg.TextView.heightForN(gui, 4));
            ly.pushRemaining();
            const help_area = ly.getArea() orelse return;
            const sp = help_area.split(.vertical, gui.dstate.style.config.text_h * 9);

            if (self.selected_text_i < self.texts.items.len) {
                _ = Wg.TextView.build(vt, sp[1], &.{self.texts.items[self.selected_text_i].text}, win, .{
                    .mode = .split_on_space,
                });
            }

            _ = Wg.VScroll.build(vt, sp[0], .{
                .build_cb = &buildHelpScroll,
                .build_vt = &self.cbhandle,
                .win = win,
                .count = self.texts.items.len,
                .item_h = ly.item_height,
            });
        }
    }

    pub fn btn_help_cb(cb: *CbHandle, id: usize, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        if (id >= self.texts.items.len) return;
        self.selected_text_i = id;
        self.vt.needs_rebuild = true;
    }

    pub fn textbox_cb(cb: *guis.CbHandle, _: *Gui, string: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));

        const str = self.editor.storeString(string) catch return;
        switch (@as(Textboxes, @enumFromInt(id))) {
            .set_skyname => {
                self.editor.skybox.loadSky(str, &self.editor.vpkctx) catch return;
            },
            .set_import_visgroup => {
                self.editor.hacky_extra_vmf.override_vis_group = str;
            },
        }
    }

    pub fn buildHelpScroll(cb: *CbHandle, vt: *iArea, index: usize) void {
        const gui = vt.win_ptr.gui_ptr;
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        var ly = gui.dstate.vlayout(vt.area);
        if (index >= self.texts.items.len) return;
        for (self.texts.items[index..], index..) |text, i| {
            _ = Wg.Button.build(vt, ly.getArea(), text.name[3..], .{
                .custom_draw = &Wg.Button.customButtonDraw_listitem,
                .id = i,
                .cb_fn = &btn_help_cb,
                .cb_vt = &self.cbhandle,
                .user_1 = if (self.selected_text_i == i) 1 else 0,
            });
        }
    }

    pub fn commitColor(window_area: *CbHandle, gui: *Gui, color: u32, _: usize) void {
        _ = window_area;
        gui.dstate.tint = color;
    }

    pub fn checkbox_cb_auto_vis(user: *iArea, _: *Gui, val: bool, id: usize) void {
        const self: *PauseWindow = @alignCast(@fieldParentPtr("area", user));
        if (id >= self.editor.autovis.enabled.items.len) return;
        self.editor.autovis.enabled.items[id] = val;
        self.editor.rebuildAutoVis() catch return;
    }
};

fn buildVisGroups(self: *PauseWindow, gui: *Gui, area: *iArea, ar: graph.Rect) void {
    const Helper = struct {
        fn recur(vs: void, vg: void.Group, depth: usize, gui_: *Gui, vl: *guis.VerticalLayout, vt: *iArea, win: *iWindow) void {
            vl.padding.left = @floatFromInt(depth * 20);
            const the_bool = !vs.disabled.isSet(vg.id);

            var hy = guis.HorizLayout{ .bounds = vl.getArea() orelse return, .count = 2 };
            _ = Wg.Checkbox.build(
                vt,
                hy.getArea(),
                vg.name,
                .{ .cb_fn = &commit_cb, .cb_vt = win.area, .user_id = vg.id },
                the_bool,
            );

            _ = Wg.Button.build(vt, hy.getArea(), "Select", .{
                .cb_fn = &select_all_vis,
                .cb_vt = win.area,
                .id = vg.id,
            });

            for (vg.children.items) |id| {
                recur(
                    vs,
                    &vs.groups.items[id],
                    depth + 2,
                    gui_,
                    vl,
                    vt,
                    win,
                );
            }
        }

        fn commit_cb(user: *iArea, _: *Gui, val: bool, id: usize) void {
            const selfl: *PauseWindow = @alignCast(@fieldParentPtr("area", user));
            if (id > 55) return;
            selfl.editor.visgroups.setValueCascade(@intCast(id), val);
            selfl.editor.rebuildVisGroups() catch return;
            selfl.vt.needs_rebuild = true;
        }

        fn select_all_vis(user: *iArea, id: usize, _: *Gui, _: *iWindow) void {
            const selfl: *PauseWindow = @alignCast(@fieldParentPtr("area", user));
            selfl.editor.selection.setToMulti();
            const mask = selfl.editor.visgroups.getMask(&.{@as(u8, @intCast(id))});
            var it = selfl.editor.ecs.iterator(.editor_info);
            while (it.next()) |item| {
                if (mask.subsetOf(item.vis_mask))
                    selfl.editor.selection.addUnchecked(it.i) catch return;
            }
        }
    };
    var ly = gui.dstate.vlayout(ar);

    if (self.editor.visgroups.getRoot()) |vg| {
        Helper.recur(&self.editor.visgroups, vg, 0, gui, &ly, area, &self.vt);
    }
}

pub const SortHelpText = struct {
    pub fn lessThan(_: void, a: PauseWindow.HelpText, b: PauseWindow.HelpText) bool {
        if (a.name.len < 3 or b.name.len < 3) return false;

        const an = std.fmt.parseInt(u32, a.name[0..3], 10) catch return false;
        const bn = std.fmt.parseInt(u32, b.name[0..3], 10) catch return true;
        return an < bn;
    }
};

const std = @import("std");
const graph = @import("graph");
const vpk = @import("vpk.zig");
const Os9Gui = graph.gui_app.Os9Gui;
const guiutil = graph.gui_app;
const Vec3 = graph.za.Vec3;
const edit = @import("editor.zig");
const Config = @import("config.zig");
const ecs = @import("ecs.zig");
const Gui = graph.Gui;
const guis = graph.RGui;
const RGui = guis.Gui;
//TODO center camera view on model on new model load

pub const DialogState = struct {
    target_id: ecs.EcsT.Id,

    previous_pane_index: usize,

    kind: enum { texture, model },
};

pub const RecentsList = struct {
    max: usize = 16,
    alloc: std.mem.Allocator,
    list: std.ArrayListUnmanaged(vpk.VpkResId) = .{},

    pub fn init(alloc: std.mem.Allocator, max: usize) @This() {
        return .{
            .alloc = alloc,
            .max = max,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.list.deinit(self.alloc);
    }

    pub fn append(self: *@This(), id: vpk.VpkResId) !void {
        try self.list.append(self.alloc, id);
    }

    pub fn put(self: *@This(), id: vpk.VpkResId) !void {
        for (self.list.items, 0..) |item, index| {
            if (item == id) {
                _ = self.list.orderedRemove(index);
                break;
            }
        }

        try self.list.insert(self.alloc, 0, id);
        if (self.list.items.len > self.max)
            try self.list.resize(self.alloc, self.max);
    }
};

const log = std.log.scoped(.asset_browser);
pub const AssetBrowserGui = struct {
    const Self = @This();
    const IdVec = std.ArrayList(vpk.VpkResId);

    /// These are populated at init then left const
    model_list: IdVec,
    mat_list: IdVec,

    model_list_sub: IdVec,
    mat_list_sub: IdVec,

    model_search: Os9Gui.DynamicTextbox,
    mat_search: Os9Gui.DynamicTextbox,

    num_texture_column: usize = 10,
    start_index_model: usize = 0,
    start_index_mat: usize = 0,

    model_needs_rebuild: bool = true,
    mat_needs_rebuild: bool = true,

    //TODO when narrowing a search, make sure selected index lies within it
    selected_model_vpk_id: ?vpk.VpkResId = null,
    selected_index_model: usize = 0,
    selected_index_mat: usize = 0,
    selected_mat_vpk_id: ?vpk.VpkResId = null,

    min_column: i32 = 1,
    max_column: i32 = 10,
    name_buf: std.ArrayList(u8),

    hide_missing: bool = false,

    model_cam: graph.Camera3D = .{ .pos = Vec3.new(0, -100, 0), .up = .z, .move_speed = 20 },

    dialog_state: ?DialogState = null,

    recent_mats: RecentsList,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .recent_mats = RecentsList.init(alloc, 16),
            .name_buf = std.ArrayList(u8).init(alloc),
            .model_list = IdVec.init(alloc),
            .mat_list = IdVec.init(alloc),
            .model_list_sub = IdVec.init(alloc),
            .mat_list_sub = IdVec.init(alloc),
            .model_search = Os9Gui.DynamicTextbox.init(alloc),
            .mat_search = Os9Gui.DynamicTextbox.init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.recent_mats.deinit();
        self.model_list.deinit();
        self.mat_list.deinit();
        self.model_list_sub.deinit();
        self.mat_list_sub.deinit();
        self.model_search.deinit();
        self.mat_search.deinit();
        self.name_buf.deinit();
    }

    pub fn applyDialogState(self: *Self, editor: *edit.Context) !void {
        defer self.dialog_state = null;
        if (self.dialog_state) |ds| {
            switch (ds.kind) {
                .model => {
                    const mid = self.selected_model_vpk_id orelse return;
                    if (try editor.ecs.getOptPtr(ds.target_id, .entity)) |ent| {
                        try ent.setModel(editor, ds.target_id, .{ .id = mid }, false);
                    }
                    //To set the model, first change the kv,
                    //then set ent._model_id
                },
                .texture => {
                    const tid = self.selected_mat_vpk_id orelse return;
                    if (try editor.ecs.getOptPtr(ds.target_id, .key_values)) |ent| {
                        if (try editor.vpkctx.resolveId(.{ .id = tid }, false)) |idd| {
                            //var name = idd.name;
                            //if (std.mem.startsWith(u8, name, "materials/"))
                            //    name = idd.name["materials/".len..];
                            try ent.putString(editor, ds.target_id, "texture", idd.name);
                        }
                    }
                },
            }

            editor.draw_state.tab_index = ds.previous_pane_index;
        }
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
                try self.mat_list.append(item.key_ptr.*);
            } else if (id == mdl) {
                try self.model_list.append(item.key_ptr.*);
            } else if (id == png) {
                try self.mat_list.append(item.key_ptr.*);
            }
        }
        log.info("excluded {d} materials", .{excluded});
    }

    pub fn drawModelPreview(
        self: *Self,
        win: *graph.SDL.Window,
        pane_area: graph.Rect,
        cam_state: graph.ptypes.Camera3D.MoveState,
        editor: *edit.Context,
        draw: *graph.ImmediateDrawingContext,
    ) !void {
        const selected_mod = self.selected_model_vpk_id orelse return;
        const sp = pane_area;
        self.model_cam.updateDebugMove(if (win.mouse.left == .high) cam_state else .{});
        const screen_area = pane_area;
        const x: i32 = @intFromFloat(screen_area.x);
        const y: i32 = @intFromFloat(screen_area.y);
        const w: i32 = @intFromFloat(screen_area.w);
        const h: i32 = @intFromFloat(screen_area.h);

        graph.c.glViewport(x, y, w, h);
        graph.c.glScissor(x, y, w, h);
        graph.c.glEnable(graph.c.GL_SCISSOR_TEST);
        defer graph.c.glDisable(graph.c.GL_SCISSOR_TEST);
        //todo
        //defer loading of all textures

        self.name_buf.clearRetainingCapacity();
        //try name_buf.writer().print("models/{s}/{s}.mdl", .{ modname[0], modname[1] });
        //draw.cube(Vec3.new(0, 0, 0), Vec3.new(10, 10, 10), 0xffffffff);
        if (editor.models.get(selected_mod)) |mod| {
            if (mod.mesh) |mm| {
                const view = self.model_cam.getMatrix(sp.w / sp.h, 1, 64 * 512);
                const mat = graph.za.Mat4.identity();
                mm.drawSimple(view, mat, editor.draw_state.basic_shader);
            }
        } else {
            if (editor.vpkctx.entries.get(selected_mod)) |tt| {
                try self.name_buf.writer().print("{s}/{s}.mdl", .{ tt.path, tt.name });
                _ = try editor.loadModel(self.name_buf.items);
            }
        }
        try draw.flush(null, self.model_cam);
    }

    pub fn drawEditWindow(
        self: *Self,
        screen_area: graph.Rect,
        os9gui: *Os9Gui,
        editor: *edit.Context,
        tab: enum { model, texture },
    ) !void {
        const should_focus_tb = os9gui.gui.isBindState(editor.config.keys.focus_search.b, .rising);
        if (try os9gui.beginTlWindow(screen_area)) {
            defer os9gui.endTlWindow();

            switch (tab) {
                .model => {
                    if (self.model_needs_rebuild) {
                        self.start_index_model = 0;
                        self.model_needs_rebuild = false;
                        self.model_list_sub.clearRetainingCapacity();
                        const io = std.mem.indexOf;
                        const search = self.model_search.arraylist.items;
                        for (self.model_list.items) |item| {
                            //models
                            //vehicle
                            //
                            //models/vehicle
                            //
                            //vehicle_rich
                            const tt = editor.vpkctx.entries.get(item) orelse continue;
                            if (io(u8, tt.name, search) != null or io(u8, tt.path, search) != null or
                                (io(u8, search, tt.name) != null and io(u8, search, tt.path) != null))
                                try self.model_list_sub.append(item);
                        }
                    }
                    const vl = try os9gui.beginV();
                    vl.padding.top = 0;
                    vl.padding.bottom = 0;
                    defer os9gui.endL();
                    os9gui.sliderEx(&self.start_index_model, 0, self.model_list.items.len, "", .{});
                    {
                        _ = try os9gui.beginH(3);
                        defer os9gui.endL();
                        const len = self.model_search.arraylist.items.len;
                        try os9gui.textbox2(&self.model_search, .{ .make_active = should_focus_tb, .make_inactive = os9gui.gui.isKeyDown(.RETURN) });
                        os9gui.label("Results {d}", .{self.model_list_sub.items.len});
                        if (len != self.model_search.arraylist.items.len)
                            self.model_needs_rebuild = true;

                        if (os9gui.button("Accept")) {
                            try self.applyDialogState(editor);
                        }
                    }
                    var moved_with_keyboard = false;
                    if (os9gui.gui.isBindState(editor.config.keys.down_line.b, .rising)) {
                        self.selected_index_model += 1;
                        moved_with_keyboard = true;
                    }

                    if (os9gui.gui.isBindState(editor.config.keys.up_line.b, .rising) and self.selected_index_model > 0) {
                        self.selected_index_model -= 1;
                        moved_with_keyboard = true;
                    }

                    vl.pushRemaining();
                    if (try os9gui.beginIndexedVScroll(self.model_list_sub.items.len, &self.start_index_model, .{})) |_| {
                        defer os9gui.endIndexedVScroll();
                        self.start_index_model = @min(self.model_list_sub.items.len, self.start_index_model);
                        self.selected_index_model = std.math.clamp(self.selected_index_model, self.start_index_model, self.model_list_sub.items.len - 1);
                        for (self.model_list_sub.items[self.start_index_model..], self.start_index_model..) |model, i| {
                            const tt = editor.vpkctx.entries.get(model) orelse continue;
                            if (os9gui.buttonEx("{s}/{s}", .{ tt.path, tt.name }, .{ .disabled = self.selected_index_model == i }))
                                self.selected_index_model = i;
                            if (self.selected_index_model == i)
                                self.selected_model_vpk_id = model;
                            if (os9gui.gui.layout.last_requested_bounds == null) {
                                if (moved_with_keyboard) {
                                    const pad = 5;
                                    const ii: i64 = @intCast(i);
                                    const sm: i64 = @intCast(self.selected_index_model);
                                    const start: i64 = @intCast(self.start_index_model);
                                    if (sm - pad < start) {
                                        self.start_index_model = @max(0, (sm - pad));
                                    } else if (sm + pad > ii) {
                                        //j = (sm + pad ) - ii
                                        self.start_index_model += @max(0, (sm + pad) - ii);
                                    }
                                }
                                break;
                            }
                        }
                    }
                },
                .texture => {
                    if (self.mat_needs_rebuild) {
                        self.start_index_mat = 0;
                        self.mat_needs_rebuild = false;
                        self.mat_list_sub.clearRetainingCapacity();
                        const io = std.mem.indexOf;
                        for (self.mat_list.items) |item| {
                            const tt = editor.vpkctx.entries.get(item) orelse continue;
                            if (io(u8, tt.path, self.mat_search.arraylist.items) != null or io(u8, tt.name, self.mat_search.arraylist.items) != null)
                                try self.mat_list_sub.append(item);
                        }
                    }

                    const vl = try os9gui.beginV();
                    defer os9gui.endL();
                    self.start_index_mat = @min(self.start_index_mat, self.mat_list_sub.items.len);
                    const max_scroll = @divFloor(self.mat_list_sub.items.len, self.num_texture_column);
                    os9gui.sliderEx(&self.start_index_mat, 0, max_scroll, "", .{});
                    os9gui.sliderEx(&self.num_texture_column, 1, self.max_column, "num column", .{});
                    const len = self.mat_search.arraylist.items.len;
                    {
                        _ = try os9gui.beginH(4);
                        defer os9gui.endL();
                        try os9gui.textbox2(&self.mat_search, .{ .make_active = should_focus_tb });
                        os9gui.label("Results {d}", .{self.mat_list_sub.items.len});
                        _ = os9gui.checkbox("Hide missing", &self.hide_missing);
                        if (os9gui.button("Accept")) {
                            try self.applyDialogState(editor);
                        }
                    }

                    if (len != self.mat_search.arraylist.items.len)
                        self.mat_needs_rebuild = true;
                    //const ar = os9gui.gui.getArea() orelse graph.Rec(0, 0, 0, 0);
                    vl.pushRemaining();
                    const scroll_area = os9gui.gui.getArea() orelse return error.broken;
                    os9gui.gui.draw9Slice(scroll_area, os9gui.style.getRect(.basic_inset), os9gui.style.texture, os9gui.scale);
                    const ins = scroll_area.inset(3 * os9gui.scale);
                    var index: i32 = @intCast(self.start_index_mat);
                    const md: i32 = @intFromFloat(os9gui.gui.getMouseWheelDelta() orelse 0);
                    const res_per_page = 4;
                    if (os9gui.gui.isKeyDown(.LCTRL)) {
                        var nc: i32 = @intCast(self.num_texture_column);
                        nc += md;
                        self.num_texture_column = @intCast(std.math.clamp(
                            nc,
                            self.min_column,
                            self.max_column,
                        ));
                    } else {
                        index += md * res_per_page;
                    }
                    const nc: f32 = @floatFromInt(self.num_texture_column);
                    self.start_index_mat = @intCast(std.math.clamp(
                        index,
                        0,
                        @as(i32, @intCast(max_scroll)),
                    ));

                    _ = try os9gui.gui.beginLayout(Gui.SubRectLayout, .{ .rect = ins }, .{ .scissor = ins });
                    defer os9gui.gui.endLayout();

                    _ = try os9gui.beginL(Gui.TableLayout{
                        .columns = @intCast(self.num_texture_column),
                        .item_height = ins.w / nc,
                    });
                    defer os9gui.endL();
                    const acc_ind = @min(self.start_index_mat * self.num_texture_column, self.mat_list_sub.items.len);
                    const missing = edit.missingTexture();
                    for (self.mat_list_sub.items[acc_ind..], acc_ind..) |model, i| {
                        const tex = try editor.getTexture(model);
                        if (self.hide_missing and tex.id == missing.id) {
                            continue;
                        }
                        const area = os9gui.gui.getArea() orelse break;
                        const text_h = area.h / 8;
                        const click = os9gui.gui.clickWidget(area);
                        if (click == .click) {
                            self.selected_index_mat = i;
                            self.selected_mat_vpk_id = model;
                            try self.recent_mats.put(model);
                        }
                        //os9gui.gui.drawRectFilled(area, 0xffff);
                        os9gui.gui.drawRectTextured(area, 0xffffffff, tex.rect(), tex);
                        const tr = graph.Rec(area.x, area.y + area.h - text_h, area.w, text_h);
                        os9gui.gui.drawRectFilled(tr, 0xff);
                        const tt = editor.vpkctx.entries.get(model) orelse continue;
                        os9gui.gui.drawTextFmt(
                            "{s}/{s}",
                            .{ tt.path, tt.name },
                            tr,
                            20,
                            //text_h,
                            0xffffffff,
                            .{},
                            os9gui.font,
                        );
                        if (self.selected_index_mat == i) {
                            os9gui.gui.drawRectOutline(area, 0x00ff00ff);
                        }
                        //os9gui.label("{s}/{s}", .{ model[0], model[1] });
                    }
                },
            }
            //os9gui.endTabs();
        }
    }
};

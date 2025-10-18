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
const Wg = guis.Widget;
const Context = @import("../editor.zig").Context;
pub const exec_command_cb = *const fn (
    *ConsoleCb,
    command_string: []const u8,
    output: *std.ArrayList(u8),
) void;

pub const ConsoleCb = struct {
    exec: exec_command_cb,
};

pub const Console = struct {
    const Self = @This();
    vt: iWindow,
    cbhandle: guis.CbHandle = .{},
    area: iArea,

    line_arena: std.heap.ArenaAllocator,
    lines: std.ArrayList([]const u8),
    scratch: std.ArrayList(u8),

    exec_vt: *ConsoleCb,

    pub fn create(gui: *Gui, editor: *Context, exec_vt: *ConsoleCb) !*Console {
        _ = editor;
        const self = gui.create(@This());

        self.* = .{
            .area = .{ .area = Rec(0, 0, 0, 0), .deinit_fn = area_deinit },
            .vt = iWindow.init(&build, gui, &deinit, &self.area),
            .lines = std.ArrayList([]const u8).init(gui.alloc),
            .line_arena = std.heap.ArenaAllocator.init(gui.alloc),
            .scratch = std.ArrayList(u8).init(gui.alloc),
            .exec_vt = exec_vt,
        };

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        vt.deinit(gui);
        self.lines.deinit();
        self.line_arena.deinit();
        self.scratch.deinit();
        gui.alloc.destroy(self);
    }

    fn getTextView(self: *@This()) ?*Wg.TextView {
        if (self.area.children.items.len != 2) return null;
        const tv: *Wg.TextView = @alignCast(@fieldParentPtr("vt", self.area.children.items[1]));
        return tv;
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn build(vt: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.area.area = area;
        self.area.clearChildren(gui, vt);
        self.area.dirty(gui);
        const inset = GuiHelp.insetAreaForWindowFrame(gui, area);
        const item_height = gui.dstate.style.config.default_item_h;
        const sp = inset.split(.horizontal, inset.h - item_height);
        const text_area = sp[0];
        const command = sp[1];

        self.area.addChildOpt(gui, vt, Wg.Textbox.buildOpts(gui, command, .{
            .init_string = "",
            .commit_cb = &textbox_cb,
            .commit_vt = &self.cbhandle,
            .user_id = 0,
            .clear_on_commit = true,
            .restricted_charset = "`",
            .invert_restriction = true,
        }));
        if (self.area.children.items.len > 0) {
            gui.grabFocus(self.area.children.items[0], vt);
        }

        self.area.addChildOpt(gui, vt, Wg.TextView.build(gui, text_area, self.lines.items, vt, .{
            .mode = .split_on_space,
            .force_scroll = true,
        }));
    }

    pub fn focus(self: *@This(), gui: *Gui) void {
        if (self.area.children.items.len > 0) {
            gui.grabFocus(self.area.children.items[0], &self.vt);
        }
    }

    pub fn execCommand(self: *@This(), command: []const u8, gui: *Gui) void {
        self.scratch.clearRetainingCapacity();
        self.exec_vt.exec(self.exec_vt, command, &self.scratch);
        const duped = self.line_arena.allocator().dupe(u8, self.scratch.items) catch return;
        self.lines.append(duped) catch return;
        var tv = self.getTextView() orelse return;
        tv.addOwnedText(duped, gui) catch return;
        tv.gotoBottom();
        tv.rebuildScroll(gui, gui.getWindow(&self.area) orelse return);
    }

    pub fn textbox_cb(cb: *guis.CbHandle, gui: *Gui, string: []const u8, _: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.execCommand(string, gui);
    }

    pub fn draw(vt: *iArea, d: DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
    }
};

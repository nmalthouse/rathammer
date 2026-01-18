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
const Readline = @import("../readline.zig");
const Context = @import("../editor.zig").Context;
const shell = @import("../shell.zig");
const app = @import("../app.zig");

pub const exec_command_cb = *const fn (
    *ConsoleCb,
    command_string: []const u8,
    output: *std.array_list.Managed(u8),
) void;

pub const ConsoleCb = struct {
    exec: exec_command_cb,
};

pub const Console = struct {
    const Self = @This();
    vt: iWindow,
    cbhandle: guis.CbHandle = .{},

    alloc: std.mem.Allocator,
    line_arena: std.heap.ArenaAllocator,
    lines: std.ArrayList([]const u8),
    scratch: std.array_list.Managed(u8),

    readline: Readline,

    exec_vt: *ConsoleCb,
    ev_vt: app.iEvent = .{ .cb = event_cb },

    pub fn create(gui: *Gui, editor: *Context, exec_vt: *ConsoleCb) !*Console {
        const self = gui.create(@This());

        self.* = .{
            .vt = iWindow.init(&build, gui, &deinit, .{}, &self.vt),
            .lines = .{},
            .line_arena = std.heap.ArenaAllocator.init(gui.alloc),
            .scratch = .init(gui.alloc),
            .exec_vt = exec_vt,
            .alloc = gui.alloc,
            .readline = .init(gui.alloc),
        };

        if (editor.eventctx.registerListener(&self.ev_vt)) |listener| {
            editor.eventctx.subscribe(listener, @intFromEnum(app.EventKind.notify)) catch {};
        } else |_| {}

        inline for (@typeInfo(shell.Commands).@"enum".fields) |field| {
            try self.readline.addComplete(field.name);
        }

        return self;
    }

    pub fn deinit(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        vt.deinit(gui);
        self.lines.deinit(self.alloc);
        self.line_arena.deinit();
        self.readline.deinit();
        self.scratch.deinit();
        gui.alloc.destroy(self);
    }

    fn getTextView(self: *@This()) ?*Wg.TextView {
        if (self.vt.area.children.items.len != 2) return null;
        const tv: *Wg.TextView = @alignCast(@fieldParentPtr("vt", self.vt.area.children.items[1]));
        return tv;
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn event_cb(ev_vt: *app.iEvent, ev: app.Event) void {
        const self: *@This() = @alignCast(@fieldParentPtr("ev_vt", ev_vt));

        switch (ev) {
            .notify => |n| {
                self.printLine("{s}", .{n}) catch {};
            },
            else => {},
        }
    }

    fn layout(gui: *Gui, area: Rect) struct { text: Rect, cmdline: Rect } {
        const inset = GuiHelp.insetAreaForWindowFrame(gui, area);
        const item_height = gui.dstate.style.config.default_item_h;
        const sp = inset.split(.horizontal, inset.h - item_height);
        return .{
            .text = sp[0],
            .cmdline = sp[1],
        };
    }

    pub fn build(vt: *iWindow, gui: *Gui, area: Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        vt.area.area = area;
        vt.area.clearChildren(gui, vt);
        vt.area.dirty();
        const sp = layout(gui, area);

        _ = Wg.Textbox.buildOpts(&vt.area, sp.cmdline, .{
            .init_string = "",
            .commit_cb = &textbox_cb,
            .commit_vt = &self.cbhandle,
            .fevent_override_cb = textbox_fevent,
            .user_id = 0,
            .clear_on_commit = true,
            .restricted_charset = "`",
            .invert_restriction = true,
        });
        if (vt.area.children.items.len > 0) {
            gui.grabFocus(vt.area.children.items[0], vt);
        }

        _ = Wg.TextView.build(&vt.area, sp.text, self.lines.items, vt, .{
            .mode = .split_on_space,
            .force_scroll = true,
            //.bg_col = 0x222222ff,
        });
    }

    pub fn focus(self: *@This(), gui: *Gui) void {
        if (self.vt.area.children.items.len > 0) {
            gui.grabFocus(self.vt.area.children.items[0], &self.vt);
        }
    }

    pub fn printLine(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
        self.scratch.clearRetainingCapacity();
        try self.scratch.print(fmt, args);
        const duped = try self.line_arena.allocator().dupe(u8, self.scratch.items);
        try self.lines.append(self.alloc, duped);

        const gui = self.vt.gui_ptr;
        var tv = self.getTextView() orelse return;
        tv.addOwnedText(duped, gui) catch return;
        tv.gotoBottom();
        tv.rebuildScroll(gui, &self.vt);
    }

    pub fn execCommand(self: *@This(), command: []const u8, gui: *Gui) void {
        self.printLine("{s}", .{command}) catch {}; //echo
        self.lines.append(self.alloc, self.line_arena.allocator().dupe(u8, command) catch return) catch return;
        self.scratch.clearRetainingCapacity();
        self.exec_vt.exec(self.exec_vt, command, &self.scratch);
        self.readline.appendHistory(command) catch return;
        const duped = self.line_arena.allocator().dupe(u8, self.scratch.items) catch return;
        self.lines.append(self.alloc, duped) catch return;
        var tv = self.getTextView() orelse return;
        tv.addOwnedText(duped, gui) catch return;
        tv.gotoBottom();
        tv.rebuildScroll(gui, &self.vt);
    }

    pub fn textbox_fevent(cb: *guis.CbHandle, ev: guis.FocusedEvent, tb: *Wg.Textbox) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        switch (ev.event) {
            else => {},
            .keydown => |kev| {
                const M = graph.SDL.keycodes.Keymod;
                const mod = kev.mod_state & ~M.mask(&.{ .SCROLL, .NUM, .CAPS });
                for (kev.keys) |key| {
                    if (key.state != .rising) continue;
                    const ctrl = mod & M.mask(&.{.CTRL}) != 0;

                    switch (@as(graph.SDL.keycodes.Scancode, @enumFromInt(key.key_id))) {
                        .UP => if (self.readline.prev()) |prev| {
                            tb.reset(prev) catch {};
                            tb.move_to(.end);
                        },
                        .DOWN => if (self.readline.next()) |next| {
                            tb.reset(next) catch {};
                            tb.move_to(.end);
                        },
                        .R => if (ctrl) { //ctrl p
                            if (self.readline.prev()) |prev| {
                                tb.reset(prev) catch {};
                                tb.move_to(.end);
                            }
                        },
                        .L => if (ctrl) { //ctrl n
                            if (self.readline.next()) |next| {
                                tb.reset(next) catch {};
                                tb.move_to(.end);
                            }
                        },
                        else => {},
                        .TAB => {
                            const complete_string = self.readline.complete();
                            if (complete_string.len > 0) {
                                tb.reset(complete_string) catch {};
                                tb.move_to(.end);
                            }
                            return; //skip emit
                        },
                    }
                }
            },
        }
        //pass on all events to textbox
        Wg.Textbox.fevent_err(&tb.vt, ev) catch return;
        self.readline.setLine(tb.codepoints.items) catch {};
    }

    pub fn textbox_cb(cb: *guis.CbHandle, gui: *Gui, string: []const u8, _: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", cb));
        self.execCommand(string, gui);
    }

    pub fn draw(vt: *iArea, d: DrawState) void {
        GuiHelp.drawWindowFrame(d, vt.area);
        const sp = layout(d.gui, vt.area);
        d.ctx.rect(sp.text, d.nstyle.color.text_bg);
    }
};

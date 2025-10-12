const graph = @import("graph");
const std = @import("std");
const DrawCtx = graph.ImmediateDrawingContext;
const Editor = @import("editor.zig").Context;

pub const ViewDrawState = struct {
    camstate: graph.ptypes.Camera3D.MoveState,
    draw: *DrawCtx,
    win: *graph.SDL.Window,
};

pub const iPane = struct {
    /// Called on every frame
    draw_fn: ?*const fn (*iPane, graph.Rect, *Editor, ViewDrawState, PaneId) void = null,
    deinit_fn: *const fn (*iPane, std.mem.Allocator) void,
};

pub const Grab = struct {
    owner: ?PaneId = null,
    grabbed: bool = false,
    was_grabbed: bool = false,

    overridden: bool = false,

    /// set before calling pane.draw_fn so we don't need to pass pane_id to every isBindStateCall
    current_stack_pane: ?PaneId = null,

    //if the mouse is ungrabbed, the pane who contains it gets own
    //if the mouse is ungrabbed, and a pane contain it, it can grab it
    //nobody else can own it until the owner calls ungrab

    pub fn tryOwn(self: *@This(), area: graph.Rect, win: *graph.SDL.Window, own: PaneId) bool {
        if (self.overridden) return false;
        if (self.was_grabbed) return self.owns(own);
        if (area.containsPoint(win.mouse.pos)) {
            self.owner = own;
        }
        return self.owns(own);
    }

    pub fn override(self: *@This()) void {
        self.overridden = true;
    }

    pub fn owns(self: *const @This(), owner: ?PaneId) bool {
        if (owner == null or self.owner == null or self.overridden) return false;
        return self.owner.? == owner.?;
    }

    pub fn endFrame(self: *@This()) void {
        self.was_grabbed = self.grabbed;
        self.grabbed = false;
        self.overridden = false;
        self.current_stack_pane = null;
    }

    pub fn trySetGrab(self: *@This(), own: PaneId, should_grab: bool) enum { ungrabbed, grabbed, none } {
        if (self.overridden) return .none;
        if (self.was_grabbed) {
            if (self.owns(own)) {
                self.grabbed = should_grab;
                if (!self.grabbed)
                    return .ungrabbed;
            }
            return .none;
        }
        if (self.owns(own)) {
            if (self.grabbed != should_grab) {
                self.grabbed = should_grab;
                self.was_grabbed = self.grabbed;
                return if (should_grab) .grabbed else .ungrabbed;
            }
        }
        return .none;
    }
};

pub const PaneId = usize;
pub const PaneReg = struct {
    const Self = @This();

    panes: std.ArrayList(*iPane),
    // Indicies into panes
    map: std.AutoHashMap(*iPane, PaneId),
    alloc: std.mem.Allocator,

    grab: Grab = .{},

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .alloc = alloc,
            .panes = std.ArrayList(*iPane).init(alloc),
            .map = std.AutoHashMap(*iPane, PaneId).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.panes.items) |pane| {
            pane.deinit_fn(pane, self.alloc);
        }
        self.panes.deinit();
        self.map.deinit();
    }

    pub fn add(self: *Self, pane: *iPane) !PaneId {
        if (self.map.contains(pane)) {
            return error.alreadyPut;
        }

        const id = self.panes.items.len;
        try self.panes.append(pane);
        try self.map.put(pane, id);
        return id;
    }

    pub fn get(self: *Self, id: PaneId) ?*iPane {
        if (id >= self.panes.items.len) return null;
        return self.panes.items[id];
    }

    pub fn stackOwns(self: *const Self) bool {
        return self.grab.owns(self.grab.current_stack_pane);
    }
};

pub const GuiPane = struct {
    const Self = @This();
    const guis = graph.RGui;
    const Gui = guis.Gui;
    vt: iPane,
    gui_ptr: *Gui,

    window_vt: *guis.iWindow,

    pub fn create(alloc: std.mem.Allocator, gui: *Gui, win: *guis.iWindow) !*iPane {
        var ret = try alloc.create(@This());
        ret.* = .{
            .vt = .{
                .deinit_fn = &deinit,
                .draw_fn = &draw_fn,
            },
            .window_vt = win,
            .gui_ptr = gui,
        };
        return &ret.vt;
    }

    pub fn draw_fn(vt: *iPane, screen_area: graph.Rect, editor: *Editor, _: ViewDrawState, pane_id: PaneId) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.gui_ptr.window_collector.append(self.gui_ptr.alloc, self.window_vt) catch return;
        self.gui_ptr.updateWindowSize(self.window_vt, screen_area) catch return;
        if (editor.panes.grab.owns(pane_id)) {
            self.gui_ptr.update(&.{self.window_vt}) catch return;
        }
    }

    pub fn deinit(vt: *iPane, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

const std = @import("std");
const graph = @import("graph");
const R = graph.Rect;
const G = graph.RGui;
//const R = struct { x: f32, y: f32, w: f32, h: f32 };

const Operation = enum { left, right, top, bottom };

pub const Op = struct { Operation, f32 };

pub fn calculateBounds(op: Op, area: R) [2]R {
    const vp = area.w * op[1];
    const hp = area.h * op[1];
    const L = R{ .x = area.x, .y = area.y, .w = vp, .h = area.h };
    const rr = R{ .x = area.x + vp, .y = area.y, .w = area.w - vp, .h = area.h };

    const T = R{ .x = area.x, .y = area.y, .w = area.w, .h = hp };
    const B = R{ .x = area.x, .y = area.y + hp, .w = area.w, .h = area.h - hp };
    return switch (op[0]) {
        .left => [2]R{ L, rr },
        .right => [2]R{ rr, L },
        .top => [2]R{ T, B },
        .bottom => [2]R{ B, T },
    };
}

pub fn fillBuf(in: []const Op, out: []R, root: R) []const R {
    var last = root;
    for (in, 0..) |inp, i| {
        const calc = calculateBounds(inp, last);
        out[i] = calc[0];
        last = calc[1];
    }
    return out[0..in.len];
}

test {
    const a = calculateBounds(.{ .left, 0.5 }, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    std.debug.print("{any}\n", .{a});

    var out: [4]R = undefined;
    _ = fillBuf(&.{
        .{ .left, 0.5 },
        .{ .top, 0.5 },
        .{ .left, 0.5 },
        .{ .bottom, 0.5 },
    }, &out, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    for (out) |o| {
        std.debug.print("{d:.2}, {d:.2}, {d}, {d}\n", .{ o.x, o.y, o.w, o.h });
    }
}

pub const Orientation = enum { vert, horiz };
//Default split gives left all, right nothing
pub const Split = struct {
    k: Orientation = .vert,
    pos: f32 = 1,
    kind: enum { perc, abs } = .perc,

    fn calcThing(self: @This(), width: f32) f32 {
        return switch (self.kind) {
            .perc => width * self.pos,
            .abs => self.pos,
        };
    }
};
pub const Area = union(enum) {
    pane: G.WindowId,
    sub: struct {
        split: Split,
        left: *Area,
        right: *Area,
    },
};

pub const ResizeHandle = struct {
    perc_ptr: *f32,
    k: Orientation,
    perc_screenspace: f32,
    r: R,
};

const Workspace = struct {};

fn splitR(r: R, op: anytype, pad: f32) [3]R {
    switch (op.k) {
        .vert => {
            const w = op.calcThing(r.w);
            return [3]R{
                .{ .x = r.x, .y = r.y, .w = w - pad, .h = r.h },
                .{ .x = r.x + w + pad, .y = r.y, .w = r.w - w - pad, .h = r.h },
                .{ .x = r.x + w - pad, .w = pad * 2, .y = r.y, .h = r.h },
            };
        },
        .horiz => {
            const h = op.calcThing(r.h);
            return [3]R{
                .{ .x = r.x, .y = r.y, .h = h - pad, .w = r.w },
                .{ .y = r.y + h + pad, .x = r.x, .h = r.h - h - pad, .w = r.w },
                .{ .x = r.x, .w = r.w, .y = r.y + h - pad, .h = pad * 2 },
            };
        },
    }
}

pub const Splits = struct {
    const Self = @This();
    pub const Output = struct {
        R,
        G.WindowId,
    };

    arena: std.heap.ArenaAllocator,
    workspaces: std.ArrayList(*Area),
    active_ws: usize = 0,

    //index into tab_handles
    slider_held: ?usize = null,

    area: R = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    tab_outputs: std.ArrayList(Output),

    tab_handles: std.ArrayList(ResizeHandle),

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .workspaces = std.ArrayList(*Area).init(alloc),
            .tab_handles = std.ArrayList(ResizeHandle).init(alloc),
            .tab_outputs = std.ArrayList(Output).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        self.workspaces.deinit();
        self.tab_handles.deinit();
        self.tab_outputs.deinit();
    }

    pub fn newArea(self: *Self, area: Area) *Area {
        const area_ptr = self.arena.allocator().create(Area) catch std.process.exit(1);
        area_ptr.* = area;
        return area_ptr;
    }

    pub fn setWorkspaceAndArea(self: *Self, ws: usize, area: R) !void {
        if (ws >= self.workspaces.items.len) return;
        if (!area.eql(self.area) or self.active_ws != ws or self.slider_held != null) {
            self.area = area;
            self.active_ws = ws;
            self.tab_outputs.clearRetainingCapacity();
            self.tab_handles.clearRetainingCapacity();
            const tab = self.workspaces.items[ws];
            try flattenTree(self.area, tab, &self.tab_outputs, &self.tab_handles);
        }
    }

    pub fn doTheSliders(self: *Self, mp: graph.Vec2f, md: graph.Vec2f, btn: graph.SDL.ButtonState) void {
        switch (btn) {
            .low, .falling => self.slider_held = null,
            .rising => {
                for (self.tab_handles.items, 0..) |tb, i| {
                    if (tb.r.containsPoint(mp)) {
                        self.slider_held = i;
                        return;
                    }
                }
            },
            .high => {
                if (self.slider_held) |sl| {
                    if (sl < self.tab_handles.items.len) {
                        const tb = self.tab_handles.items[sl];
                        const del = switch (tb.k) {
                            .vert => md.x,
                            .horiz => md.y,
                        };
                        const adding = del / tb.perc_screenspace;
                        tb.perc_ptr.* += adding;
                        tb.perc_ptr.* = std.math.clamp(tb.perc_ptr.*, 0.1, 0.9);
                    }
                }
            },
        }
    }

    pub fn getTab(self: *Self) []const Output {
        return self.tab_outputs.items;
    }
};

pub fn flattenTree(
    root_area: R,
    tree: *Area,
    output_list: *std.ArrayList(struct { R, G.WindowId }),
    output_handles: *std.ArrayList(ResizeHandle),
) !void {
    switch (tree.*) {
        .sub => |t| {
            const sp = splitR(root_area, t.split, if (t.split.kind == .perc) 5 else 0);
            try flattenTree(sp[0], t.left, output_list, output_handles);
            try flattenTree(sp[1], t.right, output_list, output_handles);
            if (t.split.kind == .perc)
                try output_handles.append(
                    .{
                        .perc_ptr = &tree.sub.split.pos,
                        .k = t.split.k,
                        .r = sp[2],
                        .perc_screenspace = switch (t.split.k) {
                            .vert => root_area.w,
                            .horiz => root_area.h,
                        },
                    },
                );
        },
        .pane => |p| try output_list.append(.{ root_area, p }),
    }
}

test {
    const alloc = std.testing.allocator;
    const root = Area{
        .split = .{ .k = .vert, .pos = 0.5 },
        .left = null, // index 0
        .right = &Area{
            .split = .{ .k = .horiz, .pos = 0.5 },
            .left = null, //Index 1
            .right = null, //index 2
        },
    };
    var list = std.ArrayList(R).init(alloc);
    defer list.deinit();
    try flattenTree(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, &root, &list);

    std.debug.print("STARTING\n", .{});
    for (list.items) |o| {
        std.debug.print("{d:.2}, {d:.2}, {d}, {d}\n", .{ o.x, o.y, o.w, o.h });
    }
}

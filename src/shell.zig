const std = @import("std");

const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const Console = @import("windows/console.zig");
const edit = @import("editor.zig");
const Editor = edit.Context;
const pointfile = @import("pointfile.zig");
const actions = @import("actions.zig");
//TODO
//add commands for
//rebuild all meshes
//write a save
//kill the vbsp

const Commands = enum {
    count_ents,
    help,
    select_id,
    select_class,
    select_tex,
    fov,
    dump_selected,
    snap_selected,
    optimize,
    tp,
    pointfile,
    unload_pointfile,
    unload_portalfile,
    portalfile,
    stats,
    wireframe,
    env,
    pos,

    trySave,
    undo,
    redo,
    clearSelection,
    delete,
    hide,
    unhideAll,
};

pub var RpcEventId: u32 = 0;

pub fn rpc_cb(ev: graph.c.SDL_UserEvent) void {
    var write_buf: [1024]u8 = undefined;
    const rpc = @import("rpc/server.zig");
    const ha = std.hash.Wyhash.hash;
    const cmd: *CommandCtx = @ptrCast(@alignCast(ev.data1 orelse return));
    const ed = cmd.ed;
    if (ev.type == RpcEventId) {
        if (ev.data2) |us1| {
            const event: *rpc.Event = @ptrCast(@alignCast(us1));
            defer event.deinit(ed.rpcserv.alloc);
            for (event.msg) |msg| {
                var wr = event.stream.writer(&write_buf);
                switch (ha(0, msg.method)) {
                    ha(0, "shell") => {
                        _ = cmd.arena.reset(.retain_capacity);
                        const aa = cmd.arena.allocator();
                        var args = std.ArrayList([]const u8){};
                        switch (msg.params) {
                            .array => |arr| {
                                for (arr.items) |param| {
                                    switch (param) {
                                        .string => |str| args.append(aa, str) catch return,
                                        else => {},
                                    }
                                }
                                var cmd_response = std.array_list.Managed(u8).init(aa);
                                cmd.execErr(args.items, &cmd_response) catch return;

                                ed.rpcserv.respond(&wr.interface, .{
                                    .id = msg.id,
                                    .result = .{ .string = cmd_response.items },
                                }) catch {};
                            },
                            else => {},
                        }
                    },
                    ha(0, "pause") => {
                        ed.paused = !ed.paused;
                        ed.rpcserv.respond(&wr.interface, .{
                            .id = msg.id,
                            .result = .{ .null = {} },
                        }) catch {};
                    },
                    ha(0, "select_class") => {},
                    else => {
                        wr.interface.print("Fuked dude, wrong method\n", .{}) catch {};
                        wr.interface.flush() catch {};
                    },
                }
            }
        }
    }
}

pub const CommandCtx = struct {
    ed: *Editor,
    env: std.StringHashMap([]const u8),
    arena: std.heap.ArenaAllocator,

    pub fn create(alloc: std.mem.Allocator, editor: *Editor) !*@This() {
        const self = try alloc.create(@This());

        self.* = .{
            .ed = editor,
            .env = std.StringHashMap([]const u8).init(alloc),
            .arena = std.heap.ArenaAllocator.init(alloc),
        };

        return self;
    }

    pub fn destroy(self: *@This(), alloc: std.mem.Allocator) void {
        self.env.deinit();
        self.arena.deinit();
        alloc.destroy(self);
    }

    pub fn resolveArg(self: *@This(), token: []const u8, output: *std.array_list.Managed(u8)) !void {
        if (token.len == 0) return;
        switch (token[0]) {
            '$' => try output.appendSlice(self.env.get(token[1..]) orelse return error.notAVar),
            '!' => try self.execErr(token[1..], output),
            else => try output.appendSlice(token),
        }
    }

    pub fn execErr(self: *@This(), argv: []const []const u8, wr: *std.array_list.Managed(u8)) anyerror!void {
        var args = SliceIt{ .slices = argv };
        const com_name = args.next() orelse return;
        if (std.meta.stringToEnum(Commands, com_name)) |com| {
            switch (com) {
                .undo => actions.undo(self.ed),
                .redo => actions.redo(self.ed),
                .trySave => try actions.trySave(self.ed),
                .clearSelection => try actions.clearSelection(self.ed),
                .delete => try actions.deleteSelected(self.ed),
                .hide => try actions.hideSelected(self.ed),
                .unhideAll => try actions.unhideAll(self.ed),
                .count_ents => {
                    try wr.print("Number of entites: {d}", .{self.ed.ecs.getEntLength()});
                },
                .help => {
                    if (args.next()) |help_com| {
                        if (std.meta.stringToEnum(Commands, help_com)) |en| {
                            try wr.print("{s}: {s}", .{ help_com, switch (en) {
                                else => "no doc written",
                                .select_id => "id0 id1... , Add or remove ids from selection",
                                .select_class => "prop_static infodecal... , Add or remove any entities with matching class",
                                .snap_selected => "Round all vertices of selected solids to integers",
                                .optimize => "Attempt to fix invalid solids in selection",
                                .pointfile => "Attempt to load pointfile in map compile dir, or user path if specified",
                            } });
                        } else {
                            try wr.print("Unknown command: {s}", .{help_com});
                        }
                    } else {
                        try wr.print("commands: \n", .{});
                        const field = @typeInfo(Commands).@"enum".fields;
                        inline for (field) |f| {
                            try wr.print("{s}\n", .{f.name});
                        }
                    }
                },
                .pos => {
                    const p = self.ed.draw_state.cam3d.pos;
                    try wr.print("{d} {d} {d}", .{ p.x(), p.y(), p.z() });
                    try wr.print("\n", .{});
                },
                .select_class => {
                    const class = args.next() orelse return error.expectedClassName;
                    var it = self.ed.ecs.iterator(.entity);
                    while (it.next()) |ent| {
                        if (std.mem.eql(u8, class, ent.class)) {
                            _ = self.ed.selection.put(it.i, self.ed) catch |err| {
                                try wr.print("Selection failed {t}\n", .{err});
                            };
                        }
                    }
                },
                .select_tex => {
                    const tex = args.next() orelse return error.expectedTexturePrefix;
                    var it = self.ed.ecs.iterator(.solid);
                    while (it.next()) |ent| {
                        var matches = true;
                        for (ent.sides.items) |side| {
                            const name = try self.ed.vpkctx.resolveId(.{ .id = side.tex_id }, false) orelse return error.invalidTexName;
                            matches = matches and std.mem.startsWith(u8, name.name, tex);
                            if (!matches)
                                break;
                        }

                        if (matches) {
                            _ = self.ed.selection.put(it.i, self.ed) catch {};
                        }
                    }
                },
                .env => {
                    var it = self.env.iterator();
                    while (it.next()) |item| {
                        try wr.print("{s}: {s}\n", .{ item.key_ptr.*, item.value_ptr.* });
                    }
                },
                .fov => {
                    const fov: f32 = std.fmt.parseFloat(f32, args.next() orelse "90") catch 90;
                    self.ed.draw_state.cam3d.fov = fov;
                    try wr.print("Set fov to {d}", .{fov});
                },
                .select_id => {
                    while (args.next()) |item| {
                        if (std.fmt.parseInt(u32, item, 10)) |id| {
                            if (!self.ed.ecs.isEntity(id)) {
                                try wr.print("\tNot an entity: {d}\n", .{id});
                            } else {
                                _ = self.ed.selection.put(id, self.ed) catch |err| {
                                    try wr.print("Selection failed {t}\n", .{err});
                                };
                            }
                        } else |_| {
                            try wr.print("\tinvalid number: {s}\n", .{item});
                        }
                    }
                },
                .wireframe => {
                    self.ed.draw_state.tog.wireframe = !self.ed.draw_state.tog.wireframe;
                },
                .stats => {
                    try wr.print("Num meshmaps/texture: {d}\n", .{self.ed.meshmap.count()});
                    try wr.print("Num models: {d}\n", .{self.ed.models.count()});
                    try wr.print("comp solid: {d} \n", .{self.ed.ecs.data.solid.dense.items.len});
                    try wr.print("comp ent  : {d} \n", .{self.ed.ecs.data.entity.dense.items.len});
                    try wr.print("comp kvs  : {d} \n", .{self.ed.ecs.data.key_values.dense.items.len});
                    try wr.print("comp AABB : {d} \n", .{self.ed.ecs.data.bounding_box.dense.items.len});
                    try wr.print("comp deleted : {d} \n", .{self.ed.ecs.data.deleted.dense.items.len});
                },
                .dump_selected => {
                    const selected_slice = self.ed.getSelected();
                    for (selected_slice) |id| {
                        try wr.print("id: {d} \n", .{id});
                        if (try self.ed.ecs.getOptPtr(id, .solid)) |solid| {
                            try wr.print("Solid\n", .{});
                            for (solid.verts.items, 0..) |vert, i| {
                                try wr.print("  v {d} [{d:.1} {d:.1} {d:.1}]\n", .{ i, vert.x(), vert.y(), vert.z() });
                            }
                            for (solid.sides.items, 0..) |side, i| {
                                try wr.print("  side {d}: ", .{i});
                                for (side.index.items) |ind|
                                    try wr.print(" {d}", .{ind});
                                try wr.print("\n", .{});
                                const norm = side.normal(solid);
                                try wr.print("  Normal: [{d} {d} {d}]\n", .{ norm.x(), norm.y(), norm.z() });
                            }
                        }
                    }
                },
                .optimize => {
                    const selected_slice = self.ed.getSelected();
                    for (selected_slice) |id| {
                        if (try self.ed.ecs.getOptPtr(id, .solid)) |solid|
                            try solid.optimizeMesh();
                    }
                },
                .snap_selected => {
                    const selected_slice = self.ed.getSelected();
                    for (selected_slice) |id| {
                        if (try self.ed.ecs.getOptPtr(id, .solid)) |solid|
                            try solid.roundAllVerts(id, self.ed);
                    }
                },
                .tp => {
                    if (parseVec(&args)) |vec| {
                        try wr.print("Teleporting to {d} {d} {d}\n", .{ vec.x(), vec.y(), vec.z() });
                        self.ed.draw_state.cam3d.pos = vec;
                    } else {
                        //try wr.print("Invalid teleport command: '{s}'\n", .{scratch.items});
                    }
                },
                .portalfile => {
                    const pf = &self.ed.draw_state.portalfile;
                    if (pf.*) |pf1|
                        pf1.verts.deinit();
                    pf.* = null;

                    const path = if (args.next()) |p| p else try self.ed.printScratch("{s}/{s}", .{ edit.TMP_DIR, "dump.prt" });

                    pf.* = try pointfile.loadPortalfile(self.ed.alloc, std.fs.cwd(), path);
                },
                .pointfile => {
                    if (self.ed.draw_state.pointfile) |pf|
                        pf.verts.deinit();
                    self.ed.draw_state.pointfile = null;

                    const path = if (args.next()) |p| p else try self.ed.printScratch("{s}/{s}", .{ edit.TMP_DIR, "dump.lin" });

                    self.ed.draw_state.pointfile = try pointfile.loadPointfile(self.ed.alloc, std.fs.cwd(), path);
                },
                .unload_pointfile => {
                    if (self.ed.draw_state.pointfile) |pf|
                        pf.verts.deinit();
                    self.ed.draw_state.pointfile = null;
                },
                .unload_portalfile => {
                    if (self.ed.draw_state.portalfile) |pf|
                        pf.verts.deinit();
                    self.ed.draw_state.portalfile = null;
                },
            }
        } else {
            try wr.print("Unknown command\n", .{});
            try printCommand(argv, wr);
            try wr.print("\n", .{});
        }
    }
};

fn parseVec(it: anytype) ?Vec3 {
    return Vec3.new(
        std.fmt.parseFloat(f32, it.next() orelse return null) catch return null,
        std.fmt.parseFloat(f32, it.next() orelse return null) catch return null,
        std.fmt.parseFloat(f32, it.next() orelse return null) catch return null,
    );
}

const SliceIt = struct {
    pos: usize = 0,
    slices: []const []const u8,

    fn next(self: *@This()) ?[]const u8 {
        if (self.pos >= self.slices.len) return null;

        defer self.pos += 1;
        return self.slices[self.pos];
    }
};

fn printCommand(argv: []const []const u8, wr: *std.array_list.Managed(u8)) !void {
    for (argv) |arg| {
        try wr.print("{s}", .{arg});
    }
    try wr.print("\n", .{});
}

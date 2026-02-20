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

const ArgIt = std.mem.TokenIterator(u8, .scalar);
fn argIt(arg_string: []const u8) ArgIt {
    return std.mem.tokenizeScalar(u8, arg_string, ' ');
}
pub const Commands = enum {
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
    save_as,

    undo,
    redo,
    clearSelection,
    delete,
    hide,
    unhideAll,

    translate,

    create_cube,

    rebuild_meshes,

    vpkinfo,

    unload_map,
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
                        var args = std.ArrayList(u8){};
                        switch (msg.params) {
                            .array => |arr| {
                                for (arr.items) |param| {
                                    switch (param) {
                                        .string => |str| args.appendSlice(aa, str) catch return,
                                        else => {},
                                    }
                                }
                                var cmd_response = std.array_list.Managed(u8).init(aa);
                                var arg_it = argIt(args.items);

                                cmd.execErr(&arg_it, &cmd_response) catch return;

                                ed.rpcserv.respond(&wr.interface, .{
                                    .id = msg.id,
                                    .result = .{ .string = cmd_response.items },
                                }) catch {};
                            },
                            else => {},
                        }
                    },
                    ha(0, "pause") => {
                        ed.setPaused(!ed._paused);
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

pub fn helpCommand(cmd: Commands) []const u8 {
    return switch (cmd) {
        else => "TODO WRITE USAGE",
        .select_id => "id0 id1... -> Add or remove ids from selection",
        .select_class => "prop_static infodecal... -> Add or remove any entities with matching class",
        .snap_selected => "-> Round all vertices of selected solids to integers",
        .optimize => "-> Attempt to fix invalid solids in selection",
        .pointfile => "-> Attempt to load pointfile in map compile dir, or user path if specified",
        .translate => "dx:float dy:float dz:float duplicate:?bool",
    };
}

pub const CommandCtx = struct {
    ed: *Editor,
    env: std.StringHashMap([]const u8),
    arena: std.heap.ArenaAllocator,

    iconsole: Console.ConsoleCb,

    pub fn create(alloc: std.mem.Allocator, editor: *Editor) !*@This() {
        const self = try alloc.create(@This());

        self.* = .{
            .ed = editor,
            .env = std.StringHashMap([]const u8).init(alloc),
            .arena = std.heap.ArenaAllocator.init(alloc),
            .iconsole = .{
                .exec = execConsole,
            },
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

    pub fn execConsole(vt: *Console.ConsoleCb, string: []const u8, wr: *std.array_list.Managed(u8)) void {
        const self: *@This() = @alignCast(@fieldParentPtr("iconsole", vt));
        var args = argIt(string);
        _ = self.arena.reset(.retain_capacity);
        self.execErr(&args, wr) catch |err| {
            var arg2 = argIt(string);
            const com = arg2.next() orelse "";
            wr.print("error.{t} executing command `{s}`\n", .{ err, com }) catch return;
            if (std.meta.stringToEnum(Commands, com)) |comc| {
                wr.print("Usage:\n\t{s} {s}", .{ com, helpCommand(comc) }) catch return;
            }
        };
    }

    /// args must be a container pointer with a pub fn next() ?[] const u8
    pub fn execErr(self: *@This(), args: *ArgIt, wr: *std.array_list.Managed(u8)) anyerror!void {
        //var args = SliceIt{ .slices = argv };
        const com_name = args.next() orelse return;
        if (std.meta.stringToEnum(Commands, com_name)) |com| {
            switch (com) {
                .unload_map => {
                    try actions.unloadMap(self.ed);
                },
                .vpkinfo => {
                    try wr.print("{d} entries\n", .{self.ed.vpkctx.entries.count()});
                    try wr.print("{d} games\n", .{self.ed.vpkctx.gameinfos.count()});
                    for (self.ed.vpkctx.gameinfos.keys()) |k| {
                        try wr.print("\t{s}\n", .{k});
                    }
                    try wr.print("{d} extensions\n", .{self.ed.vpkctx.extension_map.counter});
                    try wr.print("{d} paths\n", .{self.ed.vpkctx.path_map.counter});
                },
                .rebuild_meshes => {
                    var timer = try std.time.Timer.start();
                    try self.ed.rebuildAllDependentState();
                    try wr.print("mesh build took {d} ms\n", .{timer.read() / std.time.ns_per_ms});
                },
                .translate => {
                    const p = parseTypedArgs(struct {
                        dx: f32,
                        dy: f32,
                        dz: f32,
                        mod: enum { dupe, none } = .none,
                    }, args, wr, com, self.arena.allocator()) catch return;

                    try actions.rotateTranslateSelected(self.ed, p.mod == .dupe, null, .zero(), .new(p.dx, p.dy, p.dz));
                },
                .create_cube => {
                    const p = parseTypedArgs(struct {
                        x: f32,
                        y: f32,
                        z: f32,

                        x_dim: f32,
                        y_dim: f32,
                        z_dim: f32,
                        mod: enum { select, none } = .none,
                    }, args, wr, com, self.arena.allocator()) catch return;
                    const pgen = @import("primitive_gen.zig");
                    const cube = try pgen.cube(self.arena.allocator(), .{ .size = .new(p.x_dim, p.y_dim, p.z_dim) });
                    const vpk_id = self.ed.edit_state.selected_texture_vpk_id orelse 0;
                    _ = try actions.createSolid(self.ed, &cube, vpk_id, .new(p.x, p.y, p.z), .identity(), p.mod == .select);
                },
                .undo => actions.undo(self.ed),
                .redo => actions.redo(self.ed),
                .save_as => {
                    const p = parseTypedArgs(struct { filepath: []const u8 }, args, wr, com, self.arena.allocator()) catch return;

                    try self.ed.setMapName(p.filepath);
                    try actions.trySave(self.ed);
                },
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
                            try wr.print("Usage:\n\t{s} {s}", .{ help_com, helpCommand(en) });
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
                    const parg = parseTypedArgs(struct { class: []const []const u8 }, args, wr, com, self.arena.allocator()) catch return;
                    var counts = try self.arena.allocator().alloc(struct {
                        added: usize = 0,
                        masked: usize = 0,
                        removed: usize = 0,
                    }, parg.class.len);

                    for (counts) |*cc|
                        cc.* = .{};

                    self.ed.selection.setToMulti();
                    var it = self.ed.ecs.iterator(.entity);
                    outer: while (it.next()) |ent| {
                        for (parg.class, 0..) |class, c_i| {
                            if (std.mem.eql(u8, class, ent.class)) {
                                const res = self.ed.selection.put(it.i, self.ed) catch |err| {
                                    try wr.print("Selection failed {t}\n", .{err});
                                    continue;
                                };
                                const cc = &counts[c_i];
                                switch (res.res) {
                                    .masked => cc.masked += 1,
                                    .added => cc.added += 1,
                                    .removed => cc.removed += 1,
                                }
                                continue :outer;
                            }
                        }
                    }

                    var total_add: usize = 0;
                    var total_mask: usize = 0;
                    var total_rem: usize = 0;
                    try wr.print("{s:<16} added removed masked\n", .{"key: class"});
                    const fmt = "{s:<16} {d:>4} {d:>4} {d:>4}\n";
                    for (parg.class, 0..) |class, c_i| {
                        const cc = counts[c_i];
                        total_add += cc.added;
                        total_mask += cc.masked;
                        total_rem += cc.removed;
                        try wr.print(fmt, .{ class, cc.added, cc.removed, cc.masked });
                    }
                    try wr.print("\n", .{});
                    try wr.print(fmt, .{ "total", total_add, total_rem, total_mask });
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
                            try solid.optimizeMesh(.{ .can_reorder = !self.ed.hasComponent(id, .displacements) });
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
                    const parg = parseTypedArgs(struct { x: f32, y: f32, z: f32 }, args, wr, com, self.arena.allocator()) catch return;
                    try wr.print("Teleporting to {d} {d} {d}\n", .{ parg.x, parg.y, parg.z });
                    self.ed.draw_state.cam3d.pos = .new(parg.x, parg.y, parg.z);
                },
                .portalfile => {
                    const pf = &self.ed.draw_state.portalfile;
                    if (pf.*) |pf1|
                        pf1.verts.deinit();
                    pf.* = null;

                    const path = if (args.next()) |p| p else try self.ed.printScratch("{s}/{s}.prt", .{
                        self.ed.game_conf.mapbuilder.tmp_dir,
                        self.ed.loaded_map_name orelse "dump",
                    });

                    pf.* = try pointfile.loadPortalfile(self.ed.alloc, std.fs.cwd(), path);
                },
                .pointfile => {
                    const path = if (args.next()) |p| p else try self.ed.printScratch("{s}/{s}.lin", .{
                        self.ed.game_conf.mapbuilder.tmp_dir,
                        self.ed.loaded_map_name orelse "dump",
                    });
                    try actions.loadPointfile(self.ed, std.fs.cwd(), path);
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
            try wr.print("Unknown command, type 'help'\n", .{});
            //try printCommand(argv, wr);
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

fn parseTypedArgs(comptime T: type, it: *ArgIt, wr: *std.array_list.Managed(u8), cmd: Commands, arena: std.mem.Allocator) !T {
    return parseTypedArgsStruct(T, it, arena) catch |err| {
        try writeErrorTypedArgs(T, err, it, wr, cmd);
        return error.failed;
    };
}

fn parseTypedArgsStruct(comptime struct_T: type, it: *ArgIt, arena: std.mem.Allocator) !struct_T {
    const info = @typeInfo(struct_T);
    if (info != .@"struct") @compileError("parseTypedArgs expected struct type");
    var ret: struct_T = undefined;
    inline for (info.@"struct".fields, 0..) |field, fi| {
        switch (@typeInfo(field.type)) {
            else => {
                @field(ret, field.name) = try parseTypedArgsInner(it.next(), field);
            },
            .pointer => |p| {
                if (field.type == []const u8) {
                    @field(ret, field.name) = try parseTypedArgsInner(it.next(), field);
                    continue;
                }
                if (p.size != .slice) @compileError("pointer must be slice");
                var array = std.ArrayList(p.child){};
                while (it.next()) |value| {
                    try array.append(arena, try parseTypedArgsInner(value, .{
                        .type = p.child,
                        .name = field.name,
                        .is_comptime = false,
                        .alignment = @alignOf(p.child),
                        .default_value_ptr = null,
                    }));
                }
                if (array.items.len == 0) return error.expectedList;
                @field(ret, field.name) = array.items;
                if (fi != info.@"struct".fields.len - 1) @compileError("slice arg must be last in struct");
                return ret;
            },
        }
    }
    return ret;
}

fn parseTypedArgsInner(value: ?[]const u8, comptime field: std.builtin.Type.StructField) !field.type {
    const finfo = @typeInfo(field.type);

    switch (finfo) {
        else => @compileError("not supported " ++ field.name ++ " : " ++ @typeName(field.type)),
        .pointer => |p| {
            if (p.size != .slice or p.child != u8) @compileError("pointer must be []const u8");
            return value orelse error.expectedString;
        },
        .float => return std.fmt.parseFloat(field.type, value orelse return error.expectedFloat),
        .@"enum" => {
            if (value) |val| {
                return std.meta.stringToEnum(field.type, val) orelse return error.invalidEnum;
            } else {
                if (field.default_value_ptr) |default| {
                    return @as(*const field.type, @ptrCast(default)).*;
                }
                return error.expectedEnum;
            }
        },
    }
}

fn writeErrorTypedArgs(comptime T: type, err: anyerror, it: *const ArgIt, wr: *std.array_list.Managed(u8), cmd: Commands) !void {
    const info = @typeInfo(T);

    try wr.appendNTimes(' ', it.index);
    try wr.print("^\n", .{});
    try wr.print("{t}\n", .{err});

    try wr.print("usage:\n{t} ", .{cmd});
    inline for (info.@"struct".fields) |field| {
        switch (@typeInfo(field.type)) {
            .float => try wr.print("{s} ", .{field.name}),
            .@"enum" => |e| {
                try wr.print("{s}:{{ ", .{field.name});
                inline for (e.fields) |ef| {
                    try wr.print("{s} ", .{ef.name});
                }
                try wr.print("}} ", .{});
            },
            .pointer => {
                for (0..3) |i| {
                    try wr.print("{s}{d} ", .{ field.name, i });
                }
                try wr.print("...", .{});
            },
            else => @compileError(""),
        }
    }
}

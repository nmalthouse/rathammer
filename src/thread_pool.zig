const std = @import("std");
const Mutex = std.Thread.Mutex;
const vtf = @import("vtf.zig");
const vpk = @import("vpk.zig");
const vdf = @import("vdf.zig");
const vvd = @import("vvd.zig");
const edit = @import("editor.zig");
const graph = @import("graph");
const DEBUG_PRINT = false;
const ecs = @import("ecs.zig");
const eql = std.mem.eql;

pub const ThreadState = struct {
    alloc: std.mem.Allocator,
    vtf_file_buffer: std.ArrayList(u8) = .{},

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *@This()) void {
        self.vtf_file_buffer.deinit(self.alloc);
    }
};

pub const DeferredNotifyVtable = struct {
    notify_fn: *const fn (self: *@This(), id: vpk.VpkResId, editor: *edit.Context) void,

    pub fn notify(self: *@This(), id: vpk.VpkResId, editor: *edit.Context) void {
        self.notify_fn(self, id, editor);
    }
};

pub const iJob = struct {
    /// Store whatever you want in here
    user_id: usize,

    /// Called from the main thread 'editor'
    /// User is responsible for dealloc
    onComplete: *const fn (*iJob, editor: *edit.Context) void,
};

pub const CompletedVtfItem = struct {
    data: [ecs.Material.num_slots]?vtf.VtfBuf,
    vpk_res_id: vpk.VpkResId,
    kind: enum { none, tool },

    pub fn deinitToMaterial(self: *CompletedVtfItem, alloc: std.mem.Allocator) !ecs.Material {
        var ret: ecs.Material = .default();
        for (&self.data, 0..) |*dat, i| {
            if (dat.*) |*dd| {
                ret.set(i, try dd.deinitToTexture(alloc));
            }
        }
        return ret;
    }

    pub fn deinit(self: *CompletedVtfItem) void {
        for (&self.data) |*dat| {
            if (dat.*) |*dd|
                dd.deinit();
        }
    }
};
const log = std.log.scoped(.vtf);

const ThreadId = std.Thread.Id;
pub const Context = struct {
    alloc: std.mem.Allocator,

    map: std.AutoHashMap(std.Thread.Id, *ThreadState),
    map_mutex: Mutex = .{},

    //TODO these names are misleading, completed is textures, models
    completed: std.ArrayList(CompletedVtfItem) = .{},
    completed_models: std.ArrayList(vvd.MeshDeferred) = .{},
    completed_generic: std.ArrayList(*iJob) = .{},
    ///this mutex is used by all the completed_* fields
    completed_mutex: Mutex = .{},

    //TODO this pool should be global or this context should represent all worker thread operations
    pool: *std.Thread.Pool,

    texture_notify: std.AutoHashMap(vpk.VpkResId, std.ArrayList(*DeferredNotifyVtable)),
    notify_mutex: Mutex = .{},

    pub fn init(alloc: std.mem.Allocator, worker_thread_count: ?u32) !@This() {
        const num_cpu = try std.Thread.getCpuCount();
        const count = worker_thread_count orelse @max(num_cpu, 2) - 1;
        const pool = try alloc.create(std.Thread.Pool);
        log.info("Initializing thread pool with {d} threads.", .{count});
        try pool.init(.{ .allocator = alloc, .n_jobs = @intCast(count) });
        return .{
            .map = std.AutoHashMap(std.Thread.Id, *ThreadState).init(alloc),
            .alloc = alloc,
            .pool = pool,
            .texture_notify = std.AutoHashMap(vpk.VpkResId, std.ArrayList(*DeferredNotifyVtable)).init(alloc),
        };
    }

    pub fn getState(self: *@This()) !*ThreadState {
        self.map_mutex.lock();
        defer self.map_mutex.unlock();
        const thread_id = std.Thread.getCurrentId();
        if (self.map.get(thread_id)) |th| return th;

        const new = try self.alloc.create(ThreadState);
        new.* = ThreadState.init(self.alloc);
        try self.map.put(thread_id, new);
        return new;
    }

    pub fn insertCompleted(self: *@This(), item: CompletedVtfItem) !void {
        self.completed_mutex.lock();
        defer self.completed_mutex.unlock();
        try self.completed.append(self.alloc, item);
    }

    pub fn insertCompletedJob(self: *@This(), item: *iJob) !void {
        self.completed_mutex.lock();
        defer self.completed_mutex.unlock();
        try self.completed_generic.append(self.alloc, item);
    }

    pub fn notifyCompletedGeneric(self: *@This(), editor: *edit.Context) void {
        self.completed_mutex.lock();
        defer self.completed_mutex.unlock();
        for (self.completed_generic.items) |item| {
            item.onComplete(item, editor);
        }
        self.completed_generic.clearRetainingCapacity();
    }

    /// Use in conjunction with insertCompletedJob; probably pass a *@This() to your func
    pub fn spawnJob(self: *@This(), comptime func: anytype, args: anytype) !void {
        try self.pool.spawn(func, args);
    }

    pub fn notifyTexture(self: *@This(), id: vpk.VpkResId, editor: *edit.Context) void {
        self.notify_mutex.lock();
        defer self.notify_mutex.unlock();

        if (self.texture_notify.getPtr(id)) |list| {
            for (list.items) |vt| {
                vt.notify(id, editor);
            }
            list.deinit(self.alloc);
            _ = self.texture_notify.remove(id);
        }
    }

    //Remove all notify for given id without calling any vt functions
    pub fn removeNotify(self: *@This(), id: vpk.VpkResId) void {
        self.notify_mutex.lock();
        defer self.notify_mutex.unlock();

        if (self.texture_notify.getPtr(id)) |list| {
            list.deinit(self.alloc);
            _ = self.texture_notify.remove(id);
        }
    }

    //TODO be really carefull when using this, ensure any added vt's are alive
    pub fn addNotify(self: *@This(), id: vpk.VpkResId, vt: *DeferredNotifyVtable) !void {
        self.notify_mutex.lock();
        defer self.notify_mutex.unlock();
        if (self.texture_notify.getPtr(id)) |list| {
            try list.append(self.alloc, vt);
            return;
        }

        var new_list = std.ArrayList(*DeferredNotifyVtable){};
        try new_list.append(self.alloc, vt);
        try self.texture_notify.put(id, new_list);
    }

    pub fn deinit(self: *@This()) void {
        self.pool.deinit();
        self.map_mutex.lock();
        self.completed_mutex.lock();
        {
            var it = self.texture_notify.valueIterator();
            while (it.next()) |tx|
                tx.deinit(self.alloc);
            self.texture_notify.deinit();
        }
        // freeing memory of any remaining completed is not a priority, may leak.
        self.completed_generic.deinit(self.alloc);
        var it = self.map.iterator();
        while (it.next()) |item| {
            item.value_ptr.*.deinit();
            self.alloc.destroy(item.value_ptr.*);
        }
        for (self.completed_models.items) |*item| {
            item.mesh.deinit();
            self.alloc.destroy(item.mesh);
        }
        self.completed_models.deinit(self.alloc);

        for (self.completed.items) |*item|
            item.deinit();
        self.completed.deinit(
            self.alloc,
        );
        self.map.deinit();

        self.alloc.destroy(self.pool);
    }

    pub fn loadTexture(self: *@This(), res_id: vpk.VpkResId, vpkctx: *vpk.Context) !void {
        try self.pool.spawn(workFunc, .{ self, res_id, vpkctx });
    }

    pub fn workFunc(self: *@This(), vpk_res_id: vpk.VpkResId, vpkctx: *vpk.Context) void {
        workFuncErr(self, vpk_res_id, vpkctx) catch |e| {
            log.warn("Texture failed with {} for", .{e});
        };
    }

    pub fn loadModel(self: *@This(), res_id: vpk.VpkResId, model_name: []const u8, vpkctx: *vpk.Context) !void {
        try self.pool.spawn(loadModelWorkFunc, .{ self, res_id, model_name, vpkctx });
    }

    pub fn loadModelWorkFunc(self: *@This(), res_id: vpk.VpkResId, model_name: []const u8, vpkctx: *vpk.Context) void {
        const mesh = vvd.loadModelCrappy(self, res_id, model_name, vpkctx) catch |err| {
            const LOG_FAILED_MDL = true;
            if (LOG_FAILED_MDL) {
                std.debug.print("Failed to load model: {s} with error: {t}\n", .{ model_name, err });
            }
            return;
        };
        self.completed_mutex.lock();
        defer self.completed_mutex.unlock();
        self.completed_models.append(self.alloc, mesh) catch return;
    }

    pub fn workFuncErr(self: *@This(), vpk_res_id: vpk.VpkResId, vpkctx: *vpk.Context) !void {
        var comp: CompletedVtfItem = .{
            .data = [_]?vtf.VtfBuf{null} ** ecs.Material.num_slots,
            .vpk_res_id = vpk_res_id,
            .kind = .none,
        };
        const thread_state = try self.getState();
        //const slash = std.mem.lastIndexOfScalar(u8, sl, '/') orelse break :in error.noSlash;
        if (try vpkctx.getFileFromRes(vpk_res_id, .{ .list = &thread_state.vtf_file_buffer, .alloc = thread_state.alloc })) |tt| {
            const names = vpkctx.namesFromId(vpk_res_id) orelse return error.noNames;
            if (eql(u8, names.ext, "png")) {
                //TODO is spng thread safe?

                var bmp = graph.Bitmap.initFromPngBuffer(self.alloc, tt) catch |err| {
                    std.debug.print("the png failed with {t}\n", .{err});
                    return err;
                };
                var mipLevels = std.ArrayList(vtf.VtfBuf.MipLevel){};
                try mipLevels.append(self.alloc, .{
                    .buf = try bmp.data.toOwnedSlice(bmp.alloc),
                    .w = bmp.w,
                    .h = bmp.h,
                });
                comp.data[@intFromEnum(ecs.Material.Kind.albedo)] = .{
                    .alloc = self.alloc,
                    .buffers = mipLevels,
                    .width = bmp.w,
                    .height = bmp.h,
                    .pixel_format = bmp.format.toGLFormat(),
                    .pixel_type = bmp.format.toGLType(),
                    .compressed = false,
                };

                try self.insertCompleted(comp);
            } else if (eql(u8, names.ext, "vmt")) {
                const Help = struct {
                    fn getVtfBuf(vpkc: *vpk.Context, tstate: *ThreadState, value: []const u8, alloc: std.mem.Allocator) !?vtf.VtfBuf {
                        const base_name = sanitizeVtfName(value);
                        const buf = try vtf.loadBuffer(
                            try vpkc.getFileTempFmtBuf(
                                "vtf",
                                "{s}/{s}",
                                .{ "materials", base_name },
                                .{ .list = &tstate.vtf_file_buffer, .alloc = tstate.alloc },
                                true,
                            ) orelse {
                                return null;
                            },
                            alloc,
                        );
                        return buf;
                    }
                };
                var obj = try vdf.parse(self.alloc, tt, null, .{});
                defer obj.deinit();
                //All vmt are a single root object with a shader name as key
                var was_found = false;
                if (obj.value.list.items.len > 0) {
                    const fallback_keys = [_][]const u8{
                        "$basetexture", "%tooltexture", "$bumpmap", "$normalmap", "$bottommaterial", "$iris",
                    };
                    _ = fallback_keys;
                    for (obj.value.list.items) |shader| {
                        switch (shader.val) {
                            .obj => |o| {
                                for (o.list.items) |kv| {
                                    const key = obj.stringFromId(kv.key) orelse "";
                                    var kind: ?ecs.Material.Kind = null;
                                    const val: []const u8 = if (kv.val == .literal) kv.val.literal else blk: {
                                        //>=dx90
                                        if (eql(u8, key, ">=dx90")) { //ugly hack
                                            if (kv.val.obj.getFirst(try obj.stringId("$basetexture"))) |first| {
                                                if (first == .literal) {
                                                    kind = .albedo;
                                                    break :blk first.literal;
                                                }
                                            }
                                        }
                                        continue;
                                    };

                                    if (eql(u8, key, "$basetexture") or eql(u8, key, "%tooltexture")) {
                                        kind = .albedo;
                                    } else if (eql(u8, key, "$basetexture2")) {
                                        kind = .blend;
                                    } else if (eql(u8, key, "$bumpmap")) {
                                        kind = .bump;
                                    } else {}

                                    if (kind) |k| {
                                        if (comp.data[@intFromEnum(k)] == null) {
                                            comp.data[@intFromEnum(k)] = (try Help.getVtfBuf(vpkctx, thread_state, val, self.alloc)) orelse continue;
                                            was_found = true;
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    if (!was_found and DEBUG_PRINT) {
                        std.debug.print("Vmt found but no keys found: ", .{});
                        //std.debug.print("{s}\n", .{tt});
                        std.debug.print("{s}/{s}\n", .{ names.path, names.name });

                        obj.print();
                        //std.debug.print("{s}\n", .{tt});
                    }
                    try self.insertCompleted(comp);
                }
            }
        } else {
            if (DEBUG_PRINT) {
                const names = vpkctx.namesFromId(vpk_res_id);
                if (names) |n| {
                    log.warn("Can't find texture {s}/{s}.{s}", .{ n.path, n.name, n.ext });
                } else {
                    log.warn("Can't find vtf", .{});
                }
            }
        }
    }
};

fn sanitizeVtfName(dirty: []const u8) []const u8 {
    const relative = blk: { //Strip leading slashes
        if (dirty.len == 0) break :blk dirty;
        const a = dirty[0];
        const start: usize = if (a == '\\' or a == '/') 1 else 0;
        if (start != 0) {
            //Complain to the user about their shitty textures
        }
        break :blk dirty[start..];
    };

    if (std.mem.endsWith(u8, relative, ".vtf")) {
        return relative[0 .. relative.len - ".vtf".len];
    }
    return relative;
}

//threadpool object

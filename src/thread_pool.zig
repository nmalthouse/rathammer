const std = @import("std");
const Mutex = std.Thread.Mutex;
const vtf = @import("vtf.zig");
const vpk = @import("vpk.zig");
const vdf = @import("vdf.zig");
const vvd = @import("vvd.zig");
const edit = @import("editor.zig");
const graph = @import("graph");

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
    data: vtf.VtfBuf,
    vpk_res_id: vpk.VpkResId,
    kind: enum { none, tool },
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
            item.data.deinit();
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
        const thread_state = try self.getState();
        //const slash = std.mem.lastIndexOfScalar(u8, sl, '/') orelse break :in error.noSlash;
        if (try vpkctx.getFileFromRes(vpk_res_id, .{ .list = &thread_state.vtf_file_buffer, .alloc = thread_state.alloc })) |tt| {
            const names = vpkctx.namesFromId(vpk_res_id) orelse return error.noNames;
            if (std.mem.eql(u8, names.ext, "png")) {
                //TODO is spng thread safe?

                var bmp = graph.Bitmap.initFromPngBuffer(self.alloc, tt) catch |err| {
                    std.debug.print("the png failed with {t}\n", .{err});
                    return err;
                };
                var mipLevels = std.ArrayList(vtf.VtfBuf.MipLevel){};
                try mipLevels.append(self.alloc, .{
                    .buf = try bmp.data.toOwnedSlice(),
                    .w = bmp.w,
                    .h = bmp.h,
                });

                try self.insertCompleted(.{
                    .data = .{
                        .alloc = self.alloc,
                        .buffers = mipLevels,
                        .width = bmp.w,
                        .height = bmp.h,
                        .pixel_format = bmp.format.toGLFormat(),
                        .pixel_type = bmp.format.toGLType(),
                        .compressed = false,
                    },
                    .vpk_res_id = vpk_res_id,
                    .kind = .none,
                });
            } else if (std.mem.eql(u8, names.ext, "vmt")) {
                var obj = try vdf.parse(self.alloc, tt, null, .{});
                defer obj.deinit();
                //All vmt are a single root object with a shader name as key
                var was_found = false;
                if (obj.value.list.items.len > 0) {
                    const extensions = [_][]const u8{
                        "materials",
                    };
                    const fallback_keys = [_][]const u8{
                        "$basetexture", "%tooltexture", "$bumpmap", "$normalmap", "$bottommaterial", "$iris",
                    };
                    outer: for (obj.value.list.items) |obj_val| {
                        switch (obj_val.val) {
                            .obj => |o| {
                                for (extensions) |exten| {
                                    fallback_loop: for (fallback_keys) |fbkey| {
                                        const id = try obj.stringId(fbkey);
                                        if (o.getFirst(id)) |base| {
                                            if (base == .literal) {
                                                const base_name = blk: {
                                                    if (base.literal.len == 0) break :blk base.literal;
                                                    const a = base.literal[0];
                                                    const start: usize = if (a == '\\' or a == '/') 1 else 0;
                                                    if (start != 0) {
                                                        std.debug.print("vmt specifies an absolute path, attempting to load relative: {s}/{s}\n", .{ names.path, names.name });
                                                        std.debug.print("ABSOLUTE PATHS ARE NOT RELATIVE!\n", .{});
                                                        std.debug.print("FIX YOUR FILES\n", .{});
                                                    }
                                                    break :blk base.literal[start..];
                                                };
                                                const buf = try vtf.loadBuffer(
                                                    try vpkctx.getFileTempFmtBuf(
                                                        "vtf",
                                                        "{s}/{s}",
                                                        .{ exten, base_name },
                                                        .{ .list = &thread_state.vtf_file_buffer, .alloc = thread_state.alloc },
                                                        true,
                                                    ) orelse {
                                                        continue :fallback_loop;
                                                    },
                                                    self.alloc,
                                                );
                                                was_found = true;
                                                try self.insertCompleted(.{
                                                    .data = buf,
                                                    .vpk_res_id = vpk_res_id,
                                                    .kind = if (std.mem.eql(u8, fbkey, "%tooltexture")) .tool else .none,
                                                });
                                                break :outer;
                                            }
                                        } else {
                                            //std.debug.print("!{s}\n", .{fbkey});
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    if (!was_found) {
                        std.debug.print("A texture was not found\n", .{});
                        //std.debug.print("{s}\n", .{tt});
                        std.debug.print("{s}/{s}\n", .{ names.path, names.name });
                        //std.debug.print("{s}\n", .{tt});
                    }
                }
            }
        } else {
            const names = vpkctx.namesFromId(vpk_res_id);
            if (names) |n| {
                log.warn("Can't find vtf for {s}/{s}", .{ n.path, n.name });
            } else {
                log.warn("Can't find vtf", .{});
            }
        }
    }
};

//threadpool object

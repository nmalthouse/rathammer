const std = @import("std");
const thread_pool = @import("thread_pool.zig");
const Context = @import("editor.zig").Context;
const graph = @import("graph");
const compile_conf = @import("config");
const vpk = @import("vpk.zig");

pub const JobTemplate = struct {
    //Jobs must implement iJob vtable
    job: thread_pool.iJob,
    //Used to put the finished job in list
    pool_ptr: *thread_pool.Context,

    alloc: std.mem.Allocator,

    pub fn spawn(alloc: std.mem.Allocator, pool: *thread_pool.Context) !void {
        const self = try alloc.create(@This());
        self.* = .{
            .job = .{ .onComplete = &onComplete, .user_id = 0 },
            .alloc = alloc,
            .pool_ptr = pool,
        };
        try pool.spawnJob(workFunc, .{self});
    }

    pub fn destroy(self: *@This()) void {
        self.alloc.destroy(self);
    }

    // Called from self.spawn in a worker thread
    pub fn workFunc(self: *@This()) void {
        self.pool_ptr.insertCompletedJob(&self.job) catch {};
    }

    // Called from main thread.
    pub fn onComplete(vt: *thread_pool.iJob, edit: *Context) void {
        const self: *@This() = @alignCast(@fieldParentPtr("job", vt));
        defer self.destroy();
        _ = edit;
    }
};

/// This will destroy() itself onComplete()
const log = std.log.scoped(.Async);
pub const SdlFileData = struct {
    pub const Action = enum {
        save_map,
        pick_map,
    };
    const map_filters = [_]graph.c.SDL_DialogFileFilter{
        .{ .name = "maps", .pattern = "json;vmf;ratmap" },
        .{ .name = "vmf maps", .pattern = "vmf" },
        .{ .name = "RatHammer json maps", .pattern = "json" },
        .{ .name = "RatHammer maps", .pattern = "ratmap" },
        .{ .name = "All files", .pattern = "*" },
    };
    action: Action,

    job: thread_pool.iJob,
    has_file: enum { waiting, failed, has } = .waiting,

    pool_ptr: *thread_pool.Context,

    alloc: std.mem.Allocator,
    name_buffer: std.ArrayList(u8),

    pub fn spawn(alloc: std.mem.Allocator, pool: *thread_pool.Context, kind: Action) !void {
        const self = try alloc.create(@This());
        self.* = .{
            .job = .{ .onComplete = &onComplete, .user_id = 0 },
            .name_buffer = .{},
            .alloc = alloc,
            .pool_ptr = pool,
            .action = kind,
        };

        try pool.spawnJob(workFunc, .{self});
    }

    pub fn destroy(self: *@This()) void {
        const alloc = self.alloc;
        self.name_buffer.deinit(self.alloc);
        alloc.destroy(self);
    }

    pub fn onComplete(vt: *thread_pool.iJob, edit: *Context) void {
        const self: *@This() = @alignCast(@fieldParentPtr("job", vt));
        defer self.destroy();
        if (self.has_file != .has) return;
        switch (self.action) {
            .save_map => {
                edit.setMapName(self.name_buffer.items) catch return;
                if (edit.loaded_map_name) |basename| {
                    edit.saveAndNotify(basename, edit.loaded_map_path orelse "") catch return;
                }
            },
            .pick_map => {
                edit.loadctx.setDraw(true); // Renable it
                edit.paused = false;
                edit.loadctx.resetTime();
                edit.loadMap(std.fs.cwd(), self.name_buffer.items, edit.loadctx) catch |err| {
                    std.debug.print("load failed because {t}\n", .{err});
                };
            },
        }
    }

    pub fn workFunc(self: *@This()) void {
        switch (self.action) {
            .save_map => graph.c.SDL_ShowSaveFileDialog(&saveFileCallback2, self, null, null, 0, null),
            .pick_map => graph.c.SDL_ShowOpenFileDialog(&saveFileCallback2, self, null, &map_filters, map_filters.len, null, false),
        }
    }

    export fn saveFileCallback2(opaque_self: ?*anyopaque, filelist: [*c]const [*c]const u8, index: c_int) void {
        if (opaque_self) |ud| {
            const self: *SdlFileData = @ptrCast(@alignCast(ud));
            defer self.pool_ptr.insertCompletedJob(&self.job) catch {};

            if (filelist == 0 or filelist[0] == 0) {
                self.has_file = .failed;
                return;
            }

            const first = std.mem.span(filelist[0]);
            if (first.len == 0) {
                self.has_file = .failed;
                return;
            }

            self.name_buffer.clearRetainingCapacity();
            self.name_buffer.appendSlice(self.alloc, first) catch return;
            self.has_file = .has;
        }
        _ = index;
    }
};

//TODO, make this a singleton, if user tries spawning a second, kill the first and replace
//This will a require mapbuild to have a mutex and callback in its 'runCommand' to kill it
const map_builder = @import("map_builder.zig");
pub const MapCompile = struct {
    pub const Kind = enum {
        builtin,
        user_script,
    };
    job: thread_pool.iJob,
    pool_ptr: *thread_pool.Context,

    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    build_time: std.time.Timer,

    status: enum { failed, built, nothing } = .nothing,

    map_name: []const u8,

    pub fn spawn(alloc: std.mem.Allocator, pool: *thread_pool.Context, paths: map_builder.Paths, kind: Kind) !void {
        const self = try alloc.create(@This());
        self.* = .{
            .job = .{
                .user_id = 0,
                .onComplete = &onComplete,
            },
            .build_time = try std.time.Timer.start(),
            .arena = std.heap.ArenaAllocator.init(alloc),
            .alloc = alloc,
            .pool_ptr = pool,
            .map_name = "",
        };
        const aa = self.arena.allocator();
        self.map_name = try aa.dupe(u8, paths.vmf);
        switch (kind) {
            inline else => |e| try pool.spawnJob(switch (e) {
                .user_script => workFuncUser,
                .builtin => workFunc,
            }, .{ self, map_builder.Paths{
                .cwd_path = try aa.dupe(u8, paths.cwd_path),
                .gamename = try aa.dupe(u8, paths.gamename),
                .gamedir_pre = try aa.dupe(u8, paths.gamedir_pre),
                .exedir_pre = try aa.dupe(u8, paths.exedir_pre),
                .tmpdir = try aa.dupe(u8, paths.tmpdir),
                .outputdir = try aa.dupe(u8, paths.outputdir),
                .vmf = try aa.dupe(u8, paths.vmf),
                .user_cmd = try aa.dupe(u8, paths.user_cmd),
            } }),
        }
    }

    pub fn destroy(self: *@This()) void {
        self.arena.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    pub fn onComplete(vt: *thread_pool.iJob, edit: *Context) void {
        const self: *@This() = @alignCast(@fieldParentPtr("job", vt));
        defer self.destroy();
        const t = self.build_time.read();
        switch (self.status) {
            .failed => {
                edit.notify("Error building Map", .{}, 0xff0000ff) catch {};
            },
            .built => {
                edit.notify("built {s} in {d} s", .{ self.map_name, t / std.time.ns_per_s }, 0x00ff00ff) catch {};
            },
            .nothing => edit.notify("Something bad happend when building the map", .{}, 0xffff_00_ff) catch {},
        }
    }

    pub fn workFuncUser(self: *@This(), args: map_builder.Paths) void {
        defer self.pool_ptr.insertCompletedJob(&self.job) catch {};
        if (map_builder.runUserBuildCommand(self.arena.allocator(), args)) {
            self.status = .built;
        } else |err| {
            log.err("Build map failed with : {t}", .{err});
            self.status = .failed;
        }
    }

    pub fn workFunc(self: *@This(), args: map_builder.Paths) void {
        defer self.pool_ptr.insertCompletedJob(&self.job) catch {};
        if (map_builder.buildmap(self.arena.allocator(), args)) {
            self.status = .built;
        } else |err| {
            log.err("Build map failed with : {t}", .{err});
            self.status = .failed;
        }
    }
};

pub const CompressAndSave = struct {
    const Opts = struct {
        dir: std.fs.Dir,
        name: []const u8,
        json_buffer: []const u8,
        thumbnail: ?graph.Bitmap,
    };
    job: thread_pool.iJob,
    pool_ptr: *thread_pool.Context,

    alloc: std.mem.Allocator,
    json_buf: []const u8,

    dir: std.fs.Dir,
    filename: []const u8,
    status: enum { failed, built, nothing } = .nothing,
    thumb: ?graph.Bitmap,

    //Closes the passed in dir handle
    pub fn spawn(alloc: std.mem.Allocator, pool: *thread_pool.Context, opts: Opts) !void {
        const self = try alloc.create(@This());
        self.* = .{
            .job = .{
                .user_id = 0,
                .onComplete = &onComplete,
            },
            .thumb = opts.thumbnail,
            .alloc = alloc,
            .json_buf = opts.json_buffer,
            .pool_ptr = pool,
            .dir = opts.dir,
            .filename = try alloc.dupe(u8, opts.name),
        };
        try pool.spawnJob(workFunc, .{self});
    }

    pub fn destroy(self: *@This()) void {
        self.alloc.free(self.json_buf);
        self.dir.close();
        self.alloc.free(self.filename);
        if (self.thumb) |th|
            th.deinit();

        const alloc = self.alloc;
        alloc.destroy(self);
    }

    pub fn onComplete(vt: *thread_pool.iJob, edit: *Context) void {
        const self: *@This() = @alignCast(@fieldParentPtr("job", vt));
        defer self.destroy();
        switch (self.status) {
            .nothing, .failed => edit.notify("Unable to compress map nothing written", .{}, 0xff0000ff) catch {},
            .built => {
                edit.notify("Compressed map", .{}, 0x00ff00ff) catch {};
                if (edit.getMapFullPath()) |full_path| {
                    edit.addRecentMap(full_path) catch |err| {
                        std.debug.print("Failed to write recent maps {t}\n", .{err});
                    };
                } else {
                    std.debug.print("Failed to get map full path\n", .{});
                }
            },
        }
    }

    pub fn workFunc(self: *@This()) void {
        defer self.pool_ptr.insertCompletedJob(&self.job) catch {};

        var compressed = std.Io.Writer.Allocating.init(self.alloc);
        defer compressed.deinit();
        if (graph.miniz.compressGzip(self.alloc, self.json_buf, &compressed.writer)) |_| {} else |err| {
            log.err("compress failed {t}", .{err});
            self.status = .failed;
            return;
        }

        var copy_name: std.ArrayList(u8) = .{};
        defer copy_name.deinit(self.alloc);
        copy_name.appendSlice(self.alloc, self.filename) catch return;
        copy_name.appendSlice(self.alloc, ".saving") catch return;

        {
            const file = self.dir.createFile(copy_name.items, .{}) catch |err| {
                log.err("unable to create file {s} aborting with {t}", .{ copy_name.items, err });
                return;
            };
            defer file.close();
            var write_buffer: [2048]u8 = undefined;
            var wr = file.writer(&write_buffer);

            var tar_wr = std.tar.Writer{ .underlying_writer = &wr.interface };

            if (self.thumb) |th| {
                var qd = graph.c.qoi_desc{
                    .width = th.w,
                    .height = th.h,
                    .channels = 3,
                    .colorspace = graph.c.QOI_LINEAR,
                };
                var qoi_len: c_int = 0;
                if (graph.c.qoi_encode(&th.data.items[0], &qd, &qoi_len)) |qoi_data| {
                    const qoi_s: [*c]const u8 = @ptrCast(qoi_data);
                    const qlen: usize = if (qoi_len > 0) @intCast(qoi_len) else 0;
                    const slice: []const u8 = qoi_s[0..qlen];
                    tar_wr.writeFileBytes("thumbnail.qoi", slice, .{}) catch |err| {
                        log.warn("unable to write thumbnail {t}", .{err});
                    };
                    graph.c.QOI_FREE(qoi_data);
                }
            }

            tar_wr.writeFileBytes("map.json.gz", compressed.written(), .{}) catch |err| {
                log.err("file write failed {t}", .{err});
                self.status = .failed;
                return;
            };

            wr.interface.flush() catch {};
            self.status = .built;
        }
        // saving file was written, copy then delete
        self.dir.copyFile(copy_name.items, self.dir, self.filename, .{}) catch |err| {
            log.err("unable to copy {s} to {s} with {t}", .{ copy_name.items, self.filename, err });
            return;
        };

        self.dir.deleteFile(copy_name.items) catch |err| {
            log.err("unable to delete {s} with {t}", .{ copy_name.items, err });
            return;
        };
    }
};

pub const CheckVersionHttp = struct {
    const version = @import("version.zig");
    job: thread_pool.iJob,
    pool_ptr: *thread_pool.Context,

    alloc: std.mem.Allocator,
    new_version: ?[]const u8 = null,

    pub fn spawn(alloc: std.mem.Allocator, pool: *thread_pool.Context) !void {
        const self = try alloc.create(@This());
        self.* = .{
            .job = .{ .onComplete = &onComplete, .user_id = 0 },
            .alloc = alloc,
            .pool_ptr = pool,
        };
        try pool.spawnJob(workFunc, .{self});
    }

    pub fn destroy(self: *@This()) void {
        if (self.new_version) |nv|
            self.alloc.free(nv);
        self.alloc.destroy(self);
    }

    pub fn workFunc(self: *@This()) void {
        self.workFuncErr() catch |err| {
            log.err("Version check failed: {t}", .{err});
        };
    }

    // Called from self.spawn in a worker thread
    fn workFuncErr(self: *@This()) !void {
        if (comptime compile_conf.http_version_check) {
            var client = std.http.Client{
                .allocator = self.alloc,
            };
            defer client.deinit();
            var header_buf: [1024]u8 = undefined;

            const default_uri = "http://nmalthouse.net:80/api/version";
            const uri = compile_conf.http_version_check_url orelse default_uri;

            var req = try client.request(.GET, try std.Uri.parse(uri), .{ .headers = .{
                .user_agent = .{
                    .override = "zig " ++ version.version_string,
                },
            } });
            defer req.deinit();

            try req.sendBodiless();

            var buf: [16]u8 = undefined;
            var resp = try req.receiveHead(&header_buf);
            var resp_read = resp.reader(&buf);

            if (try resp_read.takeDelimiter(0)) |answer| {
                log.info("Version check {s}", .{answer});
                const server_version = try std.SemanticVersion.parse(answer);
                const client_version = try std.SemanticVersion.parse(version.version);
                if (std.SemanticVersion.order(server_version, client_version) == .gt) {
                    self.new_version = try self.alloc.dupe(u8, answer);
                }
            }
        }

        self.pool_ptr.insertCompletedJob(&self.job) catch {};
    }

    // Called from main thread.
    pub fn onComplete(vt: *thread_pool.iJob, edit: *Context) void {
        const self: *@This() = @alignCast(@fieldParentPtr("job", vt));
        defer self.destroy();
        if (self.new_version) |nv| {
            edit.notify("New version available: {s}", .{nv}, 0x00ff00ff) catch {};
            edit.notify("Current version: {s}", .{version.version}, 0xfca73fff) catch {};
        }
    }
};

pub const QoiDecode = struct {
    //Jobs must implement iJob vtable
    job: thread_pool.iJob,
    //Used to put the finished job in list
    pool_ptr: *thread_pool.Context,

    alloc: std.mem.Allocator,

    qoi_buf: []const u8,

    bitmap: ?graph.Bitmap = null,
    id: vpk.VpkResId,

    /// Assumes qoi_buf was allocated with passed in alloc,
    /// takes ownership of qoi_buf
    pub fn spawn(alloc: std.mem.Allocator, pool: *thread_pool.Context, qoi_buf: []const u8, id: vpk.VpkResId) !void {
        const self = try alloc.create(@This());
        self.* = .{
            .job = .{ .onComplete = &onComplete, .user_id = 0 },
            .alloc = alloc,
            .pool_ptr = pool,
            .qoi_buf = qoi_buf,
            .id = id,
        };
        try pool.spawnJob(workFunc, .{self});
    }

    pub fn destroy(self: *@This()) void {
        if (self.bitmap) |*bmp|
            bmp.deinit();
        self.alloc.free(self.qoi_buf);
        self.alloc.destroy(self);
    }

    // Called from self.spawn in a worker thread
    pub fn workFunc(self: *@This()) void {
        _ = D: {
            self.bitmap = graph.Bitmap.initFromQoiBuffer(self.alloc, self.qoi_buf) catch break :D;
        };
        self.pool_ptr.insertCompletedJob(&self.job) catch {};
    }

    // Called from main thread.
    pub fn onComplete(vt: *thread_pool.iJob, edit: *Context) void {
        const self: *@This() = @alignCast(@fieldParentPtr("job", vt));
        defer self.destroy();

        if (self.bitmap) |bmp|
            edit.textures.put(self.id, graph.Texture.initFromBitmap(bmp, .{})) catch {};
    }
};

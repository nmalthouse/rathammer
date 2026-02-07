const std = @import("std");
const profile = @import("profile.zig");
const util = @import("util.zig");
const VPK_FILE_SIG: u32 = 0x55aa1234;
const StringStorage = @import("string.zig").StringStorage;

pub threadlocal var timer = profile.BasicProfiler.init();
threadlocal var error_msg_buffer: [1024]u8 = undefined;

const config = @import("config");
const vpk_dump_file_t = if (config.dump_vpk) std.fs.File else void;

pub const VpkResId = u64;
pub const ManagedBuf = struct {
    alloc: std.mem.Allocator,
    list: *std.ArrayList(u8),
};

const GameId = enum(u8) {
    _,
};

pub const Game = struct {
    pub const Default = Game{ .u_scale = 0.25, .v_scale = 0.25 };
    u_scale: f32,
    v_scale: f32,
};

pub const IdOrName = union(enum) {
    id: VpkResId,
    name: []const u8,
};

pub const IdAndName = struct {
    id: VpkResId,
    name: []const u8,
};
///16 bits: extension_index
///16 bits: path_index
///32 bits: entry_index
pub fn encodeResourceId(extension_index: u64, path_index: u64, entry_index: u64) VpkResId {
    std.debug.assert(extension_index < 0xffff);
    std.debug.assert(path_index < 0xffff);
    std.debug.assert(entry_index < 0xff_ff_ff_ff);
    //Assert all are below accepted values
    return extension_index << 48 | path_index << 32 | entry_index;
}
/// All identifiers within the vpk are lowercased and \ -> /
/// The same is done to all resources specified in source engine formats (vmf, vmt, mdl)
/// This means any resources in loose directories must be lower case to get loaded.
pub fn sanatizeVpkString(str: []u8) void {
    for (str) |*ch| {
        ch.* = switch (ch.*) {
            '\\' => '/',
            'A'...'Z' => ch.* | 0b00100000, //Lowercase
            else => ch.*,
        };
    }
}

pub fn decodeResourceId(id: VpkResId) struct {
    ext: u64,
    path: u64,
    name: u64,
} {
    return .{
        .ext = id >> 48,
        .path = id << 16 >> (32 + 16),
        .name = id << 32 >> 32,
    };
}

/// Given one or more vpk dir files, allows you to request file contents
pub const Context = struct {
    const log = std.log.scoped(.vpk);
    const Self = @This();
    const StrCtx = std.hash_map.StringContext;
    pub const Names = struct {
        ext: []const u8,
        path: []const u8,
        name: []const u8,
    };

    /// Map a resource string to numeric id
    const IdMap = struct {
        /// All strings are stored by parent vpk.Context.arena
        alloc: std.mem.Allocator,
        map: std.StringArrayHashMapUnmanaged(u32),
        lut: std.ArrayListUnmanaged([]const u8), //Strings owned by arena
        counter: u32 = 0,
        mutex: std.Thread.Mutex = .{},

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{ .map = .{}, .lut = .{}, .alloc = alloc };
        }

        pub fn deinit(self: *@This()) void {
            self.mutex.lock();
            self.map.deinit(self.alloc);
            self.lut.deinit(self.alloc);
        }

        pub fn getName(self: *@This(), id: u32) ?[]const u8 {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (id == 0) return null;
            if (id - 1 >= self.lut.items.len) return null;
            return self.lut.items[id - 1];
        }

        pub fn getPut(self: *@This(), res_name: []const u8) !u32 {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.map.get(res_name)) |entry| return entry;

            self.counter += 1;
            const new_id = self.counter;
            try self.lut.append(self.alloc, res_name);
            try self.map.put(self.alloc, res_name, new_id);
            return new_id;
        }

        pub fn get(self: *@This(), res_name: []const u8) ?u32 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.get(res_name);
        }
    };

    const Dir = struct {
        prefix: []const u8,

        fds: std.AutoHashMap(u16, std.fs.File),
        root: std.fs.Dir,

        pub fn init(alloc: std.mem.Allocator, prefix: []const u8, root: std.fs.Dir) @This() {
            return .{
                .fds = std.AutoHashMap(u16, std.fs.File).init(alloc),
                .prefix = prefix,
                .root = root,
            };
        }

        pub fn deinit(self: *@This()) void {
            var it = self.fds.valueIterator();
            while (it.next()) |f|
                f.close();
            self.fds.deinit();
        }
    };

    const Entry = struct {
        path: []const u8,
        name: []const u8,
        res_id: VpkResId,

        game: GameId,

        location: union(enum) {
            vpk: VpkEntry,
            loose: LooseEntry,
        },
    };

    const LooseEntry = struct {
        dir_index: u16,
    };

    const VpkEntry = struct {
        dir_index: u16,
        archive_index: u16,
        offset: u32,
        length: u32,
    };

    /// These map the strings found in vpk to a numeric id.
    /// Ids are not unique between maps. using encodeResourceId they uniquely identify any resource.
    /// Id's are not derived from the string, but the load order.
    extension_map: IdMap,
    path_map: IdMap,
    res_map: IdMap,

    /// This maps a encodeResourceId id to a vpk entry
    entries: std.AutoArrayHashMapUnmanaged(VpkResId, Entry) = .{},

    loose_dirs: std.ArrayList(struct { dir: std.fs.Dir, game_id: GameId }) = .{},
    dirs: std.ArrayList(Dir) = .{},
    /// Stores all long lived strings used by vpkctx. Mostly keys into IdMap
    string_storage: StringStorage,

    alloc: std.mem.Allocator,

    /// Scratch buffers
    strbuf: std.ArrayList(u8) = .{},
    name_buf: std.ArrayList(u8) = .{},
    split_buf: std.ArrayList(u8) = .{},
    filebuf: std.ArrayList(u8) = .{},

    /// File object to optionally dump contents of all mounted vpk's
    vpk_dump_file: vpk_dump_file_t,

    mutex: std.Thread.Mutex = .{},

    gameinfos: std.StringArrayHashMap(Game),

    pub fn init(alloc: std.mem.Allocator) !Self {
        return .{
            .gameinfos = .init(alloc),
            .extension_map = IdMap.init(alloc),
            .path_map = IdMap.init(alloc),
            .res_map = IdMap.init(alloc),
            .string_storage = try StringStorage.init(alloc),
            .alloc = alloc,
            .vpk_dump_file = if (config.dump_vpk) try std.fs.cwd().createFile("vpkdump.txt", .{}) else {},
        };
    }

    pub fn deinit(self: *Self) void {
        if (config.dump_vpk)
            self.vpk_dump_file.close();
        self.string_storage.deinit();
        for (self.dirs.items) |*dir| {
            dir.deinit();
        }
        self.dirs.deinit(self.alloc);
        self.strbuf.deinit(self.alloc);
        self.filebuf.deinit(self.alloc);
        self.split_buf.deinit(self.alloc);
        for (self.loose_dirs.items) |*dir|
            dir.dir.close();
        self.loose_dirs.deinit(self.alloc);
        self.gameinfos.deinit();

        self.name_buf.deinit(self.alloc);
        self.extension_map.deinit();
        self.path_map.deinit();
        self.res_map.deinit();
        self.entries.deinit(self.alloc);
    }

    //Not thread safe
    fn namesFromId_(self: *Self, id: VpkResId) ?Names {
        const ids = decodeResourceId(id);
        return .{
            .name = self.res_map.getName(@intCast(ids.name)) orelse return null,
            .ext = self.extension_map.getName(@intCast(ids.ext)) orelse return null,
            .path = self.path_map.getName(@intCast(ids.path)) orelse return null,
        };
    }

    /// Thread safe
    pub fn namesFromId(self: *Self, id: VpkResId) ?Names {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.namesFromId_(id);
    }

    pub fn getResource(self: *Self, id: VpkResId) ?[]const u8 {
        if (self.namesFromId(id)) |names| {
            self.name_buf.clearRetainingCapacity();
            self.name_buf.print(self.alloc, "{s}/{s}.{s}", .{
                names.path,
                names.name,
                names.ext,
            }) catch return null;
            return self.name_buf.items;
        }
        return null;
    }

    /// clobbers and returns memory from namebuf
    pub fn resolveId(self: *Self, id: IdOrName, sanitize: bool) !?IdAndName {
        self.name_buf.clearRetainingCapacity();
        switch (id) {
            .id => |idd| {
                const names = self.namesFromId(idd) orelse return null;
                try self.name_buf.print(self.alloc, "{s}/{s}.{s}", .{ names.path, names.name, names.ext });
                return .{
                    .id = idd,
                    .name = self.name_buf.items,
                };
            },
            .name => |name| {
                const idd = try self.getResourceIdString(name, sanitize) orelse return null;

                try self.name_buf.appendSlice(self.alloc, name);
                return .{
                    .id = idd,
                    .name = self.name_buf.items,
                };
            },
        }
    }

    fn writeDump(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (config.dump_vpk) {
            self.vpk_dump_file.writer().print(fmt, args) catch return;
        }
    }

    pub fn addLooseDir(self: *Self, root: std.fs.Dir, path: []const u8, game_dir_name: []const u8, game: Game) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.loose_dirs.append(self.alloc, .{ .dir = try root.openDir(path, .{}), .game_id = try self.getOrPutGame(game_dir_name, game) });
    }

    pub fn getGame(self: *Self, vpkid: VpkResId) ?Game {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.get(vpkid)) |ent| {
            return self.gameinfos.values()[@intFromEnum(ent.game)];
        }
        return null;
    }

    pub fn slowIndexOfLooseDirSubPath(self: *Self, subpath: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var strbuf = std.ArrayList(u8){};
        defer strbuf.deinit(self.alloc);
        try strbuf.appendSlice(self.alloc, subpath);
        //TODO Check for the damn backslash too
        if (!std.mem.endsWith(u8, subpath, "/")) {
            try strbuf.append(self.alloc, '/');
        }
        const prefix_len = strbuf.items.len;
        for (self.loose_dirs.items, 0..) |loose_dir, dir_index| {
            if (loose_dir.dir.openDir(subpath, .{ .iterate = true })) |sub_dir| {
                var walker = try sub_dir.walk(self.alloc);
                defer walker.deinit();
                while (try walker.next()) |file| {
                    switch (file.kind) {
                        .file => {
                            try strbuf.resize(self.alloc, prefix_len);
                            try strbuf.appendSlice(self.alloc, file.path);
                            //sanatizeVpkString(strbuf.items);
                            const split = splitPath(strbuf.items);

                            const ext_stored = try self.string_storage.store(split.ext);
                            const ext_id = try self.extension_map.getPut(ext_stored);
                            const path_stored = try self.string_storage.store(split.path);
                            const path_id = try self.path_map.getPut(path_stored);

                            const fname_stored = try self.string_storage.store(split.name);
                            const fname_id = try self.res_map.getPut(fname_stored);
                            const res_id = encodeResourceId(ext_id, path_id, fname_id);
                            const entry = try self.entries.getOrPut(self.alloc, res_id);
                            if (!entry.found_existing) {
                                entry.value_ptr.* = Entry{
                                    .game = loose_dir.game_id,
                                    .res_id = res_id,
                                    .path = path_stored,
                                    .name = fname_stored,
                                    .location = .{ .loose = .{ .dir_index = @intCast(dir_index) } },
                                };
                            } else {}
                        },
                        else => {},
                    }
                }
            } else |_| {} //Not having the subpath is fine too.
        }
    }

    /// the vpk_set: hl2_pak.vpk -> hl2_pak_dir.vpk . This matches the way gameinfo.txt does it
    /// The passed in root dir must remain alive.
    pub fn addDir(
        self: *Self,
        root: std.fs.Dir,
        vpk_set: []const u8,
        loadctx: anytype,
        game_dir_name: []const u8,
        game: Game,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const game_id = try self.getOrPutGame(game_dir_name, game);
        if (!std.mem.endsWith(u8, vpk_set, ".vpk")) {
            log.err("Invalid vpk set: {s}", .{vpk_set});
            log.err("Vpk sets should be in the format: 'hl2_pak.vpk' which maps to the files: hl2_pak_xxx.vpk", .{});
            log.err("See hl2/gameinfo.txt for examples", .{});
            return error.invalidVpkSet;
        }
        timer.start();
        defer timer.end();
        const prefix = vpk_set[0 .. vpk_set.len - ".vpk".len];
        var new_dir = Dir.init(self.alloc, try self.string_storage.store(prefix), root);
        const dir_index = self.dirs.items.len;

        var strbuf = std.ArrayList(u8){};
        defer strbuf.deinit(self.alloc);
        try strbuf.print(self.alloc, "{s}_dir.vpk", .{prefix});
        self.writeDump("VPK NAME: {s}\n", .{prefix});

        const file_name = try self.string_storage.store(strbuf.items);
        const infile = root.openFile(strbuf.items, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                log.err("Couldn't find vpk: {s} with given set: {s}", .{ strbuf.items, vpk_set });
                const path = root.realpath(".", &error_msg_buffer) catch "realpathFailed";
                log.err("Search directory path is: {s}/{s}", .{ path, strbuf.items });
                return error.FileNotFound;
            },
            else => return err,
        };
        // 0x7fff is the marker for files stored inside the dir.vpk
        try new_dir.fds.put(0x7fff, infile);
        try self.dirs.append(self.alloc, new_dir);

        self.filebuf.clearRetainingCapacity();
        var buf: [4096]u8 = undefined;
        var re = infile.reader(&buf);
        const slice = try re.interface.allocRemaining(self.alloc, .unlimited);
        defer self.alloc.free(slice);

        var reader: std.Io.Reader = .fixed(slice);
        const r = &reader;

        const sig = try r.takeInt(u32, .little);
        if (sig != VPK_FILE_SIG)
            return error.invalidVpk;
        const version = try r.takeInt(u32, .little);
        const header_size: u32 = switch (version) {
            1 => 12,
            2 => 28,
            else => return error.unsupportedVpkVersion,
        };
        switch (version) {
            1 => {
                const tree_size = try r.takeInt(u32, .little);
                loadctx.addExpected(10);
                try parseVpkDirCommon(self, loadctx, r, tree_size, header_size, dir_index, true, game_id);
            },
            2 => {
                const tree_size = try r.takeInt(u32, .little);
                const filedata_section_size = try r.takeInt(u32, .little);
                const archive_md5_sec_size = try r.takeInt(u32, .little);
                const other_md5_sec_size = try r.takeInt(u32, .little);
                const sig_sec_size = try r.takeInt(u32, .little);
                _ = sig_sec_size;
                _ = archive_md5_sec_size;
                _ = filedata_section_size;

                if (other_md5_sec_size != 48) return error.invalidMd5Size;

                loadctx.addExpected(10);
                try parseVpkDirCommon(self, loadctx, r, tree_size, header_size, dir_index, false, game_id);
            },
            else => {
                log.err("Unsupported vpk version {d}, file: {s}", .{ version, file_name });
                return error.unsupportedVpkVersion;
            },
        }
    }

    /// Only call this from the main thread.
    pub fn getFileTempFmt(self: *Self, extension: []const u8, comptime fmt: []const u8, args: anytype, sanitize: bool) !?[]const u8 {
        //Also , race condition
        return self.getFileTempFmtBuf(extension, fmt, args, .{ .list = &self.filebuf, .alloc = self.alloc }, sanitize);
    }

    pub fn getFileTempFmtBuf(self: *Self, extension: []const u8, comptime fmt: []const u8, args: anytype, buf: ManagedBuf, sanitize: bool) !?[]const u8 {
        const res_id = try self.getResourceIdFmt(extension, fmt, args, sanitize) orelse return null;
        return try self.getFileFromRes(res_id, buf);
    }

    /// Returns a buffer owned by Self which will be clobberd on next getFileTemp call
    /// Only call this from the main thread
    pub fn getFileTemp(self: *Self, extension: []const u8, path: []const u8, name: []const u8) !?[]const u8 {
        const res_id = try self.getResourceId(extension, path, name) orelse return null;
        self.filebuf.clearRetainingCapacity();
        //the pointer is passed before mutex is locked, if another thread is resizing filebuf the ptr is invalid
        //In practice this shouldn't be a problem because only the main thread should ever call getFileTemp.
        return self.getFileFromRes(res_id, .{ .list = &self.filebuf, .alloc = self.alloc });
    }

    // Thread safe
    pub fn getResourceId(self: *Self, extension: []const u8, path: []const u8, fname: []const u8) ?VpkResId {
        const ex = self.string_storage.store(extension) catch return null;
        const p = self.string_storage.store(path) catch return null;
        const fnam = self.string_storage.store(fname) catch return null;
        return encodeResourceId(
            self.extension_map.getPut(ex) catch return null,
            self.path_map.getPut(p) catch return null,
            self.res_map.getPut(fnam) catch return null,
        );
    }

    /// Thread safe
    pub fn getResourceIdFmt(self: *Self, ext: []const u8, comptime fmt: []const u8, args: anytype, sanitize: bool) !?VpkResId {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.split_buf.clearRetainingCapacity();
        try self.split_buf.print(self.alloc, fmt, args);
        if (sanitize)
            sanatizeVpkString(self.split_buf.items);
        //_ = std.ascii.lowerString(self.split_buf.items, self.split_buf.items);
        const sl = self.split_buf.items;
        const slash = std.mem.lastIndexOfScalar(u8, sl, '/') orelse return error.noSlash;

        return self.getResourceId(ext, sl[0..slash], sl[slash + 1 ..]);
    }

    pub fn getResourceIdString(self: *Self, name: []const u8, sanitize: bool) !?VpkResId {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.split_buf.clearRetainingCapacity();
        _ = try self.split_buf.print(self.alloc, "{s}", .{name});
        if (sanitize)
            sanatizeVpkString(self.split_buf.items);
        //_ = std.ascii.lowerString(self.split_buf.items, self.split_buf.items);
        const sl = self.split_buf.items;
        const slash = std.mem.lastIndexOfScalar(u8, sl, '/') orelse return error.noSlash;
        const dot = std.mem.lastIndexOfScalar(u8, sl, '.') orelse return error.noExt;

        const path = sl[0..slash];
        const ext = sl[dot + 1 ..]; //Eat the dot
        const name_ = sl[slash + 1 .. dot];

        return self.getResourceId(ext, path, name_);
    }

    /// Thread safe
    pub fn getFileFromRes(self: *Self, res_id: VpkResId, buf: ManagedBuf) !?[]const u8 {
        var read_buffer: [1024]u8 = undefined;
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.entries.get(res_id) orelse {
            const names = self.namesFromId_(res_id) orelse return null;
            self.strbuf.clearRetainingCapacity();
            try self.strbuf.print(self.alloc, "{s}/{s}.{s}", .{ names.path, names.name, names.ext });
            //std.debug.print("Searching loose dir for {s} \n", .{self.strbuf.items});
            for (self.loose_dirs.items) |ldir| {
                const infile = ldir.dir.openFile(self.strbuf.items, .{}) catch continue;
                defer infile.close();
                buf.list.clearRetainingCapacity();
                var re = infile.reader(&read_buffer);
                try re.interface.appendRemaining(buf.alloc, buf.list, .unlimited);
                return buf.list.items;
            }
            return null;
        };
        switch (entry.location) {
            .loose => |lo| {
                const names = self.namesFromId_(res_id) orelse return null;
                self.strbuf.clearRetainingCapacity();
                try self.strbuf.print(self.alloc, "{s}/{s}.{s}", .{ names.path, names.name, names.ext });
                //std.debug.print("Searching loose dir for {s} \n", .{self.strbuf.items});
                if (lo.dir_index >= self.loose_dirs.items.len) return null;
                const ldir = self.loose_dirs.items[lo.dir_index];

                const infile = ldir.dir.openFile(self.strbuf.items, .{}) catch return null;
                defer infile.close();
                buf.list.clearRetainingCapacity();
                var re = infile.reader(&read_buffer);
                try re.interface.appendRemaining(buf.alloc, buf.list, .unlimited);
                return buf.list.items;
            },
            .vpk => |v| {
                const dir = self.getDir(v.dir_index) orelse return null;
                const res = try dir.fds.getOrPut(v.archive_index);
                if (!res.found_existing) {
                    errdefer _ = dir.fds.remove(v.archive_index); //Prevent closing an unopened file messing with stack trace
                    self.strbuf.clearRetainingCapacity();
                    try self.strbuf.print(self.alloc, "{s}_{d:0>3}.vpk", .{ dir.prefix, v.archive_index });

                    res.value_ptr.* = dir.root.openFile(self.strbuf.items, .{}) catch |err| switch (err) {
                        error.FileNotFound => {
                            log.err("Couldn't open vpk file: {s}", .{self.strbuf.items});
                            return err;
                        },
                        else => return err,
                    };
                }

                try buf.list.resize(buf.alloc, v.length);
                try res.value_ptr.seekTo(v.offset);
                var read = res.value_ptr.reader(&read_buffer);
                try read.seekTo(v.offset);
                try read.interface.readSliceAll(buf.list.items);
                return buf.list.items;
            },
        }
    }

    /// The pointer to Dir may be invalidated if addDir is called
    pub fn getDir(self: *Self, dir_index: u16) ?*Dir {
        if (dir_index < self.dirs.items.len) {
            return &self.dirs.items[dir_index];
        }
        return null;
    }

    /// not thread safe
    fn getOrPutGame(self: *Self, game_name_user: []const u8, game: Game) !GameId {
        const game_name = try self.string_storage.store(game_name_user);
        const res = try self.gameinfos.getOrPut(game_name);
        res.value_ptr.* = game;
        if (res.index > std.math.maxInt(@typeInfo(GameId).@"enum".tag_type)) return error.tooManyGames;
        return @enumFromInt(res.index);
    }
};

fn parseVpkDirCommon(self: *Context, loadctx: anytype, r: *std.Io.Reader, tree_size: u32, header_size: u32, dir_index: usize, do_null_skipping: bool, game_id: GameId) !void {
    while (true) {
        loadctx.printCb("Dir mounted {d:.2}%", .{@as(f32, @floatFromInt(r.seek)) / @as(f32, @floatFromInt(r.end + 1)) * 100});
        const ext = try r.takeDelimiter(0) orelse break;
        if (ext.len == 0)
            break;
        sanatizeVpkString(ext);
        self.writeDump("{s}\n", .{ext});
        const ext_stored = try self.string_storage.store(ext);
        const ext_id = try self.extension_map.getPut(ext_stored);
        while (true) {
            const path = try r.takeDelimiter(0) orelse break;
            if (path.len == 0)
                break;
            self.writeDump("    {s}\n", .{path});
            sanatizeVpkString(path);
            const path_stored = try self.string_storage.store(path);
            const path_id = try self.path_map.getPut(path_stored);

            while (true) {
                const fname = try r.takeDelimiter(0) orelse break;
                if (fname.len == 0)
                    break;
                self.writeDump("        {s}\n", .{fname});

                _ = try r.takeInt(u32, .little); //CRC
                const preload_count = try r.takeInt(u16, .little); //preload bytes
                var arch_index = try r.takeInt(u16, .little); //archive index
                var offset = try r.takeInt(u32, .little);
                var entry_len = try r.takeInt(u32, .little);

                const term = try r.takeInt(u16, .little);
                if (term != 0xffff) return error.badBytes;
                if (arch_index == 0x7fff) {
                    //TODO put a dir with arch_index 0x7ff do it .
                    offset += tree_size + header_size;
                }

                if (entry_len == 0) { //Hack to support preload
                    offset = @intCast(r.seek);
                    arch_index = 0x7fff;
                    entry_len = preload_count;
                }

                r.toss(preload_count);

                sanatizeVpkString(fname);
                const fname_stored = try self.string_storage.store(fname);
                const fname_id = try self.res_map.getPut(fname_stored);
                const res_id = encodeResourceId(ext_id, path_id, fname_id);
                const entry = try self.entries.getOrPut(self.alloc, res_id);
                if (!entry.found_existing) {
                    entry.value_ptr.* = Context.Entry{
                        .game = game_id,
                        .res_id = res_id,
                        .path = path_stored,
                        .name = fname_stored,
                        .location = .{ .vpk = .{
                            .dir_index = @intCast(dir_index),
                            .archive_index = arch_index,
                            .offset = offset,
                            .length = entry_len,
                        } },
                    };
                } else {
                    //log.err("Duplicate resource is named: {s}", .{fname});
                    //    //return error.duplicateResource;
                }

                if (do_null_skipping) {}
            }
        }
    }
}

fn splitPath(sl: []const u8) struct { ext: []const u8, path: []const u8, name: []const u8 } {
    const slash = std.mem.lastIndexOfScalar(u8, sl, '/') orelse 0;
    const dot = std.mem.lastIndexOfScalar(u8, sl, '.') orelse sl.len;

    return .{
        .path = sl[0..slash],
        .ext = sl[dot + 1 ..], //Eat the dot
        .name = sl[slash + 1 .. dot],
    };
}

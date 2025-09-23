const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const graph = @import("graph");
const pushEvent = graph.SDL.pushEvent;

pub const JsonRpcRequest = struct {
    jsonrpc: []const u8,
    method: []const u8,
    params: std.json.Value = .{ .null = {} },
    id: []const u8 = "",
};
const MsgT = []const JsonRpcRequest;

pub const JsonRpcError = struct {
    jsonrpc: []const u8,
    id: []const u8 = "Null",
    @"error": struct {
        code: i64,
        message: []const u8,
        data: []const u8,
    },
};

pub const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    result: std.json.Value,
    id: []const u8,
};

pub const RpcError = enum(i64) {
    parse = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_param = -32602,
    internal = -32603,
};

//allocated by rpc_server
pub const Event = struct {
    stream: std.net.Stream, // send a response back
    msg: MsgT,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        //self.msg.deinit();
        self.arena.deinit();
        alloc.destroy(self);
    }
};

pub const RpcServer = struct {
    const Self = @This();

    alloc: std.mem.Allocator,

    mutex: std.Thread.Mutex = .{},
    threads: ArrayList(std.Thread) = .{},

    messages: ArrayList(MsgT) = .{},

    event_id: u32,
    user1: ?*anyopaque,

    response_buf: ArrayList(u8) = .{},

    pub fn create(alloc: std.mem.Allocator, user1: ?*anyopaque) !*Self {
        const ret = try alloc.create(Self);

        ret.* = Self{
            .alloc = alloc,
            .event_id = graph.c.SDL_RegisterEvents(1),
            .user1 = user1,
        };

        {
            ret.mutex.lock();
            defer ret.mutex.unlock();
            try ret.threads.append(ret.alloc, try std.Thread.spawn(.{}, serverThread, .{ret}));
        }

        return ret;
    }

    pub fn serverThread(self: *Self) !void {
        std.fs.cwd().deleteFile("test.socket") catch {};
        const addr = try std.net.Address.initUnix("test.socket");
        defer std.fs.cwd().deleteFile("test.socket") catch {};
        var serv = try addr.listen(.{});
        defer serv.deinit();
        while (true) {
            const con = try serv.accept();

            {
                self.mutex.lock();
                defer self.mutex.unlock();

                try self.threads.append(self.alloc, try std.Thread.spawn(.{}, handleClientThread, .{ self, con.stream }));
            }
        }
    }

    //Thread safe
    fn putMessage(self: *Self, msg: MsgT) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.messages.append(self.alloc, msg);
    }

    // Thread safe, user must free returned
    pub fn getMessage(self: *Self) ?MsgT {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.messages.pop();
    }

    pub fn destroy(self: *Self) void {
        // for (self.threads.items) |th| {
        //     th.join();
        // }
        self.mutex.lock();
        self.threads.deinit(self.alloc);
        self.response_buf.deinit(self.alloc);

        self.alloc.destroy(self);
    }

    pub fn handleClientThread(self: *Self, stream: std.net.Stream) !void {
        defer stream.close();
        const r = stream.reader();
        var msg_buf = ArrayList(u8){};
        defer msg_buf.deinit(self.alloc);
        while (true) {
            msg_buf.clearRetainingCapacity();
            r.streamUntilDelimiter(msg_buf.writer(self.alloc), ':', null) catch break;

            const length = try std.fmt.parseInt(u32, msg_buf.items, 10);
            try msg_buf.resize(self.alloc, length);
            try r.readNoEof(msg_buf.items);

            const expect_comma = try r.readByte();
            if (expect_comma != ',') return error.expectedComma;

            const trimmed = std.mem.trimLeft(u8, msg_buf.items, " \n\t\r");
            if (trimmed.len == 0) return error.invalid;

            var arena = std.heap.ArenaAllocator.init(self.alloc);
            errdefer arena.deinit();

            const parsed = blk: switch (trimmed[0]) {
                '{' => { //Single json object
                    const parsed = std.json.parseFromSliceLeaky(JsonRpcRequest, arena.allocator(), msg_buf.items, .{}) catch |err| {
                        var wr = stream.writer();
                        wr.print("{!}\n", .{err}) catch {};
                        break;
                    };
                    const slice = try arena.allocator().alloc(JsonRpcRequest, 1);
                    slice[0] = parsed;
                    break :blk slice;
                },
                '[' => std.json.parseFromSliceLeaky([]const JsonRpcRequest, arena.allocator(), msg_buf.items, .{}) catch |err| {
                    var wr = stream.writer();
                    wr.print("{!}\n", .{err}) catch {};
                    break;
                },
                else => return error.invalidJson,
            };

            //defer parsed.deinit();

            const ev = try self.alloc.create(Event);
            ev.* = .{
                .arena = arena,
                .msg = parsed,
                //.msg = try self.alloc.dupe(u8, msg_buf.items),
                .stream = stream,
            };
            try graph.SDL.pushEvent(self.event_id, 0, self.user1, @ptrCast(ev));
        }
    }

    //Only call this from the main thread.
    pub fn respond(self: *Self, wr: anytype, resp: JsonRpcResponse) !void {
        self.response_buf.clearRetainingCapacity();
        try std.json.stringify(resp, .{}, self.response_buf.writer(self.alloc));

        try wr.print("{d}:{s},", .{ self.response_buf.items.len, self.response_buf.items });
    }
};

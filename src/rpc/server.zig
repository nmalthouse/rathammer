const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const graph = @import("graph");
const pushEvent = graph.SDL.pushEvent;
const rpc = @import("rpc.zig");

const MsgT = []const rpc.JsonRpcRequest;
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

    response_buf: std.Io.Writer.Allocating,

    pub fn create(alloc: std.mem.Allocator, user1: ?*anyopaque, event_id: u32) !*Self {
        const ret = try alloc.create(Self);

        ret.* = Self{
            .alloc = alloc,
            .event_id = event_id,
            .user1 = user1,
            .response_buf = .init(alloc),
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
        self.response_buf.deinit();

        self.alloc.destroy(self);
    }

    pub fn handleClientThread(self: *Self, stream: std.net.Stream) !void {
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [1024]u8 = undefined;
        defer stream.close();
        var read = stream.reader(&read_buffer);
        const r = read.interface();

        var write = stream.writer(&write_buffer);
        const wr = &write.interface;

        var msg_buf: std.Io.Writer.Allocating = .init(self.alloc);
        defer msg_buf.deinit();

        while (true) {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            errdefer arena.deinit();

            const parsed = rpc.parseSafe(arena.allocator(), r, &msg_buf, rpc.JsonRpcRequest) catch |err| switch (err) {
                error.invalidStream => return,
                error.invalidJson => {
                    try respondBuf(wr, .{
                        .id = 0,
                        .@"error" = .{
                            .code = @intFromEnum(rpc.RpcError.parse),
                            .message = "bad json",
                            .data = "",
                        },
                    }, &msg_buf);
                    continue;
                },
            };

            //defer parsed.deinit();

            const ev = try self.alloc.create(Event);
            ev.* = .{
                .arena = arena,
                .msg = parsed,
                .stream = stream,
            };
            try graph.SDL.pushEvent(self.event_id, 0, self.user1, @ptrCast(ev));
        }
    }

    pub fn respondBuf(wr: *std.Io.Writer, resp: rpc.JsonRpcResponse, msg_buf: *std.Io.Writer.Allocating) !void {
        msg_buf.clearRetainingCapacity();
        try std.json.Stringify.value(resp, .{}, &msg_buf.writer);

        const slice = msg_buf.written();
        try wr.print("{d}:{s},", .{ slice.len, slice });
        try wr.flush();
    }

    /// Only call this from the main thread.
    pub fn respond(self: *Self, wr: *std.Io.Writer, resp: rpc.JsonRpcResponse) !void {
        try respondBuf(wr, resp, &self.response_buf);
    }
};

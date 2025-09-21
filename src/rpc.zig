const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const graph = @import("graph");
const pushEvent = graph.SDL.pushEvent;

const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: std.json.Value,
    id: []const u8,
};
const JsonRpcRequestParsed = std.json.Parsed(JsonRpcRequest);

//allocated by rpc_server
pub const Event = struct {
    stream: std.net.Stream, // send a response back
    msg: []const u8,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.msg);
        alloc.destroy(self);
    }
};

pub const RpcServer = struct {
    const MsgT = []const u8;
    const Self = @This();

    alloc: std.mem.Allocator,

    mutex: std.Thread.Mutex = .{},
    threads: ArrayList(std.Thread) = .{},

    messages: ArrayList(MsgT) = .{},

    event_id: u32,
    user1: ?*anyopaque,

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

        self.alloc.destroy(self);
    }

    pub fn handleClientThread(self: *Self, stream: std.net.Stream) !void {
        defer stream.close();
        var r = stream.reader();
        var msg_buf = ArrayList(u8){};
        defer msg_buf.deinit(self.alloc);
        while (true) {
            msg_buf.clearRetainingCapacity();
            r.streamUntilDelimiter(msg_buf.writer(self.alloc), '\n', null) catch break;

            //try self.putMessage(try self.alloc.dupe(u8, msg_buf.items));
            const ev = try self.alloc.create(Event);
            ev.* = .{ .msg = try self.alloc.dupe(u8, msg_buf.items), .stream = stream };
            try graph.SDL.pushEvent(self.event_id, 0, self.user1, @ptrCast(ev));
        }
    }
};

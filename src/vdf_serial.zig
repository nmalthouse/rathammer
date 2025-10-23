const std = @import("std");

pub const VdfWriter = struct {
    const Self = @This();
    out_stream: *std.Io.Writer,

    indendation: usize = 0,
    state: enum {
        expecting_key,
        expecting_value,
        in_value,
    } = .expecting_key,
    strbuf: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, stream: *std.Io.Writer) Self {
        return .{
            .strbuf = .{},
            .alloc = alloc,
            .out_stream = stream,
        };
    }

    pub fn deinit(self: *Self) void {
        self.strbuf.deinit(self.alloc);
    }

    //may clear self.strbuf
    fn sanitizeName(self: *Self, name: []const u8) ![]const u8 {
        var needs_quotes = false;
        for (name) |char| {
            switch (char) {
                //This is more strict than the canonical vdfs.
                //Having unescaped newlines inside of keys is bad, imo.
                //Escaping is an option which is off by default in the Valve parsers, some vdf's use the '\' as a path
                //seperator, so we can't force it on.
                '{', '}', ' ', '\t' => {
                    needs_quotes = true;
                },
                '\\' => return error.backslashNotAllowed,
                '"' => return error.quotesNotAllowed,
                '\n', '\r' => return error.newlineNotAllowed,
                else => {},
                //TODO should we disallow all control chars?
                //what about unicode?
            }
        }
        if (needs_quotes) {
            self.strbuf.clearRetainingCapacity();
            try self.strbuf.append(self.alloc, '\"');
            try self.strbuf.appendSlice(self.alloc, name);
            try self.strbuf.append(self.alloc, '\"');
            return self.strbuf.items;
        }
        return name;
    }

    fn indent(self: *Self) !void {
        _ = try self.out_stream.splatByte(' ', self.indendation * 4);
    }

    pub fn writeComment(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.state != .expecting_key)
            return error.invalidState;
        try self.indent();
        try self.out_stream.print("//" ++ fmt ++ "\n", args);
    }

    pub fn writeKey(self: *Self, key: []const u8) !void {
        if (self.state != .expecting_key)
            return error.invalidState;
        try self.indent();
        _ = try self.out_stream.write(try self.sanitizeName(key));
        _ = try self.out_stream.write(" ");
        self.state = .expecting_value;
    }

    pub fn printKey(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.state != .expecting_key)
            return error.invalidState;
        try self.indent();
        try self.out_stream.print(fmt, args);
        _ = try self.out_stream.write(" ");
        self.state = .expecting_value;
    }

    pub fn beginObject(self: *Self) !void {
        if (self.state != .expecting_value)
            return error.invalidState;
        _ = try self.out_stream.write("{\n");
        self.indendation += 1;
        self.state = .expecting_key;
    }

    pub fn endObject(self: *Self) !void {
        if (self.state != .expecting_key)
            return error.invalidState;
        self.indendation -= 1;
        try self.indent();
        _ = try self.out_stream.write("}\n");
    }

    pub fn writeValue(self: *Self, value: []const u8) !void {
        if (self.state != .expecting_value)
            return error.invalidState;
        _ = try self.out_stream.write(try self.sanitizeName(value));
        _ = try self.out_stream.writeByte('\n');
        self.state = .expecting_key;
    }

    pub fn writeKv(self: *Self, key: []const u8, value: anytype) !void {
        try self.writeKey(key);
        try self.writeAnyValue(value);
    }

    /// does not verify
    pub fn printValue(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.state != .expecting_value)
            return error.invalidState;
        try self.out_stream.print(fmt ++ "\n", args);
        self.state = .expecting_key;
    }

    pub fn beginValue(self: *Self) !void {
        if (self.state != .expecting_value)
            return error.invalidState;
        try self.out_stream.writeByte('\"');
        self.state = .in_value;
    }

    pub fn printInnerValue(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.state != .in_value)
            return error.invalidState;

        try self.out_stream.print(fmt, args);
    }

    pub fn endValue(self: *Self) !void {
        if (self.state != .in_value)
            return error.invalidState;
        _ = try self.out_stream.write("\"\n");
        self.state = .expecting_key;
    }

    pub fn writeInnerStruct(self: *Self, value: anytype) !void {
        const info = @typeInfo(@TypeOf(value));
        inline for (info.@"struct".fields) |field| {
            try self.writeKv(field.name, @field(value, field.name));
        }
    }

    pub fn writeAnyValue(self: *Self, value: anytype) !void {
        const info = @typeInfo(@TypeOf(value));
        switch (info) {
            .int, .comptime_int, .float => try self.printValue("\"{d}\"", .{value}),
            .pointer => |p| {
                if (p.child == u8) {
                    try self.printValue("\"{s}\"", .{value});
                    return;
                }
                @compileError("not supported on pointers " ++ @typeName(@TypeOf(value)) ++ " " ++ @typeName(p.child));
            },
            .@"struct" => {
                try self.beginObject();
                try self.writeInnerStruct(value);
                try self.endObject();
            },
            else => @compileError("not supported " ++ @typeName(@TypeOf(value))),
        }
    }
};

const std = @import("std");
pub const JsonRpcRequest = struct {
    jsonrpc: []const u8,
    method: []const u8,
    params: std.json.Value = .{ .null = {} },
    id: i64,
};

pub const JsonRpcError = struct {
    jsonrpc: []const u8,
    id: []const u8 = "Null",
};

pub const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    result: std.json.Value = .null,
    id: i64,

    @"error": ?struct {
        code: i64,
        message: []const u8,
        data: []const u8,
    } = null,
};

pub const RpcError = enum(i64) {
    parse = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_param = -32602,
    internal = -32603,
};

pub fn parse(alloc: std.mem.Allocator, r: *std.Io.Reader, msg_buf: *std.Io.Writer.Allocating, comptime T: type) ![]const T {
    const length_str = (r.takeDelimiter(':') catch null) orelse return error.invalidStream;

    const length = try std.fmt.parseInt(u32, length_str, 10);

    msg_buf.clearRetainingCapacity();
    _ = try r.stream(&msg_buf.writer, .limited(length));

    if (try r.takeByte() != ',') return error.invalidStream;

    const trimmed = std.mem.trimLeft(u8, msg_buf.written(), " \n\t\r");
    if (trimmed.len == 0) return error.invalidStream;

    return blk: switch (trimmed[0]) {
        '{' => { //Single json object
            const parsed = try std.json.parseFromSliceLeaky(T, alloc, msg_buf.written(), .{});
            const slice = try alloc.alloc(T, 1);
            slice[0] = parsed;
            break :blk slice;
        },
        '[' => try std.json.parseFromSliceLeaky([]const T, alloc, msg_buf.written(), .{}),
        else => return error.invalidJson,
    };
}

/// Filters errors into:
/// error invalidStream
/// error invalidJson
pub fn parseSafe(alloc: std.mem.Allocator, r: *std.Io.Reader, msg_buf: *std.Io.Writer.Allocating, comptime T: type) ![]const T {
    return parse(alloc, r, msg_buf, T) catch |err| switch (err) {
        error.WriteFailed,
        error.ReadFailed,
        error.EndOfStream,
        error.OutOfMemory,
        error.Overflow,
        error.UnexpectedEndOfInput,
        error.BufferUnderrun,
        error.invalidStream,
        => error.invalidStream,
        else => error.invalidJson,
    };
}

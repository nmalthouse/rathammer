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
    @"error": struct {
        code: i64,
        message: []const u8,
        data: []const u8,
    },
};

pub const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    result: std.json.Value,
    id: i64,
};

pub const RpcError = enum(i64) {
    parse = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_param = -32602,
    internal = -32603,
};

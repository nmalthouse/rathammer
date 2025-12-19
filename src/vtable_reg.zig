const std = @import("std");
const graph = @import("graph");
const SparseSet = graph.SparseSet;

pub fn VtableReg(vt_type: type) type {
    return struct {
        const Self = @This();
        const IdType = u16;

        var TYPE_ID_COUNTER: IdType = 0;

        pub const TableReg = ?IdType;
        pub const initTableReg = null;

        vtables: SparseSet(*vt_type, IdType),
        alloc: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .alloc = alloc,
                .vtables = .init(alloc),
            };
        }

        fn assertTool(comptime T: type) void {
            if (!@hasDecl(T, "tool_id"))
                @compileError("Tools must declare a: pub threadlocal var tool_id: TableReg = initTableReg;");
            if (@TypeOf(T.tool_id) != TableReg)
                @compileError("Invalid type for tool_id, should be ToolReg");
        }

        pub fn register(self: *Self, comptime T: type, vt: *vt_type) !void {
            assertTool(T);
            const id = T.tool_id orelse blk: {
                T.tool_id = TYPE_ID_COUNTER;
                TYPE_ID_COUNTER += 1;
                break :blk T.tool_id.?;
            };

            try self.vtables.insert(id, vt);
        }

        pub fn getId(self: *Self, comptime T: type) !IdType {
            _ = self;
            assertTool(T);
            return T.tool_id orelse error.toolNotRegistered;
        }

        pub fn getVt(self: *Self, comptime T: type) !*vt_type {
            const id = try self.getId(T);
            return try self.vtables.get(id);
        }

        pub fn deinit(self: *Self) void {
            for (self.vtables.dense.items) |item|
                item.deinit_fn(item, self.alloc);
            self.vtables.deinit();
        }
    };
}

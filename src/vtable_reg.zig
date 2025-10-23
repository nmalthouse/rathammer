const std = @import("std");
//TODO make this not create singletons,
//introduce a second array mapping table_ids to local vtable array
//so more than one registry can exist.
pub fn VtableReg(vt_type: type) type {
    return struct {
        const Self = @This();
        pub const TableReg = ?usize;
        pub const initTableReg = null;

        vtables: std.ArrayList(*vt_type),
        alloc: std.mem.Allocator,
        name_map: std.StringHashMap(usize),

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .alloc = alloc,
                .vtables = .{},
                .name_map = std.StringHashMap(usize).init(alloc),
            };
        }

        fn assertTool(comptime T: type) void {
            if (!@hasDecl(T, "tool_id"))
                @compileError("Tools must declare a: pub threadlocal var tool_id: TableReg = initTableReg;");
            if (@TypeOf(T.tool_id) != TableReg)
                @compileError("Invalid type for tool_id, should be ToolReg");
        }

        pub fn register(self: *Self, name: []const u8, comptime T: type) !void {
            assertTool(T);

            const alloc_name = try self.alloc.dupe(u8, name);
            if (T.tool_id != null)
                return error.toolAlreadyRegistered;

            const id = self.vtables.items.len;
            try self.vtables.append(self.alloc, try T.create(self.alloc));
            T.tool_id = id;
            try self.name_map.put(alloc_name, id);
        }

        pub fn registerCustom(self: *Self, name: []const u8, comptime T: type, vt: *vt_type) !void {
            assertTool(T);

            const alloc_name = try self.alloc.dupe(u8, name);
            if (T.tool_id != null)
                return error.toolAlreadyRegistered;

            const id = self.vtables.items.len;
            try self.vtables.append(self.alloc, vt);
            T.tool_id = id;
            try self.name_map.put(alloc_name, id);
        }

        pub fn getId(self: *Self, comptime T: type) !usize {
            _ = self;
            assertTool(T);
            return T.tool_id orelse error.toolNotRegistered;
        }

        pub fn getVt(self: *Self, comptime T: type) !*vt_type {
            const id = try self.getId(T);
            return self.vtables.items[id];
        }

        pub fn deinit(self: *Self) void {
            var it = self.name_map.keyIterator();
            while (it.next()) |item| {
                self.alloc.free(item.*);
            }
            self.name_map.deinit();
            for (self.vtables.items) |item|
                item.deinit_fn(item, self.alloc);
            self.vtables.deinit(self.alloc);
        }
    };
}

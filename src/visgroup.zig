const std = @import("std");
const vmf = @import("vmf.zig");
const graph = @import("graph");
const json_map = @import("json_map.zig");

const Self = @This();

pub const VisGroupId = u8;
pub const MAX_VIS_GROUP = 128;
pub const BitSetT = std.bit_set.StaticBitSet(MAX_VIS_GROUP);

pub const Group = struct {
    name: []const u8,
    color: u32,
    id: VisGroupId,

    children: std.ArrayList(VisGroupId),
};
const log = std.log.scoped(.visgroup);

vmf_id_mapping: std.AutoHashMap(i32, VisGroupId),
// VisGroupId indexes into this
groups: std.ArrayList(Group),
alloc: std.mem.Allocator,

disabled: BitSetT,

pub fn init(alloc: std.mem.Allocator) Self {
    return .{
        .vmf_id_mapping = std.AutoHashMap(i32, VisGroupId).init(alloc),
        .groups = std.ArrayList(Group).init(alloc),
        .alloc = alloc,
        .disabled = BitSetT.initEmpty(),
    };
}

pub fn getRoot(self: *Self) ?*Group {
    if (self.groups.items.len > 0)
        return &self.groups.items[0];

    return null;
}

fn getRootNoFail(self: *Self) !*Group {
    return self.getRoot() orelse {
        _ = try self.newGroup("");
        return &self.groups.items[0];
    };
}

pub fn getMask(self: *Self, groups: []const VisGroupId) BitSetT {
    _ = self;
    var ret = BitSetT.initEmpty();
    for (groups) |group| {
        ret.set(group);
    }
    return ret;
}

pub fn getMaskFromEditorInfo(self: *Self, info: *const vmf.EditorInfo) !BitSetT {
    var ret = BitSetT.initEmpty();
    for (info.visgroupid) |id| {
        if (self.vmf_id_mapping.get(id)) |g_id| {
            ret.set(g_id);
        } else {
            log.warn("invalid vis group", .{});
            return ret;
        }
    }
    return ret;
}

pub fn setValueCascade(self: *Self, group_id: VisGroupId, shown: bool) void {
    self.recurSetValue(group_id, shown);
}

fn recurSetValue(self: *Self, id: VisGroupId, shown: bool) void {
    self.setValue(id, shown);
    if (id >= self.groups.items.len) return;
    for (self.groups.items[id].children.items) |group| {
        self.recurSetValue(group, shown);
    }
}

pub fn setValue(self: *Self, group_id: VisGroupId, shown: bool) void {
    if (group_id >= self.groups.items.len) return;
    self.disabled.setValue(group_id, !shown);
}

pub fn writeToJson(self: *Self, wr: anytype) !void {
    if (self.getRoot()) |root| {
        try self.writeGroupToJson(root.id, wr);
    } else {
        try wr.write(null);
    }
}

fn writeGroupToJson(self: *Self, group_id: u8, wr: anytype) !void {
    if (group_id >= self.groups.items.len) return error.invalidVisgroup;
    const group = self.groups.items[group_id];
    try wr.beginObject();
    try wr.objectField("name");
    try wr.write(group.name);
    try wr.objectField("color");
    try wr.write(group.color);
    try wr.objectField("id");
    try wr.write(group.id);
    try wr.objectField("children");
    try wr.beginArray();
    for (group.children.items) |child|
        try self.writeGroupToJson(child, wr);
    try wr.endArray();
    try wr.endObject();
}

//Be careful, this may invalidate previous pointers
fn newGroup(self: *Self, name: []const u8) !*Group {
    try self.groups.append(Group{
        .name = try self.alloc.dupe(u8, name),
        .color = 0xff,
        .id = @intCast(self.groups.items.len),
        .children = std.ArrayList(VisGroupId).init(self.alloc),
    });
    return &self.groups.items[self.groups.items.len - 1];
}

pub fn getOrPutTopLevelGroup(self: *Self, name: []const u8) !VisGroupId {
    {
        const root = try self.getRootNoFail();
        for (root.children.items) |child_id| {
            const child = self.groups.items[child_id];
            if (std.mem.eql(u8, child.name, name))
                return child.id;
        }
    }

    const new = try self.newGroup(name);
    const id = new.id;

    //PTR madness
    const root = self.getRoot() orelse return error.noRoot;
    try root.children.append(id);
    return id;
}

pub fn getGroup(self: *Self, id: VisGroupId) ?Group {
    if (id >= self.groups.items.len) return null;
    return self.groups.items[id];
}

pub fn putDefaultVisGroups(self: *Self) !void {
    var auto_node: ?VisGroupId = null;
    if (self.getRoot()) |root| {
        for (root.children.items) |direct| {
            if (self.getGroup(direct)) |gr| {
                if (std.mem.eql(u8, gr.name, "Auto")) {
                    auto_node = gr.id;
                    break;
                }
            }
        }
    } else {
        _ = try self.newGroup(""); //Add a root node
    }
    if (auto_node == null) {
        const aa = try self.newGroup("Auto");
        auto_node = aa.id;
        const root = self.getRoot() orelse return;
        try root.children.append(aa.id);
    }
    //Auto
    //  entity
    //      World Solids
    //      Point Ent
    //      Brush Ent
    //      Trigger
    //  detail
    //      props
    //      func_detail

}

//This does no validation of the passed in data, so if you modify json it will crash horribly
pub fn insertVisgroupsFromJson(self: *Self, json_vis: ?json_map.VisGroup) !void {
    const jv = json_vis orelse return;
    if (jv.id != 0) return; //Root must be 0
    if (self.groups.items.len != 0) return;
    var tmp_mapping = std.AutoHashMap(VisGroupId, void).init(self.alloc);
    defer tmp_mapping.deinit();
    try self.insertRecur(&tmp_mapping, jv);
    if (self.groups.items.len != tmp_mapping.count()) return error.visgroupsFucked;

    for (0..self.groups.items.len) |item| {
        if (!tmp_mapping.contains(@intCast(item))) return error.visgroupsFucked;
    }
}

fn insertRecur(self: *Self, map: *std.AutoHashMap(VisGroupId, void), node: json_map.VisGroup) !void {
    if (map.contains(node.id)) return error.duplicateVisgroup;
    var children = std.ArrayList(VisGroupId).init(self.alloc);
    for (node.children) |ch|
        try children.append(ch.id);
    try map.put(node.id, {});
    try self.groups.insert(node.id, .{
        .name = try self.alloc.dupe(u8, node.name),
        .color = node.color,
        .id = node.id,
        .children = children,
    });
    for (node.children) |ch| {
        try self.insertRecur(map, ch);
    }
}

pub fn buildMappingFromVmf(self: *Self, vmf_visgroups: []const vmf.VisGroup, parent_i: ?u8) !void {
    for (vmf_visgroups) |gr| {
        if (!self.vmf_id_mapping.contains(gr.visgroupid)) {
            const index_o = self.groups.items.len;
            if (index_o > MAX_VIS_GROUP)
                return error.tooManyVisgroups;
            const index: VisGroupId = @intCast(index_o);
            try self.vmf_id_mapping.put(gr.visgroupid, index);
            try self.groups.append(.{
                .name = try self.alloc.dupe(u8, gr.name),
                .color = graph.ptypes.intColorFromVec3(gr.color.v, 1),
                .id = @intCast(index),
                .children = std.ArrayList(VisGroupId).init(self.alloc),
            });
            //std.debug.print("PUtting visgroup {s}\n", .{gr.name});
            if (parent_i) |p| {
                try self.groups.items[p].children.append(index);
            }
            try self.buildMappingFromVmf(gr.visgroup, index);
        } else {
            std.debug.print("Duplicate vis group {s} with id {d}, omitting\n", .{ gr.name, gr.visgroupid });
        }
    }
}

pub fn deinit(self: *Self) void {
    self.vmf_id_mapping.deinit();
    for (self.groups.items) |*group| {
        self.alloc.free(group.name);
        group.children.deinit();
    }
    self.groups.deinit();
}

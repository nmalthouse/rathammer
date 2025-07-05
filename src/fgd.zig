const std = @import("std");
const util = @import("util.zig");
// Comments //
//
// //@BaseEnt ?classprop() ?classprop2() = classname ?: "my description" [ *contents* ]
// propertyname(type) : doc_name ?: default : doc_string
//
// spawnFlags =
// []
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const stringToEnum = std.meta.stringToEnum;
const log = std.log.scoped(.fgd);

//TODO this parser sucks
// Should work with hl2, portal2, portal, cstrike, tf2.
// Others are untested
pub const Tag = enum {
    comma,
    colon,
    l_bracket,
    r_bracket,
    plus,
    l_paren,
    r_paren,
    equals,
    newline,
    quoted_string,
    plain_string,
    at_string,
    //comment,
};

pub const Token = struct {
    pub const Pos = struct {
        start: usize,
        end: usize,
    };
    tag: Tag,
    pos: Pos,

    fn debugPrint(self: @This(), slice: []const u8) void {
        std.debug.print("Token: {s} \"{s}\"\n", .{ @tagName(self.tag), slice[self.pos.start..self.pos.end] });
    }

    pub fn orderedTokenIterator(delim: Tag, slice: []const Token) struct {
        delim: Tag,
        slice: []const Token,
        pos: usize,

        //if delim is , and our token stream is a,,a,a
        //our next calls should return:  a null a a
        pub fn next(self: *@This()) ?Token {
            if (self.pos >= self.slice.len)
                return null;
            defer self.pos += 1;
            if (self.slice[self.pos].tag != self.delim)
                return self.slice[self.pos];

            //Peek the next, if not delim return that
            if (self.pos + 1 < self.slice.len and self.slice[self.pos + 1].tag != self.delim) {
                self.pos += 1;
                return self.slice[self.pos];
            }

            return null;
        }
    } {
        return .{
            .delim = delim,
            .slice = slice,
            .pos = 0,
        };
    }
};

pub const FgdTokenizer = struct {
    //Zig is so cool.
    slice: []const u8,
    pos: usize = 0,
    last_tok: ?Tag = null,
    peeked: ?Token = null,

    line_counter: usize = 1,
    char_counter: usize = 1,

    alloc: Allocator,

    params: std.ArrayList(Token),

    pub fn init(slice: []const u8, alloc: Allocator) @This() {
        return .{
            .slice = slice,
            .alloc = alloc,
            .params = std.ArrayList(Token).init(alloc),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.params.deinit();
    }

    fn controlChar(char: u8) ?Tag {
        return switch (char) {
            ',' => .comma,
            '[' => .l_bracket,
            ']' => .r_bracket,
            '+' => .plus,
            '=' => .equals,
            '(' => .l_paren,
            ')' => .r_paren,
            ':' => .colon,
            else => null,
        };
    }

    pub fn expectNext(self: *@This(), tag: Tag) !Token {
        const n = try self.next() orelse return error.eos;
        if (n.tag != tag) {
            n.debugPrint(self.slice);
            return error.unexpectedTag;
        }

        return n;
    }

    pub fn getSlice(self: *@This(), token: Token) []const u8 {
        return self.slice[token.pos.start..token.pos.end];
    }

    pub fn nextEatNewline(self: *@This()) !?Token {
        while (try self.next()) |t| {
            if (t.tag != .newline)
                return t;
        }
        return null;
    }

    pub fn eatNewline(self: *@This()) !void {
        while (true) {
            const n = try self.peek() orelse return;
            if (n.tag != .newline)
                return;
            _ = try self.next();
        }
    }

    pub fn expectNextEatNewline(self: *@This(), comptime tag: Tag) !Token {
        if (tag == .newline) @compileError("impossible");
        while (try self.next()) |t| {
            if (t.tag != .newline) {
                if (t.tag != tag) {
                    t.debugPrint(self.slice);
                    return error.wrongTag;
                }
                return t;
            }
        }
        return error.missing;
    }

    // <ent_desc> ::= <at_string> <inherit> | <equals> <ent_name> <ent_doc> | <newline> <ent_def>
    // <ent_name> ::= <plain_string>
    // <ent_doc> ::= <colon> <multi-line-str>
    // <ent_def> ::= <l_br>

    //A multi-line string has the grammar:
    // <multi-line-str> ::= <quoted_string> <newline> | <multi-line-str-cont>
    // <multi-line-str-cont> ::= <plus> <newline> <multi-line-str>
    pub fn expectMultilineString(self: *@This(), ret: *std.ArrayList(u8)) !void { //TODO return string, requires alloc
        while (true) {
            const n1 = try self.next() orelse return error.multilineStringSyntax;
            if (n1.tag != .quoted_string) {
                return error.multilineStringSyntax;
            }
            try ret.appendSlice(self.getSlice(n1));
            const ne = try self.peek() orelse return;
            switch (ne.tag) {
                .plus => {
                    _ = try self.next(); //Clear peek

                    _ = try self.expectNext(.newline);
                    const n = try self.peek() orelse return;
                    switch (n.tag) {
                        .quoted_string => {
                            try ret.append('\n');
                            continue;
                        },
                        else => return, //A workaround to ill defined syntax
                        //Some multi-line strings (2 in base.fgd) terminate with a '+' with no string on the following line
                        //Should be a syntax error
                    }
                },
                else => break,
            }
        }
    }

    pub fn peek(self: *@This()) !?Token {
        if (self.peeked) |p| return p;
        self.peeked = try self.next();
        return self.peeked;
    }

    pub fn nextA(self: *@This()) !Token {
        return try self.next() orelse error.expectedToken;
    }

    pub fn next(self: *@This()) !?Token {
        if (self.peeked) |p| {
            defer self.peeked = null;
            return p;
        }
        var state: enum {
            start,
            quoted_string,
            comment,
            at_string,
            plain_string,
        } = .start;
        var res = Token{ .pos = .{ .start = self.pos, .end = self.pos }, .tag = .newline };
        if (self.pos >= self.slice.len)
            return null;
        while (self.pos < self.slice.len) : (self.pos += 1) {
            const ch = self.slice[self.pos];
            self.char_counter += 1;
            if (ch == '\n') {
                self.line_counter += 1;
                self.char_counter = 1;
            }
            switch (state) {
                .start => {
                    switch (ch) {
                        '\r', '\n' => {
                            if (self.last_tok != null and self.last_tok.? == .newline) { //A cheap way to handle \r\n returning multiple newline tokens
                                state = .start;
                                if (self.pos + 1 >= self.slice.len)
                                    return null;
                                res.pos.start = self.pos + 1;
                                continue;
                            }
                            res.tag = .newline;
                            self.pos += 1;
                            res.pos.end = self.pos;
                            break;
                        },
                        ' ', '\t' => res.pos.start = self.pos + 1,
                        '\"' => {
                            state = .quoted_string;
                            res.pos.start = self.pos + 1;
                        },
                        '@' => state = .at_string,
                        else => {
                            if (controlChar(ch)) |cc| {
                                res.tag = cc;
                                self.pos += 1;
                                res.pos.end = self.pos;
                                break;
                            }
                            state = .plain_string;
                            if (ch == '/' and self.pos + 1 < self.slice.len and self.slice[self.pos + 1] == '/')
                                state = .comment;
                        },
                    }
                },
                .at_string => {
                    if (controlChar(ch) != null) {
                        res.tag = .at_string;
                        res.pos.end = self.pos;
                        break;
                    }
                    switch (ch) {
                        '\r', '\n', ' ' => {
                            res.tag = .at_string;
                            res.pos.end = self.pos;
                            break;
                        },
                        else => {},
                    }
                },
                .plain_string => {
                    if (controlChar(ch) != null) {
                        res.tag = .plain_string;
                        res.pos.end = self.pos;
                        break;
                    }
                    switch (ch) {
                        '\r', '\n', ' ', '\t' => {
                            res.tag = .plain_string;
                            res.pos.end = self.pos;
                            break;
                        },
                        else => {},
                    }
                },
                .quoted_string => {
                    switch (ch) {
                        '"' => {
                            res.tag = .quoted_string;
                            res.pos.end = self.pos;
                            self.pos += 1; //Increment pos after to eat the closing "
                            break;
                        },
                        '\r', '\n' => return error.noNewlineInString,
                        else => {},
                    }
                },
                .comment => {
                    switch (ch) {
                        '\r', '\n' => {
                            if (self.pos + 1 >= self.slice.len)
                                return null;
                            res.pos.start = self.pos + 1;
                            self.last_tok = null;
                            state = .start;
                            continue;
                        },
                        else => {},
                    }
                },
            }
        }
        self.last_tok = res.tag;
        return res;
    }
};

const AtDirective = enum {
    // these two are different.
    mapsize, // parameters passed through paren arg list
    include, // parameter is a single string with no separators

    //The following all have the same grammar
    BaseClass,
    PointClass,
    NPCClass,
    SolidClass,
    FilterClass,
    KeyFrameClass,
    MoveClass,

    //AutoVisGroup, //Similar to Classes but different.
    //MaterialExclusion,
};

test {
    const alloc_ = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc_);
    defer arena.deinit();
    const alloc = arena.allocator();
    const game_dirs = [_]struct { []const u8, []const u8 }{
        .{ "portal2.fgd", "Portal 2/bin" },
        .{ "cstrike.fgd", "Counter-Strike Source/bin" },
        .{ "halflife2.fgd", "Half-Life 2/bin" },
        .{ "tf.fgd", "Team Fortress 2/bin" },
    };

    var scratch = std.ArrayList(u8).init(alloc);
    //const bas = "/home/rat/.local/share/Steam/steamapps/common/Counter-Strike Source/bin";
    const bas = "/home/rat/.local/share/Steam/steamapps/common/";
    for (game_dirs) |gd| {
        std.debug.print("Opening {s}\n", .{gd[0]});
        scratch.clearRetainingCapacity();
        try scratch.writer().print("{s}{s}", .{ bas, gd[1] });
        const base_dir = try std.fs.cwd().openDir(scratch.items, .{});

        const in = try base_dir.openFile(gd[0], .{});
        //const in = try base_dir.openFile("portal.fgd", .{});
        defer in.close();

        const slice = try in.reader().readAllAlloc(alloc, std.math.maxInt(usize));
        defer alloc.free(slice);

        var ctx = EntCtx.init(alloc);
        defer ctx.deinit();

        var parse = ParseCtx.init(alloc, slice);
        defer parse.deinit();
        parse.crass(&ctx, base_dir) catch |err| {
            std.debug.print("Line: {d}:{d}\n", .{ parse.tkz.line_counter, parse.tkz.char_counter });
            return err;
        };
    }
}

pub const EntCtx = struct {
    const Self = @This();

    string_alloc: std.heap.ArenaAllocator,
    alloc: Allocator,
    ents: std.ArrayList(EntClass),

    base: std.StringHashMap(usize), // classname -> ents.items[index]

    all_input_map: std.StringHashMap(usize),
    all_inputs: std.ArrayList(EntClass.Io),

    pub fn init(alloc: Allocator) Self {
        return .{
            .string_alloc = std.heap.ArenaAllocator.init(alloc),
            .alloc = alloc,
            .ents = std.ArrayList(EntClass).init(alloc),
            .base = std.StringHashMap(usize).init(alloc),
            .all_input_map = std.StringHashMap(usize).init(alloc),
            .all_inputs = std.ArrayList(EntClass.Io).init(alloc),
        };
    }

    pub fn dupeString(self: *Self, str: []const u8) ![]const u8 {
        return try self.string_alloc.allocator().dupe(u8, str);
    }

    pub fn addIo(self: *Self, io: EntClass.Io) !void {
        switch (io.kind) {
            .output => {},
            .input => {
                if (self.all_input_map.contains(io.name)) return;
                const index = self.all_inputs.items.len;
                try self.all_input_map.put(io.name, index);
                try self.all_inputs.append(io);
            },
        }
    }

    pub fn deinit(self: *Self) void {
        for (self.ents.items) |*item| {
            item.deinit();
        }
        self.base.deinit();
        self.ents.deinit();
        self.all_input_map.deinit();
        self.all_inputs.deinit();
        self.string_alloc.deinit();
    }

    pub fn getId(self: *Self, class_name: []const u8) ?usize {
        return self.base.get(class_name);
    }

    pub fn getPtr(self: *Self, class_name: []const u8) ?*EntClass {
        const index = self.base.get(class_name) orelse return null;
        if (index >= self.ents.items.len)
            return null;
        return &self.ents.items[index];
    }

    pub fn nameFromId(self: *Self, id: usize) ?[]const u8 {
        if (id < self.ents.items.len)
            return self.ents.items[id].name;
        return null;
    }
};

pub const EntClass = struct {
    const Self = @This();
    pub const Field = struct {
        pub const Type = union(enum) {
            pub const KV = struct { []const u8, []const u8 };
            pub const Flag = struct {
                on: bool,
                mask: u32,
                name: []const u8,
            };
            choices: std.ArrayList(KV),
            flags: std.ArrayList(Flag),
            color255: void,
            material: void,
            model: void,
            angle: void,
            generic: void,
        };
        name: []const u8,
        type: Type,
        default: []const u8,
        doc_string: []const u8,
        is_derived: bool = false,

        pub fn deinit(self: *@This()) void {
            if (self.is_derived)
                return;
            switch (self.type) {
                .choices => |cc| cc.deinit(),
                .flags => |cc| cc.deinit(),
                else => {},
            }
        }
    };
    pub const Io = struct {
        pub const Kind = enum { input, output };
        pub const Type = enum { void, string, integer, float, bool, ehandle, color255, target_destination, vector };
        //All strings alloced by entctx
        kind: Kind,
        name: []const u8,
        type: Type,
        doc: []const u8,
    };
    io_data: std.ArrayList(Io),
    io: std.StringHashMap(usize),
    ///Indexes into io_data
    inputs: std.ArrayList(usize),
    outputs: std.ArrayList(usize),

    field_data: std.ArrayList(Field),
    fields: std.StringHashMap(usize),
    //fields: std.ArrayList(Field),
    name: []const u8 = "",
    doc: []const u8 = "",
    iconsprite: []const u8 = "",
    studio_model: []const u8 = "",

    pub fn init(alloc: Allocator) Self {
        return .{
            .inputs = std.ArrayList(usize).init(alloc),
            .outputs = std.ArrayList(usize).init(alloc),
            .io_data = std.ArrayList(Io).init(alloc),
            .io = std.StringHashMap(usize).init(alloc),
            .field_data = std.ArrayList(Field).init(alloc),
            .fields = std.StringHashMap(usize).init(alloc),
        };
    }

    //Assumes all fields are already alloced
    pub fn addField(self: *Self, field: Field) !void {
        if (self.fields.contains(field.name)) {
            var f = field;
            f.deinit();
            return;
        }

        const index = self.field_data.items.len;
        try self.fields.put(field.name, index);
        try self.field_data.append(field);
    }

    /// Assumes all fields are alloced
    pub fn addIo(self: *Self, io: Io) !void {
        if (self.io.contains(io.name)) return;

        const index = self.io_data.items.len;
        try self.io.put(io.name, index);
        try self.io_data.append(io);
        switch (io.kind) {
            .input => try self.inputs.append(index),
            .output => try self.outputs.append(index),
        }
    }

    pub fn inherit(self: *Self, parent: Self) !void {
        //BUG, some fields are inherited twice, switch to a hash map
        //This is because of multinheritance, the diamond problem
        var it = parent.fields.iterator();
        while (it.next()) |item| {
            if (self.fields.contains(item.key_ptr.*)) continue; //duplicate field

            var cc = parent.field_data.items[item.value_ptr.*];
            cc.is_derived = true;
            const index = self.field_data.items.len;
            try self.fields.put(item.key_ptr.*, index);
            try self.field_data.append(cc);
        }

        var io_it = parent.io.iterator();
        while (io_it.next()) |item| {
            if (self.io.contains(item.key_ptr.*)) continue;
            const io = parent.io_data.items[item.value_ptr.*];
            try self.addIo(io);
        }
    }

    pub fn deinit(self: *Self) void {
        for (self.field_data.items) |*item|
            item.deinit();
        self.field_data.deinit();
        self.fields.deinit();
        self.io.deinit();
        self.io_data.deinit();
        self.inputs.deinit();
        self.outputs.deinit();
    }
};

pub fn loadFgd(ctx: *EntCtx, base_dir: std.fs.Dir, path: []const u8) !void {
    const in = util.openFileFatal(base_dir, path, .{}, "Where is the fgd?");
    defer in.close();
    const alloc = ctx.alloc;

    const slice = try in.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(slice);
    var parse = ParseCtx.init(alloc, slice);
    defer parse.deinit();

    parse.crass(ctx, base_dir) catch |err| {
        std.debug.print("Line: {d}:{d}\n", .{ parse.tkz.line_counter, parse.tkz.char_counter });
        return err;
    };
}

var mask_default_buf: [100]u8 = undefined;
pub const ParseCtx = struct {
    const Self = @This();
    tkz: FgdTokenizer,
    alloc: std.mem.Allocator,
    slice: []const u8, //Not freed

    scratch_buf: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator, slice: []const u8) @This() {
        return .{
            .scratch_buf = std.ArrayList(u8).init(alloc),
            .slice = slice,
            .alloc = alloc,
            .tkz = FgdTokenizer.init(slice, alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.scratch_buf.deinit();
        self.tkz.deinit();
    }

    pub fn sanitizeIdent(self: *Self, string: []const u8) []const u8 {
        self.scratch_buf.clearRetainingCapacity();
        self.scratch_buf.resize(string.len) catch std.process.exit(1);
        return std.ascii.lowerString(self.scratch_buf.items, string);
    }

    pub fn crass(pctx: *Self, ctx: *EntCtx, base_dir: std.fs.Dir) !void {
        const alloc = pctx.alloc;
        const tkz = &pctx.tkz;
        var ignored_count: usize = 0;
        var print_buf = std.ArrayList(u8).init(alloc);
        defer print_buf.deinit();
        while (try tkz.next()) |tk| {
            const tok = tkz.getSlice(tk);
            switch (tk.tag) {
                .at_string => {
                    //+1 to strip the '@'
                    const ct = stringToEnum(AtDirective, tok[1..]) orelse {
                        log.warn("Unsupported fgd directive: {s}", .{tok});
                        continue;
                    };
                    try pctx.parseDirective(ctx, base_dir, ct);
                },
                .newline => {},
                else => {
                    ignored_count += 1;
                    //return error.br;
                },
            }
        }
    }

    pub fn parseDirective(pctx: *Self, ctx: *EntCtx, base_dir: std.fs.Dir, directive: AtDirective) anyerror!void {
        const tkz = &pctx.tkz;
        const alloc = pctx.alloc;
        switch (directive) {
            .include => {
                //If you do cyclic includes, the stack will overflow.
                //TODO prevent cycles
                const include_file = try tkz.expectNext(.quoted_string);
                //Don't use openFileFatal as parse will log the error and line number
                const in_f = try base_dir.openFile(tkz.getSlice(include_file), .{});
                defer in_f.close();
                const slice2 = try in_f.reader().readAllAlloc(alloc, std.math.maxInt(usize));
                defer alloc.free(slice2);
                var parse = ParseCtx.init(alloc, slice2);
                defer parse.deinit();

                parse.crass(ctx, base_dir) catch |err| {
                    log.err("Include : {s}, error line: {d}:{d}", .{ pctx.tkz.getSlice(include_file), parse.tkz.line_counter, parse.tkz.char_counter });
                    return err;
                };
            },
            .mapsize => {
                _ = try tkz.expectNext(.l_paren);
                const width = try tkz.expectNext(.plain_string);
                _ = try tkz.expectNext(.comma);
                const height = try tkz.expectNext(.plain_string);
                _ = try tkz.expectNext(.r_paren);
                _ = width;
                _ = height;
            },
            .PointClass, .BaseClass, .NPCClass, .SolidClass, .FilterClass, .KeyFrameClass, .MoveClass => {
                var new_class = EntClass.init(alloc);
                while (try tkz.next()) |t| { //Parse all the inherited classes
                    switch (t.tag) {
                        .plain_string => {
                            const parent_name = tkz.getSlice(t);
                            //Dumb, yes. But this is the *only* one like it
                            //All other parent classes take 0 or more arguments in parentheses, "halfgridsnap" has no arguments AND no ().
                            if (eql(u8, parent_name, "halfgridsnap")) {
                                continue;
                            }
                            _ = try tkz.expectNext(.l_paren);
                            tkz.params.clearRetainingCapacity();
                            while (true) {
                                const next = try tkz.next() orelse return error.syntax;
                                switch (next.tag) {
                                    else => {
                                        try tkz.params.append(next);
                                    }, // add to param list
                                    .r_paren => break,
                                }
                            }
                            if (stringToEnum(enum {
                                base,
                                iconsprite,
                                studio,
                            }, parent_name)) |en| {
                                const ps = tkz.params.items;
                                switch (en) {
                                    .studio => {
                                        if (ps.len != 1 or ps[0].tag != .quoted_string) {
                                            //std.debug.print("Invalid studio mdl: {s}\n", .{});
                                        } else {
                                            new_class.studio_model = try ctx.dupeString(tkz.getSlice(ps[0]));
                                        }
                                    },
                                    .iconsprite => {
                                        if (ps.len != 1 or ps[0].tag != .quoted_string) {
                                            log.warn("Invalid icon sprite", .{});
                                        } else {
                                            new_class.iconsprite = try ctx.dupeString(tkz.getSlice(ps[0]));
                                        }
                                    },
                                    .base => {
                                        var it = Token.orderedTokenIterator(.comma, ps);
                                        while (it.next()) |tt| {
                                            const base = ctx.getPtr(tkz.getSlice(tt)) orelse {
                                                log.warn("INVALID CLASS {s}", .{tkz.getSlice(tt)});
                                                continue;
                                            };
                                            try new_class.inherit(base.*);
                                        }
                                    },
                                }
                            }
                        },
                        else => return error.invalidClassDef,
                        .equals => break,
                    }
                }

                const class_name = try tkz.expectNext(.plain_string);
                new_class.name = try ctx.dupeString(tkz.getSlice(class_name));
                //std.debug.print("Decl {s}\n", .{tkz.getSlice(class_name)});

                //@directive base1(arg) base2(arg) = class_name

                try tkz.eatNewline();
                const n = try tkz.peek() orelse return error.syntax;
                switch (n.tag) {
                    .colon => { //Parse docstring
                        _ = try tkz.next(); //peeked
                        try tkz.eatNewline();
                        pctx.scratch_buf.clearRetainingCapacity();
                        try tkz.expectMultilineString(&pctx.scratch_buf);
                        new_class.doc = try ctx.dupeString(pctx.scratch_buf.items);
                        //std.debug.print("NEW ONE {s}\n", .{multi_string_buf.items});
                    },
                    .newline => {},
                    .l_bracket => {},
                    else => return error.syntax,
                }
                //BUG, sometimes the colon is on next line
                _ = try tkz.expectNextEatNewline(.l_bracket);

                try pctx.parseFields(ctx, &new_class);

                switch (directive) {
                    else => {
                        const index = ctx.ents.items.len;
                        try ctx.ents.append(new_class);
                        try ctx.base.put(new_class.name, index);
                    },
                }
            },
        }
    }
    pub fn parseFields(self: *Self, ctx: *EntCtx, new_class: anytype) !void {
        const tkz = &self.tkz;
        const buf = &self.scratch_buf;
        while (try tkz.nextEatNewline()) |first| {
            if (first.tag == .r_bracket) break; //this class in done
            if (first.tag != .plain_string) return error.syntax;
            const fsl = tkz.getSlice(first);
            if (stringToEnum(EntClass.Io.Kind, fsl)) |fw| { //Input, output field
                const io_name = try tkz.expectNext(.plain_string);
                _ = try tkz.expectNext(.l_paren);
                const io_type = try tkz.expectNext(.plain_string);
                _ = try tkz.expectNext(.r_paren);
                const n1 = try tkz.peek() orelse return error.syntax;
                var io_doc: []const u8 = "";
                if (n1.tag == .colon) {
                    _ = try tkz.next(); //eat peek
                    buf.clearRetainingCapacity();
                    try tkz.expectMultilineString(buf);
                    io_doc = buf.items;
                }
                const new_io = EntClass.Io{
                    .name = try ctx.dupeString(tkz.getSlice(io_name)),
                    .doc = try ctx.dupeString(io_doc),
                    .type = try getIoType(tkz.getSlice(io_type), buf),
                    .kind = fw,
                };
                try new_class.addIo(new_io);
                try ctx.addIo(new_io);
            } else { // A regular field
                _ = try tkz.expectNext(.l_paren);
                const type_tok = try tkz.expectNext(.plain_string); //Type must be a plain string
                _ = try tkz.expectNext(.r_paren);
                try self.parseModifier();

                const dat = try self.parseKVCommon(ctx);
                const tt = try self.parseKvType(ctx, type_tok, &mask_default_buf);
                const new_type = tt[0];
                const mask_default = tt[1];
                try new_class.addField(.{
                    .name = try ctx.dupeString(self.sanitizeIdent(fsl)),
                    .type = new_type,
                    .default = try ctx.dupeString(mask_default orelse dat.def),
                    .doc_string = dat.doc,
                });
            }
        }
    }

    pub fn parseModifier(self: *Self) !void {
        const tkz = &self.tkz;
        while (true) { // Read modifiers
            const n1 = try tkz.peek() orelse return error.syntax;
            switch (n1.tag) {
                .plain_string => {
                    const Mods = enum { readonly, report };
                    const pl = tkz.getSlice(n1);
                    _ = stringToEnum(Mods, pl) orelse {
                        log.err("MODIFIER '{s}'\n", .{pl});
                        return error.invalidModifier;
                    };
                    _ = try tkz.next();
                },
                else => break,
            }
        }
    }

    /// Parse the what all kv fields have
    /// : "Kv name" : "default" : "doc string"
    pub fn parseKVCommon(self: *Self, ctx: *EntCtx) !struct { def: []const u8, doc: []const u8 } {
        var index: i32 = -1;
        var default_str: []const u8 = "";
        const tkz = &self.tkz;
        const buf = &self.scratch_buf;
        var new_type_doc: []const u8 = "";
        while (true) {
            const n1 = try tkz.peek() orelse return error.syntax;
            switch (n1.tag) {
                else => break,
                .colon => {
                    _ = try tkz.next();
                    index += 1;
                },
                .newline => {
                    // workaround for a couple lines portal2
                    // newline does not indicate end of type its expecting a doc string
                    if (index == 2) {
                        _ = try tkz.next();
                    } else {
                        break;
                    }
                },
                .plain_string, .quoted_string => {
                    switch (index) {
                        0 => { //prop name
                            _ = try tkz.next();
                        },
                        1 => { //default value
                            const t = (try tkz.next()) orelse return error.syntax;
                            default_str = tkz.getSlice(t);
                            //Not duped yet because it may be
                            //provided by flags instead
                        },
                        2 => { //doc string
                            buf.clearRetainingCapacity();
                            try tkz.expectMultilineString(buf);
                            new_type_doc = try ctx.dupeString(buf.items);
                            break;
                        },
                        else => return error.syntax,
                    }
                },
            }
        }
        return .{
            .def = default_str,
            .doc = new_type_doc,
        };
    }

    /// Some kvs define extra type data like choices flags etc, this parses that
    pub fn parseKvType(self: *Self, ctx: *EntCtx, type_tok: Token, default_buf: []u8) !struct { EntClass.Field.Type, ?[]const u8 } {
        const buf = &self.scratch_buf;
        const tkz = &self.tkz;
        var default_str: ?[]const u8 = null;
        const TypeStr = enum { choices, flags, string, float, integer, boolean, color255, angle, decal, material, studio };
        var new_type = EntClass.Field.Type{ .generic = {} };
        if (stringToEnum(TypeStr, self.sanitizeIdent(tkz.getSlice(type_tok)))) |st| {
            switch (st) {
                .choices => {
                    var new_choices = std.ArrayList(EntClass.Field.Type.KV).init(ctx.alloc);
                    _ = try tkz.expectNext(.equals);
                    _ = try tkz.expectNextEatNewline(.l_bracket);
                    while (true) {
                        const n1 = try tkz.nextEatNewline() orelse return error.choiceMis;
                        switch (n1.tag) {
                            .plain_string, .quoted_string => {
                                _ = try tkz.expectNext(.colon);
                                const val = try tkz.expectNext(.quoted_string);
                                try new_choices.append(.{
                                    try ctx.dupeString(tkz.getSlice(n1)),
                                    try ctx.dupeString(tkz.getSlice(val)),
                                });
                            },
                            .r_bracket => break,
                            else => return error.choiceSyntax,
                        }
                    }
                    new_type = .{ .choices = new_choices };
                },
                .flags => {
                    _ = try tkz.expectNext(.equals);
                    _ = try tkz.expectNextEatNewline(.l_bracket);
                    var new_flags = std.ArrayList(EntClass.Field.Type.Flag).init(ctx.alloc);
                    while (true) {
                        const n1 = try tkz.nextEatNewline() orelse return error.choiceMis;
                        switch (n1.tag) {
                            .plain_string => {
                                const mask = try std.fmt.parseInt(u32, tkz.getSlice(n1), 10);
                                _ = try tkz.expectNext(.colon);
                                const mask_name = try tkz.expectNext(.quoted_string);
                                _ = try tkz.expectNext(.colon);
                                //TODO make this optional
                                const def = try tkz.expectNext(.plain_string);
                                const defint = try std.fmt.parseInt(u32, tkz.getSlice(def), 10);
                                try new_flags.append(.{
                                    .on = defint > 0,
                                    .name = try ctx.dupeString(tkz.getSlice(mask_name)),
                                    .mask = mask,
                                });
                            },
                            .r_bracket => break,
                            else => return error.flagSyntax,
                        }
                    }
                    var def_mask: u32 = 0;
                    for (new_flags.items) |f| {
                        if (f.on) {
                            def_mask |= f.mask;
                        }
                    }
                    buf.clearRetainingCapacity();
                    try buf.writer().print("{d}", .{def_mask});
                    default_str = buf.items;
                    new_type = .{ .flags = new_flags };
                },
                .color255 => new_type = .{ .color255 = {} },
                .material, .decal => new_type = .{ .material = {} },
                .angle => new_type = .{ .angle = {} },
                .studio => new_type = .{ .model = {} },
                else => {},
            }
        } else {
            //std.debug.print("TYPE {s}\n", .{tkz.getSlice(type_tok)});
            //_ = try tkz.expectNext(.newline);
        }
        const defalt = blk: {
            if (default_str) |dstr| {
                const len = @min(dstr.len, default_buf.len);
                @memcpy(default_buf[0..len], dstr);
                break :blk default_buf[0..len];
            } else {
                break :blk null;
            }
        };
        return .{ new_type, defalt };
    }
};

fn getIoType(string: []const u8, buf: *std.ArrayList(u8)) !EntClass.Io.Type {
    try buf.resize(string.len);
    _ = std.ascii.lowerString(buf.items, string);
    return stringToEnum(EntClass.Io.Type, buf.items) orelse {
        log.warn("unrecognized io type: {s}", .{string});
        return .void;
    };
}

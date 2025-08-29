const std = @import("std");

pub const Tag = enum {
    newline,
    open_bracket,
    close_bracket,
    string,
    quoted_string,
};

pub const Token = struct {
    pub const Pos = struct { start: usize, end: usize };
    tag: Tag,
    pos: Pos,
};

pub const Tokenizer = struct {
    slice: []const u8,
    pos: usize = 0,

    line_counter: usize = 0,
    char_counter: usize = 0,

    queued: ?Token = null,

    opts: struct {
        allow_newline_in_string: bool = true,
    } = .{},

    pub fn next(self: *@This()) !?Token {
        errdefer std.debug.print("POS {d}\n", .{self.pos});
        if (self.queued) |q| {
            defer self.queued = null;
            return q;
        }

        var state: enum { start, quoted, string } = .start;
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
                .start => switch (ch) {
                    '\"' => {
                        state = .quoted;
                        res.pos.start += 1;
                    },
                    '{', '}' => {
                        res.tag = if (ch == '{') .open_bracket else .close_bracket;
                        self.pos += 1;
                        break;
                    },
                    '\n' => {
                        res.tag = .newline;
                        break;
                    },
                    else => state = .string,
                },
                .string => switch (ch) {
                    '\"', '{', '}' => return error.invalidString,
                    '\n' => {
                        res.tag = .string;
                        res.pos.end = self.pos - 1;
                        break;
                    },
                    ' ' => {
                        res.tag = .string;
                        res.pos.end = self.pos - 1;
                        self.pos += 1;
                        break;
                    },
                    else => {},
                },
                .quoted => switch (ch) {
                    '\"' => {
                        res.tag = .string;
                        res.pos.end = self.pos - 1;
                        break;
                    },
                    '\n' => {
                        if (!self.opts.allow_newline_in_string)
                            return error.newlineInString;
                    },
                    else => {},
                },
            }
        }
        switch (state) {
            .start => return null,
            .quoted => return error.missingQuote,
            .string => {
                res.tag = .string;
                res.pos.end = self.pos;
                return res;
            },
        }
    }
};

const TestExpected = struct {
    slice: []const u8,
    tok: []const Tag,
};

test "basic" {
    const ex = std.testing.expectEqual;

    const tt = [_]TestExpected{
        .{
            .slice = "hello world",
            .tok = &.{ .string, .string },
        },
        .{
            .slice = "hello world {\"string\" inside}",
            .tok = &.{ .string, .string, .open_bracket, .string, .string, .close_bracket },
        },
    };
    //while (try tok.next()) |ttt|
    //std.debug.print("{any}\n", .{ttt});
    for (tt) |test1| {
        var tok = Tokenizer{ .slice = test1.slice };
        for (test1.tok) |t| {
            try ex(t, (try tok.next()).?.tag);
        }
    }
}

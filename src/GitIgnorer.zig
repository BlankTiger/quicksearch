/// holds paths to directories and if they are git directories,
/// then they hold IgnoreRules, otherwise it's null, which means
/// that directory is not a git directory or it didnt contain
/// any rules
cache: Cache,
parser: Parser,
allocator: std.mem.Allocator,

const GitIgnorer = @This();
const Cache = std.StringHashMap(struct { rules: Rules, in_git_repo_root: bool });

const Rules = struct {
    list: std.ArrayList(Rule),

    const Rule = struct {
        parts: []const RegexPart,
        is_negated: bool,
        is_for_dirs: bool,

        pub fn deinit(self: Rule, allocator: std.mem.Allocator) void {
            for (self.parts) |part| part.deinit(allocator);
            allocator.free(self.parts);
        }
    };

    const RegexPart = union(enum) {
        literal: []const u8,
        char_range: CharRange,
        asterisk: void,
        double_asterisk: void,
        question_mark: void,

        inline fn deinit(self: RegexPart, allocator: std.mem.Allocator) void {
            switch (self) {
                .literal => |txt| allocator.free(txt),
                .char_range => |range| range.deinit(allocator),
                .asterisk, .double_asterisk, .question_mark => {},
            }
        }
    };

    const CharRange = struct {
        ranges: []const Range,
        is_negated: bool,

        pub fn deinit(self: CharRange, allocator: std.mem.Allocator) void {
            allocator.free(self.ranges);
        }
    };

    const Range = union(enum) {
        single: u8,
        range: struct { start: u8, end: u8 },
    };

    pub fn init(allocator: std.mem.Allocator) Rules {
        return .{
            .list = .init(allocator),
        };
    }

    pub fn deinit(self: Rules) void {
        for (self.items()) |rule| rule.deinit(self.list.allocator);
        self.list.deinit();
    }

    pub inline fn items(self: Rules) []const Rule {
        return self.list.items;
    }

    pub inline fn len(self: Rules) usize {
        return self.list.items.len;
    }

    pub inline fn append(self: *Rules, rule: Rule) !void {
        try self.list.append(rule);
    }

    pub inline fn append_slice(self: *Rules, rules: []const Rule) !void {
        try self.list.appendSlice(rules);
    }

    }
};

const Parser = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Self) void {
        _ = self;
    }

    const Rule = Rules.Rule;
    const RegexPart = Rules.RegexPart;

    /// doesnt take ownership of `file`
    pub fn parse_from(self: Self, file: std.fs.File) !Rules {
        const content = try file.readToEndAlloc(self.allocator, comptime std.math.maxInt(usize));
        defer self.allocator.free(content);
        return self.parse(content);
    }

    pub fn parse(self: Self, content: []const u8) !Rules {
        var rules: Rules = .init(self.allocator);
        errdefer rules.deinit();
        if (std.mem.eql(u8, content, "")) return rules;

        var line_iter = std.mem.splitBackwardsScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            if (try parse_rule(self.allocator, line)) |rule| {
                try rules.append(rule);
            }
        }

        return rules;
    }

    fn parse_rule(allocator: std.mem.Allocator, line: []const u8) !?Rule {
        if (std.mem.eql(u8, line, "")) return null;
        if (std.mem.startsWith(u8, line, "#")) return null;
        std.debug.assert(line.len > 0);

        var parts: std.ArrayList(RegexPart) = .init(allocator);
        errdefer parts.deinit();

        var idx: usize = 0;
        var idx_start_literal: ?usize = null;
        var is_negated: bool = false;
        if (line[idx] == '!') {
            is_negated = true;
            idx = 1;
        } else if (line.len > 1 and line[0] == '\\' and line[1] == '!') {
            idx = 1;
        } else if (line.len > 1 and line[0] == '\\' and line[1] == '#') {
            idx = 1;
        }

        while (idx < line.len) {
            const ch = line[idx];
            switch (ch) {
                '*' => {
                    if (idx_start_literal) |idx_start| {
                        try parts.append(.{ .literal = try allocator.dupe(u8, line[idx_start..idx]) });
                        idx_start_literal = null;
                    }
                    if (line.len > idx + 1 and line[idx + 1] == '*') {
                        idx += 2;
                        try parts.append(.double_asterisk);
                    } else {
                        idx += 1;
                        try parts.append(.asterisk);
                    }
                },

                '?' => {
                    if (idx_start_literal) |idx_start| {
                        try parts.append(.{ .literal = try allocator.dupe(u8, line[idx_start..idx]) });
                        idx_start_literal = null;
                    }
                    idx += 1;
                    try parts.append(.question_mark);
                },

                '[' => {
                    if (idx_start_literal) |idx_start| {
                        try parts.append(.{ .literal = try allocator.dupe(u8, line[idx_start..idx]) });
                        idx_start_literal = null;
                    }

                    idx += 1;

                    const range_negated = line[idx] == '!' or line[idx] == '^';
                    if (range_negated) idx += 1;

                    var ranges: std.ArrayList(Rules.Range) = .init(allocator);
                    errdefer ranges.deinit();
                    {
                        var characters: std.ArrayList(u8) = .init(allocator);
                        defer characters.deinit();
                        while (true) {
                            const new_ch = line[idx];
                            switch (new_ch) {
                                ']' => {
                                    idx += 1;
                                    for (characters.items) |_ch| {
                                        try ranges.append(.{ .single = _ch });
                                    }
                                    break;
                                },

                                '-' => {
                                    idx += 1;

                                    defer characters.clearRetainingCapacity();
                                    const chars_len = characters.items.len;
                                    for (0..characters.items.len - 1) |ch_idx| {
                                        try ranges.append(.{ .single = characters.items[ch_idx] });
                                    }

                                    try ranges.append(.{ .range = .{
                                        .start = characters.items[chars_len - 1],
                                        .end = line[idx],
                                    } });

                                    idx += 1;
                                },

                                else => {
                                    idx += 1;

                                    if (new_ch == '\\' and line[idx] == '-') {
                                        try characters.append(line[idx]);
                                        idx += 1;
                                    } else {
                                        try characters.append(new_ch);
                                    }
                                },
                            }
                        }
                    }

                    try parts.append(.{ .char_range = .{
                        .ranges = try ranges.toOwnedSlice(),
                        .is_negated = range_negated,
                    } });
                },

                else => {
                    if (idx_start_literal == null) {
                        idx_start_literal = idx;
                    }
                    idx += 1;
                },
            }
        }

        if (idx_start_literal) |idx_start| {
            try parts.append(.{ .literal = try allocator.dupe(u8, line[idx_start..]) });
            idx_start_literal = null;
        }

        return .{
            .parts = try parts.toOwnedSlice(),
            .is_negated = is_negated,
            .is_for_dirs = line[line.len - 1] == '/',
        };
    }
};

pub fn init(allocator: std.mem.Allocator) GitIgnorer {
    return .{
        .cache = .init(allocator),
        .parser = .init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *GitIgnorer) void {
    var iter = self.cache.iterator();
    while (iter.next()) |e| {
        self.allocator.free(e.key_ptr.*);
        // e.value_ptr.*.rules.deinit();
    }
    self.cache.deinit();
    self.parser.deinit();
}
test {
    _ = ParserTests;
    _ = MatchingTests;
}

const ParserTests = struct {
    test "parser can produce rules from provided text" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse("");
        defer rules.deinit();

        try t.expectEqual(0, rules.len());
    }

    test "parser can produce a simple file rule" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse("file.txt");
        defer rules.deinit();

        try t.expectEqual(1, rules.len());
        try t.expectEqual(1, rules.items()[0].parts.len);
        try t.expectEqualStrings("file.txt", rules.items()[0].parts[0].literal);
    }

    test "parser can produce many simple file rules" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse(
            \\file_a.txt
            \\file_b.txt
        );
        defer rules.deinit();

        try t.expectEqual(2, rules.len());
        try t.expectEqual(1, rules.items()[0].parts.len);
        try t.expectEqual(1, rules.items()[1].parts.len);
        try t.expectEqualStrings("file_b.txt", rules.items()[0].parts[0].literal);
        try t.expectEqualStrings("file_a.txt", rules.items()[1].parts[0].literal);
    }

    test "parser ignores empty lines" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse(
            \\file_a.txt
            \\
            \\file_b.txt
        );
        defer rules.deinit();

        try t.expectEqual(2, rules.len());
        try t.expectEqual(1, rules.items()[0].parts.len);
        try t.expectEqual(1, rules.items()[1].parts.len);
        try t.expectEqualStrings("file_b.txt", rules.items()[0].parts[0].literal);
        try t.expectEqualStrings("file_a.txt", rules.items()[1].parts[0].literal);
    }

    test "parser ignores commented lines" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse(
            \\file_a.txt
            \\# file_b.txt
            \\#file_b.txt
            \\\#file_b.txt
        );
        defer rules.deinit();

        try t.expectEqual(2, rules.len());
        try t.expectEqual(1, rules.items()[0].parts.len);
        try t.expectEqual(1, rules.items()[1].parts.len);
        try t.expectEqualStrings("#file_b.txt", rules.items()[0].parts[0].literal);
        try t.expectEqualStrings("file_a.txt", rules.items()[1].parts[0].literal);
    }

    const RegexPart = Rules.RegexPart;
    const CharRange = Rules.CharRange;
    const Range = Rules.Range;

    test "parser can parse * patterns" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse(
            \\*file_a.txt
            \\file_*.txt
            \\file_a.*
            \\file_*.*
            \\*file_*.*
        );
        defer rules.deinit();

        try t.expectEqual(5, rules.len());

        try t.expectEqualDeep(&[_]RegexPart{
            .asterisk,
            .{ .literal = "file_a.txt" },
        }, rules.items()[4].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "file_" },
            .asterisk,
            .{ .literal = ".txt" },
        }, rules.items()[3].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "file_a." },
            .asterisk,
        }, rules.items()[2].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "file_" },
            .asterisk,
            .{ .literal = "." },
            .asterisk,
        }, rules.items()[1].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .asterisk,
            .{ .literal = "file_" },
            .asterisk,
            .{ .literal = "." },
            .asterisk,
        }, rules.items()[0].parts);
    }

    test "parse negation" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse(
            \\!file_a.txt
            \\\!file_b.txt
            \\\!file_!.txt
        );
        defer rules.deinit();

        try t.expectEqual(3, rules.len());

        try t.expect(rules.items()[2].is_negated);
        try t.expectEqualDeep(&[_]RegexPart{.{ .literal = "file_a.txt" }}, rules.items()[2].parts);

        try t.expect(!rules.items()[1].is_negated);
        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "!file_b.txt" },
        }, rules.items()[1].parts);

        try t.expect(!rules.items()[0].is_negated);
        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "!file_!.txt" },
        }, rules.items()[0].parts);
    }

    test "rules store if they are matching directories or not" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse(
            \\file_a.txt
            \\dir/
        );
        defer rules.deinit();

        try t.expectEqual(2, rules.len());

        try t.expect(!rules.items()[1].is_for_dirs);
        try t.expect(rules.items()[0].is_for_dirs);
        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "dir/" },
        }, rules.items()[0].parts);
    }

    test "parsing ?" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse(
            \\file_?.txt
        );
        defer rules.deinit();

        try t.expectEqual(1, rules.len());

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "file_" },
            .question_mark,
            .{ .literal = ".txt" },
        }, rules.items()[0].parts);
    }

    test "parsing **" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse(
            \\src/**/*.zig
            \\**/foo
            \\abc/**
        );
        defer rules.deinit();

        try t.expectEqual(3, rules.len());

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "src/" },
            .double_asterisk,
            .{ .literal = "/" },
            .asterisk,
            .{ .literal = ".zig" },
        }, rules.items()[2].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .double_asterisk,
            .{ .literal = "/foo" },
        }, rules.items()[1].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "abc/" },
            .double_asterisk,
        }, rules.items()[0].parts);
    }

    test "parsing char ranges" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse(
            \\file_[a-b].txt
            \\[a-zA-Z0-9].txt
            \\[a\-z].txt
            \\[xyz].txt
            \\[!xyz].txt
            \\[^xyz].txt
            \\[xyzA-Z].txt
        );
        defer rules.deinit();

        try t.expectEqual(7, rules.len());

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "file_" },
            .{ .char_range = .{
                .ranges = &[_]Range{
                    .{ .range = .{ .start = 'a', .end = 'b' } },
                },
                .is_negated = false,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[6].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .char_range = .{
                .ranges = &[_]Range{
                    .{ .range = .{ .start = 'a', .end = 'z' } },
                    .{ .range = .{ .start = 'A', .end = 'Z' } },
                    .{ .range = .{ .start = '0', .end = '9' } },
                },
                .is_negated = false,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[5].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .char_range = .{
                .ranges = &[_]Range{
                    .{ .single = 'a' },
                    .{ .single = '-' },
                    .{ .single = 'z' },
                },
                .is_negated = false,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[4].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .char_range = .{
                .ranges = &[_]Range{
                    .{ .single = 'x' },
                    .{ .single = 'y' },
                    .{ .single = 'z' },
                },
                .is_negated = false,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[3].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .char_range = .{
                .ranges = &[_]Range{
                    .{ .single = 'x' },
                    .{ .single = 'y' },
                    .{ .single = 'z' },
                },
                .is_negated = true,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[2].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .char_range = .{
                .ranges = &[_]Range{
                    .{ .single = 'x' },
                    .{ .single = 'y' },
                    .{ .single = 'z' },
                },
                .is_negated = true,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[1].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .char_range = .{
                .ranges = &[_]Range{
                    .{ .single = 'x' },
                    .{ .single = 'y' },
                    .{ .single = 'z' },
                    .{ .range = .{ .start = 'A', .end = 'Z' } },
                },
                .is_negated = false,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[0].parts);
    }

    const t = std.testing;
};

const MatchingTests = struct {
    test "simple file match" {
        var g: GitIgnorer = .init(t.allocator);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\file.txt
        );
        defer rules.deinit();

        try t.expect(!g.is_excluded_with_rules("./src/search/search.zig", rules));
        try t.expect(g.is_excluded_with_rules("file.txt", rules));
    }

    const t = std.testing;
};

const std = @import("std");
const PathParentGenerator = @import("PathParentGenerator.zig");

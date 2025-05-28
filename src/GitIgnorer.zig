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
        has_slashes: bool,
        root_relative: bool,

        pub fn deinit(self: Rule, allocator: std.mem.Allocator) void {
            for (self.parts) |part| part.deinit(allocator);
            allocator.free(self.parts);
        }

        pub fn matches(self: Rule, path: []const u8) bool {
            var idx: usize = 0;
            // Handle root_relative patterns
            if (self.root_relative) {
                // Root relative patterns must match from the beginning of the path
                // Don't skip to filename - match the full path from root
                idx = 0;
            } else {
                // For non-root-relative patterns, use the existing logic
                if (!self.has_slashes and !self.is_for_dirs) {
                    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx_slash| {
                        idx = idx_slash + 1;
                    }
                }
            }

            var skip: usize = 0;
            for (self.parts, 0..) |p, idx_p| {
                if (skip > 0) {
                    skip -= 1;
                    continue;
                }

                const part_path = path[idx..];

                if (part_path.len == 0) return false;

                switch (p) {
                    .literal => |txt| {
                        if (part_path.len < txt.len) return false;
                        if (self.is_for_dirs) {
                            const maybe_idx_literal = std.mem.indexOf(u8, part_path, txt);
                            if (maybe_idx_literal) |idx_literal| {
                                idx += idx_literal + txt.len;
                                continue;
                            } else {
                                return false;
                            }
                        } else {
                            if (!std.mem.eql(u8, part_path[0..txt.len], txt)) return false;
                            idx += txt.len;
                        }
                    },

                    .char_range => |ch_range| {
                        const ranges = ch_range.ranges;
                        const char = part_path[0];
                        var none_matched = true;

                        for (ranges) |r| {
                            switch (r) {
                                .single => |ch| if (char == ch) {
                                    none_matched = false;
                                    break;
                                },

                                .range => |ran| if (char >= ran.start and char <= ran.end) {
                                    none_matched = false;
                                    break;
                                },
                            }
                        }

                        if (none_matched and !ch_range.is_negated) return false;

                        idx += 1;
                    },

                    .question_mark => {
                        if (part_path[0] == '/') return false;

                        idx += 1;
                    },

                    .slash => {
                        if (part_path[0] != '/') return false;

                        idx += 1;
                    },

                    .asterisk => {
                        if (idx_p + 1 < self.parts.len) {
                            const next = self.parts[idx_p + 1];
                            skip += 1;
                            switch (next) {
                                .literal => |txt| {
                                    const maybe_idx_literal = std.mem.indexOf(u8, part_path, txt);
                                    if (maybe_idx_literal) |idx_literal| {
                                        if (std.mem.indexOfScalar(u8, part_path[0..idx_literal], '/') != null) {
                                            return false;
                                        }
                                        idx += idx_literal + txt.len;
                                        continue;
                                    } else {
                                        return false;
                                    }
                                },

                                .char_range => |ch_range| {
                                    const ranges = ch_range.ranges;
                                    var found_at_offset: usize = MAX_USIZE;

                                    for (ranges) |r| {
                                        for (part_path, 0..) |path_ch, idx_path_ch| {
                                            switch (r) {
                                                .single => |ch| if (path_ch == ch) {
                                                    found_at_offset = idx_path_ch;
                                                    break;
                                                },

                                                .range => |ran| if (path_ch >= ran.start and path_ch <= ran.end) {
                                                    found_at_offset = idx_path_ch;
                                                    break;
                                                },
                                            }
                                        }
                                    }

                                    if (found_at_offset == MAX_USIZE and !ch_range.is_negated) return false;

                                    idx += found_at_offset;
                                },

                                // NOTE: this will go until the next slash or the end of the path
                                .question_mark => {
                                    if (idx_p + 2 < self.parts.len) {
                                        skip += 1;
                                        const next_next = self.parts[idx_p + 2];
                                        std.debug.assert(next_next == .slash);

                                        const maybe_idx_slash = std.mem.indexOfScalar(u8, part_path, '/');
                                        if (maybe_idx_slash) |idx_slash| {
                                            idx += idx_slash + 1;
                                            continue;
                                        } else {
                                            return false;
                                        }
                                    } else {
                                        // go to the end of the path
                                        std.debug.assert(std.mem.indexOfScalar(u8, part_path, '/') == null);
                                        return true;
                                    }
                                },

                                .slash => {
                                    const maybe_idx_slash = std.mem.indexOfScalar(u8, part_path, '/');
                                    if (maybe_idx_slash) |idx_slash| {
                                        idx += idx_slash + 1;
                                        continue;
                                    } else {
                                        return false;
                                    }
                                },

                                .asterisk => @panic("it shouldnt be possible to have two consecutive .asterisk tokens, they should be a .double_asterisk"),

                                .double_asterisk => @panic("it shouldnt be possible to have a .double_asterisk after a single .asterisk"),
                            }
                        } else {
                            // if we are here then this is the end and we match
                            std.debug.assert(self.parts.len - 1 == idx_p);
                        }
                    },

                    // NOTE: .slash must always be after a .double_asterisk, or it means its the end of the pattern
                    .double_asterisk => {
                        if (idx_p + 2 < self.parts.len) {
                            const next = self.parts[idx_p + 1];
                            const next_next = self.parts[idx_p + 2];
                            std.debug.assert(next == .slash);
                            switch (next_next) {
                                .literal => |txt| {
                                    const alloc = std.heap.page_allocator;
                                    const search_term = try std.fmt.allocPrint(alloc, "/{s}", .{txt});
                                    defer alloc.free(search_term);

                                    const maybe_idx_slash = std.mem.indexOf(u8, part_path, search_term);
                                    if (maybe_idx_term) |idx_term| {
                                        idx += idx_term + 1;
                                        continue;
                                    } else {
                                        return false;
                                    }
                                },

                                .asterisk => {

                                },

                                // TODO: this is recursive and has to be extracted
                                .double_asterisk => {

                                },

                                .slash => return false,
                            }
                        } else if (idx_p + 1 < self.parts.len) {
                            const next = self.parts[idx_p + 1];
                            std.debug.assert(next == .slash);
                            const maybe_idx_slash = std.mem.indexOfScalar(u8, part_path, '/');
                            if (maybe_idx_slash) |idx_slash| {
                                idx += idx_slash + 1;
                                continue;
                            } else {
                                return false;
                            }
                        } else {
                            const idx_last_asterisk = std.mem.lastIndexOfScalar(u8, part_path, '*').?;
                            std.debug.assert(idx_last_asterisk == part_path.len - 1);
                            idx += idx_last_asterisk;
                            continue;
                        }
                    },
                }
            }

            return true;
        }
    };

    const RegexPart = union(enum) {
        literal: []const u8,
        char_range: CharRange,
        asterisk: void,
        double_asterisk: void,
        question_mark: void,
        slash: void,

        inline fn deinit(self: RegexPart, allocator: std.mem.Allocator) void {
            switch (self) {
                .literal => |txt| allocator.free(txt),
                .char_range => |range| range.deinit(allocator),
                .asterisk, .double_asterisk, .question_mark, .slash => {},
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

    pub inline fn append_rules(self: *Rules, other: Rules) !void {
        try self.append_slice(other.items());
        other.list.deinit();
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

                '/' => {
                    if (idx_start_literal) |idx_start| {
                        try parts.append(.{ .literal = try allocator.dupe(u8, line[idx_start..idx]) });
                        idx_start_literal = null;
                    }
                    idx += 1;
                    try parts.append(.slash);
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

        const root_relative = r: {
            if (parts.items.len > 0 and parts.items[0] == .slash) {
                _ = parts.orderedRemove(0);
                break :r true;
            } else {
                break :r false;
            }
        };

        return .{
            .parts = try parts.toOwnedSlice(),
            .is_negated = is_negated,
            .is_for_dirs = line[line.len - 1] == '/',
            .has_slashes = s: {
                for (parts.items) |p| {
                    if (p == .slash) break :s true;
                }
                break :s false;
            },
            .root_relative = root_relative,
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
// test "getting rules" {
//     const t = std.testing;
//     var g: GitIgnorer = .init(t.allocator);
//     defer g.deinit();
//
//     const rules = try g.get_rules("./src/search/search.zig");
//     defer rules.deinit();
//
//     for (rules.items()) |rule| {
//         std.debug.print("rules: {}\n", .{rule});
//         for (rule.parts) |part| {
//             std.debug.print("\tpart: {}\n", .{part});
//         }
//     }
//     std.debug.print("rule count: {d}\n", .{rules.len()});
//
//     const list: []const []const u8 = &.{ "./src/GitIgnorer.zig", "./src/search/search.zig" };
//     for (list) |path| {
//         const excluded = try g.is_excluded(path);
//         std.debug.print("\t\t{s} excluded -> {s}\n", .{ path, excluded });
//     }
// }

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
            .{ .literal = "dir" },
            .slash,
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
            .{ .literal = "src" },
            .slash,
            .double_asterisk,
            .slash,
            .asterisk,
            .{ .literal = ".zig" },
        }, rules.items()[2].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .double_asterisk,
            .slash,
            .{ .literal = "foo" },
        }, rules.items()[1].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "abc" },
            .slash,
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

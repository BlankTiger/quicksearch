//! Caller is supposed to pass in an arena allocator. No explicit
//! deallocation is done in an instance of a `GitIgnorer`. Deallocation
//! can be done by calling .deinit() either on `GitIgnorer` or on the
//! passed arena.

arena: *std.heap.ArenaAllocator,
allocator: std.mem.Allocator,

/// holds paths to directories and if they are git directories,
/// then they hold IgnoreRules, otherwise it's null, which means
/// that directory is not a git directory or it didnt contain
/// any rules
cache: Cache,
parser: Parser,

const GitIgnorer = @This();
const Cache = std.StringHashMap(struct { rules: Rules, in_git_repo_root: bool });
const MAX_USIZE = std.math.maxInt(usize);

const MatchResult = enum {
    excluded,
    included,
    none,
};

const Rules = struct {
    list: std.ArrayList(Rule),

    const Rule = struct {
        from_gitignore_in: []const u8,
        pattern: []const u8,
        parts: []const RegexPart,
        is_negated: bool,
        is_for_dirs: bool,
        has_slashes: bool,
        root_relative: bool,

        ///
        /// `path` MUST:
        /// - BE TERMINATED BY A `/` IF IT'S A DIRECTORY
        /// - must also start with './'
        ///
        pub fn match(self: Rule, path: []const u8) MatchResult {
            std.debug.assert(path.len >= 2 and path[0] == '.' and path[1] == '/');

            var relative_to_gitignore = path;
            const maybe_prefix_offset = std.mem.indexOf(u8, path, self.from_gitignore_in);
            if (maybe_prefix_offset) |prefix_offset| {
                if (!(self.parts.len >= 2 and self.parts[0] == .literal and self.parts[0].literal.len == 1 and self.parts[0].literal[0] == '.' and self.parts[1] == .slash)) {
                    relative_to_gitignore = path[prefix_offset + self.from_gitignore_in.len ..];
                }
            }

            var idx: usize = 0;
            if (self.root_relative) {
                // Root relative patterns must match from the beginning of the path
                // Don't skip to filename - match the full path from root
                idx = 0;
            } else {
                if (!self.has_slashes and !self.is_for_dirs and relative_to_gitignore[relative_to_gitignore.len - 1] != '/') {
                    if (std.mem.lastIndexOfScalar(u8, relative_to_gitignore, '/')) |idx_slash| {
                        idx = idx_slash + 1;
                    }
                }
            }

            const matches_patterns = self.match_from(relative_to_gitignore, idx, 0);
            if (matches_patterns) {
                if (self.is_negated) return .included;
                return .excluded;
            } else {
                return .none;
            }
        }

        fn match_from(self: Rule, path: []const u8, from_idx_path: usize, from_idx_part: usize) bool {
            if (path.len == 0 and from_idx_part >= self.parts.len - 1 and self.parts[self.parts.len - 1] == .double_asterisk) return false;
            if (path.len == 0 or path[from_idx_path..].len == 0) return from_idx_part >= self.parts.len - 1;
            if (from_idx_part >= self.parts.len) {
                if (self.is_for_dirs) {
                    return true;
                }
                return path.len == 0 or (path[from_idx_path..].len == 1 and path[from_idx_path] == '/');
            }

            std.debug.assert(from_idx_part < self.parts.len);
            std.debug.assert(from_idx_path < path.len);

            const subpath = path[from_idx_path..];
            const part = self.parts[from_idx_part];
            switch (part) {
                .literal => |txt| {
                    if (subpath.len < txt.len) return false;
                    if (self.is_for_dirs) {
                        const maybe_idx_literal = std.mem.indexOf(u8, subpath, txt);
                        if (maybe_idx_literal) |idx_literal| {
                            const offset = idx_literal + txt.len;
                            return self.match_from(subpath[offset..], 0, from_idx_part + 1);
                        } else {
                            return false;
                        }
                    } else {
                        if (!std.mem.eql(u8, subpath[0..txt.len], txt)) return false;
                        return self.match_from(subpath[txt.len..], 0, from_idx_part + 1);
                    }
                },

                .char_range => |ch_range| {
                    const ranges = ch_range.ranges;
                    const char = subpath[0];
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

                    return self.match_from(subpath[1..], 0, from_idx_part + 1);
                },

                .question_mark => {
                    if (subpath[0] == '/') return false;

                    return self.match_from(subpath[1..], 0, from_idx_part + 1);
                },

                .slash => {
                    if (subpath[0] != '/') return false;

                    return self.match_from(subpath[1..], 0, from_idx_part + 1);
                },

                .asterisk => {
                    if (from_idx_part + 1 < self.parts.len) {
                        const next = self.parts[from_idx_part + 1];
                        switch (next) {
                            .literal => |txt| {
                                const maybe_idx_literal = std.mem.indexOf(u8, subpath, txt);
                                if (maybe_idx_literal) |idx_literal| {
                                    if (std.mem.indexOfScalar(u8, subpath[0..idx_literal], '/') != null) {
                                        return false;
                                    }
                                    return self.match_from(subpath[idx_literal + txt.len ..], 0, from_idx_part + 2);
                                } else {
                                    return false;
                                }
                            },

                            .char_range => |ch_range| {
                                const ranges = ch_range.ranges;
                                var found_at_offset: usize = MAX_USIZE;

                                for (ranges) |r| {
                                    for (subpath, 0..) |path_ch, idx_path_ch| {
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

                                return self.match_from(subpath[found_at_offset..], 0, from_idx_part + 2);
                            },

                            // NOTE: this will go until the next slash or the end of the path
                            .question_mark => {
                                if (from_idx_part + 2 < self.parts.len) {
                                    const next_next = self.parts[from_idx_part + 2];
                                    std.debug.assert(next_next == .slash);

                                    const maybe_idx_slash = std.mem.indexOfScalar(u8, subpath, '/');
                                    if (maybe_idx_slash) |idx_slash| {
                                        return self.match_from(subpath[idx_slash + 1 ..], 0, from_idx_part + 3);
                                    } else {
                                        return false;
                                    }
                                } else {
                                    // go to the end of the path
                                    std.debug.assert(std.mem.indexOfScalar(u8, subpath, '/') == null);
                                    return true;
                                }
                            },

                            .slash => {
                                const maybe_idx_slash = std.mem.indexOfScalar(u8, subpath, '/');
                                if (maybe_idx_slash) |idx_slash| {
                                    return self.match_from(subpath[idx_slash + 1 ..], 0, from_idx_part + 2);
                                } else {
                                    return false;
                                }
                            },

                            .asterisk => @panic("it shouldnt be possible to have two consecutive .asterisk tokens, they should be a .double_asterisk"),

                            .double_asterisk => @panic("it shouldnt be possible to have a .double_asterisk after a single .asterisk"),
                        }
                    } else {
                        // if we are here then this is the end and we match
                        std.debug.assert(self.parts.len - 1 == from_idx_part);
                        return true;
                    }
                },

                // NOTE: .slash must always be after a .double_asterisk, or it means its the end of the pattern
                .double_asterisk => {
                    return self.match_double_asterisk(subpath, 0, from_idx_part + 1);
                },
            }

            return false;
        }

        fn match_double_asterisk(self: Rule, path: []const u8, from_idx_path: usize, from_idx_part: usize) bool {
            // if there is no more parts to check after .double_asterisk then we match every directory
            if (from_idx_part >= self.parts.len - 1) {
                if (self.parts[self.parts.len - 1] == .double_asterisk) {
                    return path.len != 0;
                }

                return path[path.len - 1] == '/';
            }

            std.debug.assert(self.parts[from_idx_part] == .slash);
            if (from_idx_part + 1 >= self.parts.len) @panic("huh");
            const part = self.parts[from_idx_part + 1];
            // we look for all consecutive slashes and try matching by the next part
            const subpath = if (path[from_idx_path] == '/') path[from_idx_path + 1 ..] else path[from_idx_path..];

            var idx_slash: usize = 0;
            var out_buf: [200]u8 = undefined;
            while (true) {
                const path_from_slash = subpath[idx_slash..];
                switch (part) {
                    .literal => |txt| {
                        const maybe_idx_literal = std.mem.indexOf(u8, path_from_slash, txt);
                        if (maybe_idx_literal) |idx_literal| {
                            if (std.mem.indexOfScalar(u8, path_from_slash[0..idx_literal], '/') == null) {
                                return true;
                            }
                        }
                    },

                    .asterisk => {
                        if (from_idx_part + 2 >= self.parts.len) return true;

                        const next_part = self.parts[from_idx_part + 2];
                        switch (next_part) {
                            .literal => |txt| {
                                const maybe_idx_literal = std.mem.indexOf(u8, path_from_slash, txt);
                                if (maybe_idx_literal) |idx_literal| {
                                    if (std.mem.indexOfScalar(u8, path_from_slash[0..idx_literal], '/') == null) {
                                        return true;
                                    }
                                }
                            },

                            .asterisk, .double_asterisk => @panic("illegal"),

                            else => @panic(std.fmt.bufPrint(&out_buf, "unimplemented for: {s}", .{@tagName(next_part)}) catch "deez"),
                        }
                    },

                    else => @panic(std.fmt.bufPrint(&out_buf, "unimplemented for: {s}", .{@tagName(part)}) catch "nuts"),
                }

                const maybe_offset_slash = std.mem.indexOfScalar(u8, subpath[idx_slash..], '/');
                if (maybe_offset_slash) |offset_slash| {
                    idx_slash += offset_slash + 1;
                } else {
                    return false;
                }
            }

            return false;
        }
    };

    const RegexPart = union(enum) {
        literal: []const u8,
        char_range: CharRange,
        asterisk: void,
        double_asterisk: void,
        question_mark: void,
        slash: void,
    };

    const CharRange = struct {
        ranges: []const Range,
        is_negated: bool,
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
    }
};

/// Caller is supposed to pass in an arena allocator. No explicit
/// deallocation is done in an instance of a `Parser`.
const Parser = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    const Rule = Rules.Rule;
    const RegexPart = Rules.RegexPart;

    /// doesnt take ownership of `file`
    pub fn parse_from(self: Self, file: std.fs.File, from_gitignore_in: []const u8) !Rules {
        const content = try file.readToEndAlloc(self.allocator, MAX_USIZE);
        return self.parse(content, from_gitignore_in);
    }

    pub fn parse(self: Self, content: []const u8, from_gitignore_in: []const u8) !Rules {
        var rules: Rules = .init(self.allocator);
        if (std.mem.eql(u8, content, "")) return rules;

        var line_iter = std.mem.splitBackwardsScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            if (try parse_rule(self.allocator, line, from_gitignore_in)) |rule| {
                try rules.append(rule);
            }
        }

        return rules;
    }

    fn parse_rule(allocator: std.mem.Allocator, line: []const u8, from_gitignore_in: []const u8) !?Rule {
        if (std.mem.eql(u8, line, "")) return null;
        if (std.mem.startsWith(u8, line, "#")) return null;
        std.debug.assert(line.len > 0);

        var parts: std.ArrayList(RegexPart) = .init(allocator);

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
                    {
                        var characters: std.ArrayList(u8) = .init(allocator);
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

        const has_slashes = s: {
            for (parts.items) |p| {
                if (p == .slash) break :s true;
            }
            break :s false;
        };

        return .{
            .from_gitignore_in = from_gitignore_in,
            .pattern = line,
            .parts = try parts.toOwnedSlice(),
            .is_negated = is_negated,
            .is_for_dirs = line[line.len - 1] == '/',
            .has_slashes = has_slashes,
            .root_relative = root_relative,
        };
    }
};

pub fn init(arena: *std.heap.ArenaAllocator) GitIgnorer {
    const allocator = arena.allocator();
    return .{
        .cache = .init(allocator),
        .parser = .init(allocator),
        .arena = arena,
        .allocator = allocator,
    };
}

pub fn deinit(self: *GitIgnorer) void {
    self.arena.deinit();
}

/// goes in reverse order from the most specific rules until it reaches the first git
/// repository root (submodules operate independently from parent repositories)
pub fn match(self: *GitIgnorer, path: []const u8) !MatchResult {
    const rules = try self.get_rules(path);
    return self.match_with_rules(path, rules);
}

fn match_with_rules(_: GitIgnorer, path: []const u8, rules: Rules) MatchResult {
    for (rules.items()) |rule| {
        const rule_match = rule.match(path);
        if (rule_match != .none) return rule_match;
    }
    return .none;
}

/// returns all rules for path from the provided path up until the first git repository root
/// which is determined by the existance of a .git/info/exclude file
// NOTE: builds the cache from right to left
fn get_rules(self: *GitIgnorer, path: []const u8) !Rules {
    const cwd = std.fs.cwd();

    var rules: Rules = .init(self.allocator);
    var in_git_repo_root = false;

    var gen: PathParentGenerator = .init(path);
    while (gen.next()) |path_parent| {
        if (in_git_repo_root) break;
        if (self.cache.get(path_parent)) |path_parent_rules| {
            try rules.append_rules(path_parent_rules.rules);
            in_git_repo_root = path_parent_rules.in_git_repo_root;
            continue;
        }

        var path_parent_rules: Rules = .init(self.allocator);

        const ignore_path = try std.fmt.allocPrint(self.allocator, "{s}.gitignore", .{path_parent});
        const maybe_ignore = cwd.openFile(ignore_path, .{}) catch null;
        defer if (maybe_ignore) |ignore| ignore.close();
        if (maybe_ignore) |ignore| {
            try path_parent_rules.append_rules(try self.parser.parse_from(ignore, path_parent));
        }

        const exclude_path = try std.fmt.allocPrint(self.allocator, "{s}.git/info/exclude", .{path_parent});
        const maybe_exclude = cwd.openFile(exclude_path, .{}) catch null;
        defer if (maybe_exclude) |exclude| exclude.close();
        if (maybe_exclude) |exclude| {
            try path_parent_rules.append_rules(try self.parser.parse_from(exclude, path_parent));
            in_git_repo_root = true;
        }

        const key = try self.allocator.dupe(u8, path_parent);
        try self.cache.put(key, .{
            .in_git_repo_root = in_git_repo_root,
            .rules = path_parent_rules,
        });
        try rules.append_rules(path_parent_rules);
    }

    return rules;
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
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const p: Parser = .init(arena.allocator());
        const rules = try p.parse("", "./");

        try t.expectEqual(0, rules.len());
    }

    test "parser can produce a simple file rule" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const p: Parser = .init(arena.allocator());
        const rules = try p.parse("file.txt", "./");

        try t.expectEqual(1, rules.len());
        try t.expectEqual(1, rules.items()[0].parts.len);
        try t.expectEqualStrings("file.txt", rules.items()[0].parts[0].literal);
    }

    test "parser can produce many simple file rules" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const p: Parser = .init(arena.allocator());
        const rules = try p.parse(
            \\file_a.txt
            \\file_b.txt
        , "./");

        try t.expectEqual(2, rules.len());
        try t.expectEqual(1, rules.items()[0].parts.len);
        try t.expectEqual(1, rules.items()[1].parts.len);
        try t.expectEqualStrings("file_b.txt", rules.items()[0].parts[0].literal);
        try t.expectEqualStrings("file_a.txt", rules.items()[1].parts[0].literal);
    }

    test "parser ignores empty lines" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const p: Parser = .init(arena.allocator());
        const rules = try p.parse(
            \\file_a.txt
            \\
            \\file_b.txt
        , "./");

        try t.expectEqual(2, rules.len());
        try t.expectEqual(1, rules.items()[0].parts.len);
        try t.expectEqual(1, rules.items()[1].parts.len);
        try t.expectEqualStrings("file_b.txt", rules.items()[0].parts[0].literal);
        try t.expectEqualStrings("file_a.txt", rules.items()[1].parts[0].literal);
    }

    test "parser ignores commented lines" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const p: Parser = .init(arena.allocator());
        const rules = try p.parse(
            \\file_a.txt
            \\# file_b.txt
            \\#file_b.txt
            \\\#file_b.txt
        , "./");

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
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const p: Parser = .init(arena.allocator());
        const rules = try p.parse(
            \\*file_a.txt
            \\file_*.txt
            \\file_a.*
            \\file_*.*
            \\*file_*.*
        , "./");

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
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const p: Parser = .init(arena.allocator());
        const rules = try p.parse(
            \\!file_a.txt
            \\\!file_b.txt
            \\\!file_!.txt
        , "./");

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
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const p: Parser = .init(arena.allocator());
        const rules = try p.parse(
            \\file_a.txt
            \\dir/
        , "./");

        try t.expectEqual(2, rules.len());

        try t.expect(!rules.items()[1].is_for_dirs);
        try t.expect(rules.items()[0].is_for_dirs);
        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "dir" },
            .slash,
        }, rules.items()[0].parts);
    }

    test "parsing ?" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const p: Parser = .init(arena.allocator());
        const rules = try p.parse(
            \\file_?.txt
        , "./");

        try t.expectEqual(1, rules.len());

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "file_" },
            .question_mark,
            .{ .literal = ".txt" },
        }, rules.items()[0].parts);
    }

    test "parsing **" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const p: Parser = .init(arena.allocator());
        const rules = try p.parse(
            \\src/**/*.zig
            \\**/foo
            \\abc/**
        , "./");

        try t.expectEqual(3, rules.len());

        try t.expect(rules.items()[0].has_slashes);
        try t.expect(rules.items()[1].has_slashes);
        try t.expect(rules.items()[2].has_slashes);

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
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const p: Parser = .init(arena.allocator());
        const rules = try p.parse(
            \\file_[a-b].txt
            \\[a-zA-Z0-9].txt
            \\[a\-z].txt
            \\[xyz].txt
            \\[!xyz].txt
            \\[^xyz].txt
            \\[xyzA-Z].txt
        , "./");

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
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\*.txt
        , "./");
        try t.expectEqual(.none, g.match_with_rules("./src/search/search.zig", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./file.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./fileb.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./src/something/some.txt", rules));
    }

    test "matching for rules found in different directories" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        var rules = try g.parser.parse(
            \\./*.txt
        , "./");
        try rules.append_rules(try g.parser.parse(
            \\cba/**
        , "./abc/search/"));

        try t.expectEqual(.excluded, g.match_with_rules("./file.txt", rules));
        try t.expectEqual(.none, g.match_with_rules("./abc/file.txt", rules));
        try t.expectEqual(.none, g.match_with_rules("./abc/search/file.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./abc/search/cba/cba.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./abc/search/cba/new/", rules));
    }

    test "wildcard patterns" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\*.log
            \\temp*
            \\*debug*
            \\*.o
            \\*.tmp
        , "./");

        // *.log should match
        try t.expectEqual(.excluded, g.match_with_rules("./app.log", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./logs/error.log", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./production.log", rules));
        try t.expectEqual(.none, g.match_with_rules("./log.txt", rules));

        // temp* should match
        try t.expectEqual(.excluded, g.match_with_rules("./temp.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./temporary", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./build/temp_file", rules));
        try t.expectEqual(.none, g.match_with_rules("./mytemp", rules));

        // *debug* should match
        try t.expectEqual(.excluded, g.match_with_rules("./debug.log", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./mydebugfile", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./app_debug_output.txt", rules));
    }

    test "question mark wildcard" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\file?.txt
            \\debug?.log
        , "./");

        // file?.txt should match single character
        try t.expectEqual(.excluded, g.match_with_rules("./file1.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./filea.txt", rules));
        try t.expectEqual(.none, g.match_with_rules("./file10.txt", rules));
        try t.expectEqual(.none, g.match_with_rules("./file.txt", rules));

        // debug?.log should match
        try t.expectEqual(.excluded, g.match_with_rules("./debug1.log", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./debugx.log", rules));
        try t.expectEqual(.none, g.match_with_rules("./debug.log", rules));
        try t.expectEqual(.none, g.match_with_rules("./debug10.log", rules));
    }

    test "character class patterns" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\*.[oa]
            \\file[0-9].txt
        , "./");

        // *.[oa] should match .o and .a files
        try t.expectEqual(.excluded, g.match_with_rules("./main.o", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./lib.a", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./build/test.o", rules));
        try t.expectEqual(.none, g.match_with_rules("./main.c", rules));

        // file[0-9].txt should match digits
        try t.expectEqual(.excluded, g.match_with_rules("./file0.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./file9.txt", rules));
        try t.expectEqual(.none, g.match_with_rules("./filea.txt", rules));
        try t.expectEqual(.none, g.match_with_rules("./file10.txt", rules));
    }

    test "directory patterns with trailing slash" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\node_modules/
            \\build/
            \\temp/
        , "./");

        // Should match directories and their contents
        try t.expectEqual(.excluded, g.match_with_rules("./node_modules/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./node_modules/package.json", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./src/node_modules/lib.js", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./build/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./build/output.bin", rules));

        // Should not match files with same name
        try t.expectEqual(.none, g.match_with_rules("./node_modules.txt", rules));
        try t.expectEqual(.none, g.match_with_rules("./build.log", rules));
    }

    test "leading slash patterns - root relative" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\/debug.log
            \\/build
            \\/config.json
        , "./");

        // Should match only in root
        try t.expectEqual(.excluded, g.match_with_rules("./debug.log", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./build", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./config.json", rules));

        // Should not match in subdirectories
        try t.expectEqual(.none, g.match_with_rules("./src/debug.log", rules));
        try t.expectEqual(.none, g.match_with_rules("./logs/debug.log", rules));
        try t.expectEqual(.none, g.match_with_rules("./tools/build", rules));
    }

    test "double asterisk patterns - recursive matching" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\**/logs
            \\**/logs/*.log
            \\logs/**/*.log
            \\abc/**
        , "./");

        // **/logs should match logs directory anywhere
        try t.expectEqual(.excluded, g.match_with_rules("./logs/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./src/logs/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./deep/nested/logs/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./logs/error.log", rules));

        // **/logs/*.log should match .log files in any logs directory
        try t.expectEqual(.excluded, g.match_with_rules("./logs/app.log", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./src/logs/debug.log", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./logs/nested/app.log", rules));

        // logs/**/*.log should match .log files in logs tree
        try t.expectEqual(.excluded, g.match_with_rules("./logs/app.log", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./logs/nested/debug.log", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./logs/very/deep/error.log", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./other/logs/app.log", rules));

        // abc/** should match everything inside abc
        try t.expectEqual(.excluded, g.match_with_rules("./abc/files/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./abc/file.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./abc/nested/deep/file.txt", rules));
        try t.expectEqual(.none, g.match_with_rules("./abc/", rules)); // directory itself not matched
    }

    test "double asterisk pattern followed by a star" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\abc/**/*
        , "./");

        try t.expectEqual(.excluded, g.match_with_rules("./abc/nested/deep/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./abc/nested/deep.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./abc/nested/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./abc/file.txt", rules));
    }

    test "double asterisk pattern followed by a star, followed by a literal" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\abc/**/*.txt
        , "./");

        try t.expectEqual(.none, g.match_with_rules("./abc/nested/deep/", rules));
        try t.expectEqual(.none, g.match_with_rules("./abc/nested/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./abc/file.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./abc/nested/deep.txt", rules));
    }

    test "middle double asterisk patterns" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\a/**/b
            \\src/**/test
            \\**/cache/**
        , "./");

        // a/**/b should match zero or more directories between a and b
        try t.expectEqual(.excluded, g.match_with_rules("./a/b", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./a/x/b", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./a/x/y/z/b", rules));
        try t.expectEqual(.none, g.match_with_rules("./b/a", rules));

        // src/**/test should match test anywhere under src
        try t.expectEqual(.excluded, g.match_with_rules("./src/test", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./src/unit/test", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./src/deep/nested/test", rules));
        try t.expectEqual(.none, g.match_with_rules("./test/src", rules));

        // **/cache/** should match cache anywhere and everything inside
        try t.expectEqual(.excluded, g.match_with_rules("./cache/file.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./src/cache/data.json", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./deep/path/cache/nested/file.bin", rules));
    }

    const t = std.testing;
};
const std = @import("std");
const PathParentGenerator = @import("PathParentGenerator.zig");

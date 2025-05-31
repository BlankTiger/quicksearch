//!
//! Caller is supposed to pass in an arena allocator. No explicit
//! deallocation is done in an instance of a `Parser`.
//!

const Parser = @This();

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Parser {
    return .{
        .allocator = allocator,
    };
}

/// doesnt take ownership of `file`
pub fn parse_from(self: Parser, file: std.fs.File, from_gitignore_in: []const u8) !Rules {
    const content = try file.readToEndAlloc(self.allocator, comptime std.math.maxInt(usize));
    return self.parse(content, from_gitignore_in);
}

pub fn parse(self: Parser, content: []const u8, from_gitignore_in: []const u8) !Rules {
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

    var maybe_idx_backslash: ?usize = null;
    while (idx < line.len) {
        const ch = line[idx];
        switch (ch) {
            '*' => {
                if (maybe_idx_backslash) |idx_backslash| {
                    defer maybe_idx_backslash = null;
                    if (idx_backslash == idx - 1) {
                        if (idx_start_literal) |idx_start| if (line[idx_start..idx_backslash].len > 0) {
                            try parts.append(.{ .literal = try allocator.dupe(u8, line[idx_start..idx_backslash]) });
                            idx_start_literal = null;
                        };
                        idx_start_literal = idx;
                        idx += 1;
                        continue;
                    }
                }

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
                if (maybe_idx_backslash) |idx_backslash| {
                    defer maybe_idx_backslash = null;
                    if (idx_backslash == idx - 1) {
                        if (idx_start_literal) |idx_start| if (line[idx_start..idx_backslash].len > 0) {
                            try parts.append(.{ .literal = try allocator.dupe(u8, line[idx_start..idx_backslash]) });
                            idx_start_literal = null;
                        };
                        idx_start_literal = idx;
                        idx += 1;
                        continue;
                    }
                }

                if (idx_start_literal) |idx_start| {
                    try parts.append(.{ .literal = try allocator.dupe(u8, line[idx_start..idx]) });
                    idx_start_literal = null;
                }
                idx += 1;
                try parts.append(.question_mark);
            },

            '\\' => {
                if (idx_start_literal == null) {
                    idx_start_literal = idx;
                }
                maybe_idx_backslash = idx;
                idx += 1;
            },

            '[' => {
                if (maybe_idx_backslash) |idx_backslash| {
                    defer maybe_idx_backslash = null;
                    if (idx_backslash == idx - 1) {
                        if (idx_start_literal) |idx_start| if (line[idx_start..idx_backslash].len > 0) {
                            try parts.append(.{ .literal = try allocator.dupe(u8, line[idx_start..idx_backslash]) });
                            idx_start_literal = null;
                        };
                        idx_start_literal = idx;
                        idx += 1;
                        continue;
                    }
                }

                if (idx_start_literal) |idx_start| {
                    try parts.append(.{ .literal = try allocator.dupe(u8, line[idx_start..idx]) });
                    idx_start_literal = null;
                }

                idx += 1;

                const range_negated = line[idx] == '!' or line[idx] == '^';
                if (range_negated) idx += 1;

                var ranges: std.ArrayList(RegexPart.Range) = .init(allocator);
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
                if (maybe_idx_backslash) |idx_backslash| {
                    defer maybe_idx_backslash = null;
                    if (idx_backslash == idx - 1) {
                        if (idx_start_literal) |idx_start| if (line[idx_start..idx_backslash].len > 0) {
                            try parts.append(.{ .literal = try allocator.dupe(u8, line[idx_start..idx_backslash]) });
                            idx_start_literal = null;
                        };
                        idx_start_literal = idx;
                        idx += 1;
                        continue;
                    }
                }

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
        .pattern = if (builtin.is_test) line else {},
        .parts = try parts.toOwnedSlice(),
        .is_negated = is_negated,
        .is_for_dirs = line[line.len - 1] == '/',
        .has_slashes = has_slashes,
        .root_relative = root_relative,
    };
}

test {
    _ = ParserTests;
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
            \\\[xyzA-Z].txt
            \\\[xyzA-Z\].txt
        , "./");

        try t.expectEqual(9, rules.len());

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "file_" },
            .{ .char_range = .{
                .ranges = &[_]RegexPart.Range{
                    .{ .range = .{ .start = 'a', .end = 'b' } },
                },
                .is_negated = false,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[8].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .char_range = .{
                .ranges = &[_]RegexPart.Range{
                    .{ .range = .{ .start = 'a', .end = 'z' } },
                    .{ .range = .{ .start = 'A', .end = 'Z' } },
                    .{ .range = .{ .start = '0', .end = '9' } },
                },
                .is_negated = false,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[7].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .char_range = .{
                .ranges = &[_]RegexPart.Range{
                    .{ .single = 'a' },
                    .{ .single = '-' },
                    .{ .single = 'z' },
                },
                .is_negated = false,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[6].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .char_range = .{
                .ranges = &[_]RegexPart.Range{
                    .{ .single = 'x' },
                    .{ .single = 'y' },
                    .{ .single = 'z' },
                },
                .is_negated = false,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[5].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .char_range = .{
                .ranges = &[_]RegexPart.Range{
                    .{ .single = 'x' },
                    .{ .single = 'y' },
                    .{ .single = 'z' },
                },
                .is_negated = true,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[4].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .char_range = .{
                .ranges = &[_]RegexPart.Range{
                    .{ .single = 'x' },
                    .{ .single = 'y' },
                    .{ .single = 'z' },
                },
                .is_negated = true,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[3].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .char_range = .{
                .ranges = &[_]RegexPart.Range{
                    .{ .single = 'x' },
                    .{ .single = 'y' },
                    .{ .single = 'z' },
                    .{ .range = .{ .start = 'A', .end = 'Z' } },
                },
                .is_negated = false,
            } },
            .{ .literal = ".txt" },
        }, rules.items()[2].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "[xyzA-Z].txt" },
        }, rules.items()[1].parts);

        try t.expectEqualDeep(&[_]RegexPart{
            .{ .literal = "[xyzA-Z\\].txt" },
        }, rules.items()[0].parts);
    }

    const t = std.testing;
};

const std = @import("std");
const builtin = @import("builtin");
const Rule = @import("rules.zig").Rule;
const Rules = @import("rules.zig").Rules;
const RegexPart = @import("rules.zig").RegexPart;

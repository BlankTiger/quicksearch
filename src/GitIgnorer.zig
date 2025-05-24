/// holds paths to directories and if they are git directories,
/// then they hold IgnoreRules, otherwise it's null, which means
/// that directory is not a git directory or it didnt contain
/// any rules
cache: Cache,
parser: Parser,
allocator: std.mem.Allocator,

const GitIgnorer = @This();
const Cache = std.StringHashMap(Rules);

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
    const Part = Rule.Part;

    pub fn parse(self: *const Self, content: []const u8) !Rules {
        if (std.mem.eql(u8, content, "")) return .init(self.allocator, &.{});

        var list: std.ArrayList(Rule) = .init(self.allocator);
        errdefer list.deinit();

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            if (try parse_rule(list.allocator, line)) |rule| {
                try list.append(rule);
            }
        }

        return .init(list.allocator, try list.toOwnedSlice());
    }

    fn parse_rule(allocator: std.mem.Allocator, line: []const u8) !?Rule {
        if (std.mem.eql(u8, line, "")) return null;
        if (std.mem.startsWith(u8, line, "#")) return null;
        std.debug.assert(line.len > 0);

        var parts: std.ArrayList(Part) = .init(allocator);
        errdefer parts.deinit();

        var idx: usize = 0;
        var idx_start_literal: ?usize = null;
        var is_negated: bool = false;
        if (line[idx] == '!') {
            is_negated = true;
            idx = 1;
        } else if (line.len > 1 and line[0] == '\\' and line[1] == '!') {
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
                    idx += 1;
                    try parts.append(.star);
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
        };
    }
};

const Rules = struct {
    items: []const Rule,
    allocator: std.mem.Allocator,

    /// must be the same `allocator`, that allocated the `rules`
    pub fn init(allocator: std.mem.Allocator, rules: []const Rule) Rules {
        return .{
            .allocator = allocator,
            .items = rules,
        };
    }

    pub fn deinit(self: Rules) void {
        for (self.items) |rule| rule.deinit(self.allocator);
        self.allocator.free(self.items);
    }

    const Rule = struct {
        parts: []Part,
        is_negated: bool = false,

        const Part = union(enum) {
            star: void,
            literal: []const u8,

            inline fn deinit(self: Part, allocator: std.mem.Allocator) void {
                switch (self) {
                    .literal => |txt| allocator.free(txt),
                    .star => {},
                }
            }
        };

        pub fn deinit(self: Rule, allocator: std.mem.Allocator) void {
            for (self.parts) |part| part.deinit(allocator);
            allocator.free(self.parts);
        }
    };
};

test {
    _ = ParserTests;
}

const ParserTests = struct {
    test "parser can produce rules from provided text" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse("");
        defer rules.deinit();

        try t.expectEqual(0, rules.items.len);
    }

    test "parser can produce a simple file rule" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse("file.txt");
        defer rules.deinit();

        try t.expectEqual(1, rules.items.len);
        try t.expectEqual(1, rules.items[0].parts.len);
        try t.expectEqualStrings("file.txt", rules.items[0].parts[0].literal);
    }

    test "parser can produce many simple file rules" {
        const p: Parser = .init(t.allocator);
        defer p.deinit();
        const rules = try p.parse(
            \\file_a.txt
            \\file_b.txt
        );
        defer rules.deinit();

        try t.expectEqual(2, rules.items.len);
        try t.expectEqual(1, rules.items[0].parts.len);
        try t.expectEqual(1, rules.items[1].parts.len);
        try t.expectEqualStrings("file_a.txt", rules.items[0].parts[0].literal);
        try t.expectEqualStrings("file_b.txt", rules.items[1].parts[0].literal);
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

        try t.expectEqual(2, rules.items.len);
        try t.expectEqual(1, rules.items[0].parts.len);
        try t.expectEqual(1, rules.items[1].parts.len);
        try t.expectEqualStrings("file_a.txt", rules.items[0].parts[0].literal);
        try t.expectEqualStrings("file_b.txt", rules.items[1].parts[0].literal);
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

        try t.expectEqual(2, rules.items.len);
        try t.expectEqual(1, rules.items[0].parts.len);
        try t.expectEqual(1, rules.items[1].parts.len);
        try t.expectEqualStrings("file_a.txt", rules.items[0].parts[0].literal);
        try t.expectEqualStrings("#file_b.txt", rules.items[1].parts[0].literal);
    }

    const Part = Rules.Rule.Part;

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

        try t.expectEqual(5, rules.items.len);

        try t.expectEqualDeep(&[_]Part{
            .star,
            .{ .literal = "file_a.txt" },
        }, rules.items[0].parts);

        try t.expectEqualDeep(&[_]Part{
            .{ .literal = "file_" },
            .star,
            .{ .literal = ".txt" },
        }, rules.items[1].parts);

        try t.expectEqualDeep(&[_]Part{
            .{ .literal = "file_a." },
            .star,
        }, rules.items[2].parts);

        try t.expectEqualDeep(&[_]Part{
            .{ .literal = "file_" },
            .star,
            .{ .literal = "." },
            .star,
        }, rules.items[3].parts);

        try t.expectEqualDeep(&[_]Part{
            .star,
            .{ .literal = "file_" },
            .star,
            .{ .literal = "." },
            .star,
        }, rules.items[4].parts);
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

        try t.expectEqual(3, rules.items.len);

        try t.expect(rules.items[0].is_negated);
        try t.expectEqualDeep(&[_]Part{.{ .literal = "file_a.txt" }}, rules.items[0].parts);

        try t.expect(!rules.items[1].is_negated);
        try t.expectEqualDeep(&[_]Part{
            .{ .literal = "!file_b.txt" },
        }, rules.items[1].parts);

        try t.expect(!rules.items[2].is_negated);
        try t.expectEqualDeep(&[_]Part{
            .{ .literal = "!file_!.txt" },
        }, rules.items[2].parts);
    }

    const t = std.testing;
};

const std = @import("std");
const PathParentGenerator = @import("PathParentGenerator.zig");

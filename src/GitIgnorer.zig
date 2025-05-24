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

    pub fn deinit(self: Self) void { _ = self; }

    pub fn parse(self: *const Self, content: []const u8) !Rules {
        if (std.mem.eql(u8, content, "")) return .init(self.allocator, &.{});

        var list: std.ArrayList(Rule) = .init(self.allocator);
        errdefer list.deinit();

        try list.append(.{ .literal = try list.allocator.dupe(u8, content) });

        return .init(list.allocator, try list.toOwnedSlice());
    }
};

const Rules = struct {
    items: []const Rule,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// must be the same `allocator`, that allocated the `rules`
    pub fn init(allocator: std.mem.Allocator, rules: []const Rule) Self {
        return .{
            .allocator = allocator,
            .items = rules,
        };
    }

    pub fn deinit(self: Self) void {
        for (self.items) |rule| {
            switch (rule) {
                .literal => |txt| self.allocator.free(txt),
            }
        }
        self.allocator.free(self.items);
    }
};

const Rule = union(enum) {
    literal: []const u8,
};

test {
    _ = Tests;
}

const Tests = struct{
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
        try t.expectEqualStrings("file.txt", rules.items[0].literal);
    }

    const t = std.testing;
};

const std = @import("std");
const PathParentGenerator = @import("PathParentGenerator.zig");

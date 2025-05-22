/// holds paths to directories and if they are git directories,
/// then they hold IgnoreRules, otherwise it's null, which means
/// that directory is not a git directory or it didnt contain
/// any rules
cache: Cache,
allocator: std.mem.Allocator,

const Cache = std.StringHashMap(?IgnoreRules);

const IgnoreRules = struct {
    rules: Rules,
    allocator: std.mem.Allocator,

    const Rules = std.ArrayList(Rule);
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .rules = .init(allocator),
            .allocator = allocator,
        };
    }

    pub fn init_with(allocator: std.mem.Allocator, rule: Rule) !Self {
        var rules: Rules = try .initCapacity(allocator, 1);
        rules.appendAssumeCapacity(rule);
        return .{
            .rules = rules,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Self) void {
        self.rules.deinit();
    }

    /// `rules` always overwrite existing `self.rules`
    pub fn merge(self: *Self, rules: IgnoreRules) !void {

    }

    pub fn match(self: Self, path: []const u8) bool {}
};

const Rule = struct {};

const GitIgnorer = @This();

pub fn init(allocator: std.mem.Allocator) GitIgnorer {
    return .{
        .cache = .init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *GitIgnorer) void {
    self.cache.deinit();
}

/// recursively go backwards until we encounter a directory that is a git
/// directory, if its not then we can store the whole thing in the cache and
/// not check it again if we find the same prefix
///
/// if some prefix at some point turns out to be a git directory, then if
/// its not in the cache, we must add it and add parsed .gitignore and
/// $GIT_DIR/info/exclude or something like that there
pub fn is_ignored(self: *GitIgnorer, path: []const u8) !bool {
    const maybe_rules = try self.get_rules(path);

    if (maybe_rules) |rules| if (rules.match(path)) {
        return true;
    };
    return false;
}

test "show rules" {
    var ignorer: GitIgnorer = .init(std.testing.allocator);
    defer ignorer.deinit();

    const rules = ignorer.is_ignored("./src/search/search.zig");
    std.debug.print("rules: {}\n", .{rules});
}

const std = @import("std");

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

fn get_rules(self: *GitIgnorer, path: []const u8) !?IgnoreRules {
    if (path.len < 2) return null;
    if (path[0] != '/' and !(path[0] == '.' and path[1] == '/')) @panic("we should only have paths that start with a './' or a '/' here");

    return try self.find_closest_rules(path);
}

/// go from the leftmost directory and build the cache if it's not built already
/// and return the rules for the path that was passed in here
fn find_closest_rules(self: *GitIgnorer, path: []const u8) !?IgnoreRules {
    const cwd = std.fs.cwd();
    var closest_rules: ?IgnoreRules = null;

    var gen: PathParentGenerator = .init(path);
    while (gen.next()) |path_part| {
        if ((try cwd.statFile(path_part)).kind == .file) return closest_rules;

        var maybe_rules: ?IgnoreRules = null;
        if (self.cache.get(path_part)) |m_rules| {
            // we already parsed this path
            if (m_rules) |rules| maybe_rules = rules;
        } else {
            // havent seen this path before
            var dir = try cwd.openDir(path_part, .{});
            defer dir.close();

            try self.parse_rules_in_dir(dir, &maybe_rules);
            try self.cache.put(path_part, maybe_rules);
        }

        if (maybe_rules) |rules| {
            if (closest_rules) |_| {
                try closest_rules.?.merge(rules);
            } else {
                closest_rules = rules;
            }
        }
    }

    return closest_rules;
}

fn parse_rules_in_dir(self: GitIgnorer, dir: std.fs.Dir, maybe_rules: *?IgnoreRules) !void {
    const maybe_exclude = dir.openFile(".git/info/exclude", .{}) catch null;
    if (maybe_exclude) |exclude| {
        defer exclude.close();
        try self.parse_rules(exclude, maybe_rules);
    }

    const maybe_gitignore = dir.openFile(".gitignore", .{}) catch null;
    if (maybe_gitignore) |gitignore| {
        defer gitignore.close();
        try self.parse_rules(gitignore, maybe_rules);
    }
}

fn parse_rules(self: GitIgnorer, ignore_file: std.fs.File, maybe_rules: *?IgnoreRules) !void {
    var new_rules: IgnoreRules = .init(self.allocator);
    errdefer new_rules.deinit();

    const file_content = try ignore_file.readToEndAlloc(self.allocator, comptime std.math.maxInt(usize));
    defer self.allocator.free(file_content);

    if (maybe_rules.*) |_| {
        try maybe_rules.*.?.merge(new_rules);
        new_rules.deinit();
    } else {
        maybe_rules.* = new_rules;
    }
}

test "show rules" {
    var ignorer: GitIgnorer = .init(std.testing.allocator);
    defer ignorer.deinit();

    const rules = ignorer.is_ignored("./src/search/search.zig");
    std.debug.print("rules: {}\n", .{rules});
}

const std = @import("std");
const PathParentGenerator = @import("PathParentGenerator.zig");

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
    var result: MatchResult = .none;
    for (rules.items()) |rule| {
        const rule_match = rule.match(path);
        if (rule_match == .included) return rule_match;
        if (rule_match != .none) result = rule_match;
    }
    return result;
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

test {
    _ = MatchingTests;
}

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

    test "negation patterns with exclamation mark" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\*.log
            \\!important.log
            \\build/
            \\!build/keep.txt
            \\temp*
            \\!temporary_config.json
        , "./");

        // *.log should match, but !important.log should negate
        try t.expectEqual(.excluded, g.match_with_rules("./app.log", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./error.log", rules));
        try t.expectEqual(.included, g.match_with_rules("./important.log", rules)); // negated

        // build/ should match, but !build/keep.txt should negate
        try t.expectEqual(.excluded, g.match_with_rules("./build/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./build/output.bin", rules));
        try t.expectEqual(.included, g.match_with_rules("./build/keep.txt", rules)); // negated

        // temp* should match, but !temporary_config.json should negate
        try t.expectEqual(.excluded, g.match_with_rules("./temp.txt", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./temporary.log", rules));
        try t.expectEqual(.included, g.match_with_rules("./temporary_config.json", rules)); // negated
    }

    test "complex" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\# Compiled output
            \\/dist
            \\/tmp
            \\/out-tsc
            \\
            \\# Node modules
            \\node_modules/
            \\npm-debug.log*
            \\yarn-debug.log*
            \\yarn-error.log*
            \\
            \\# IDEs and editors
            \\.vscode/
            \\.idea/
            \\*.swp
            \\*.swo
            \\*~
            \\
            \\# OS
            \\.DS_Store
            \\Thumbs.db
            \\
            \\# Logs
            \\logs/
            \\*.log
            \\!important.log
        , "./");

        // Compiled output (root only)
        try t.expectEqual(.excluded, g.match_with_rules("./dist", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./tmp", rules));
        try t.expectEqual(.none, g.match_with_rules("./src/dist", rules));

        // Node modules
        try t.expectEqual(.excluded, g.match_with_rules("./node_modules/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./node_modules/lodash/index.js", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./npm-debug.log", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./npm-debug.log.1", rules));

        // IDEs and editors
        try t.expectEqual(.excluded, g.match_with_rules("./.vscode/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./.vscode/settings.json", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./src/.idea/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./file.swp", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./backup~", rules));

        // OS files
        try t.expectEqual(.excluded, g.match_with_rules("./.DS_Store", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./folder/.DS_Store", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./Thumbs.db", rules));

        // Logs with negation
        try t.expectEqual(.excluded, g.match_with_rules("./logs/", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./app.log", rules));
        try t.expectEqual(.included, g.match_with_rules("./important.log", rules)); // negated
    }

    test "escape characters" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\foo\[01].txt
            \\file\*.log
            \\dir\?name
            \\\!not_negated.txt
        , "./");

        // Should match literal characters, not wildcards
        try t.expectEqual(.excluded, g.match_with_rules("./foo[01].txt", rules));
        try t.expectEqual(.none, g.match_with_rules("./foo0.txt", rules));
        try t.expectEqual(.none, g.match_with_rules("./foo1.txt", rules));

        try t.expectEqual(.excluded, g.match_with_rules("./file*.log", rules));
        try t.expectEqual(.none, g.match_with_rules("./fileapp.log", rules));

        try t.expectEqual(.excluded, g.match_with_rules("./dir?name", rules));
        try t.expectEqual(.none, g.match_with_rules("./dirname", rules));

        // Escaped exclamation mark (not negation)
        try t.expectEqual(.excluded, g.match_with_rules("./!not_negated.txt", rules));
    }

    test "everything excluded, some includes" {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        var g: GitIgnorer = .init(&arena);
        defer g.deinit();
        const rules = try g.parser.parse(
            \\*
            \\!*/
            \\!*.keep
            \\.*
            \\!.gitignore
        , "./");

        // * should match everything, but negations should override
        try t.expectEqual(.excluded, g.match_with_rules("./file.txt", rules));
        try t.expectEqual(.included, g.match_with_rules("./dir/", rules)); // negated
        try t.expectEqual(.included, g.match_with_rules("./important.keep", rules)); // negated

        // .* should match hidden files, but .gitignore negated
        try t.expectEqual(.excluded, g.match_with_rules("./.hidden", rules));
        try t.expectEqual(.excluded, g.match_with_rules("./.env", rules));
        try t.expectEqual(.included, g.match_with_rules("./.gitignore", rules)); // negated
    }

    const t = std.testing;
};

const std = @import("std");
const builtin = @import("builtin");
const PathParentGenerator = @import("PathParentGenerator.zig");
const Parser = @import("Parser.zig");
const Rules = @import("rules.zig").Rules;
const MatchResult = @import("rules.zig").MatchResult;

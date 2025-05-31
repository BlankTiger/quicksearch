pub const Options = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,

    path: ?[]const u8 = null,
    extension: ?[]const u8 = null,
    ignore_hidden: bool = true,
    respect_gitignore: bool = true,
    gitignorer: ?GitIgnorer = null,

    fn deinit(self: *Options) void {
        if (self.gitignorer) |*g| g.deinit();
    }
};

const PathList = std.ArrayList([]const u8);

pub fn find_files(opts: *Options) !PathList {
    var paths: PathList = try .initCapacity(opts.allocator, 200);
    errdefer {
        for (paths.items) |p| opts.allocator.free(p);
        paths.deinit();
    }

    if (opts.path) |path| {
        const cwd = std.fs.cwd();
        const stat = try cwd.statFile(path);
        switch (stat.kind) {
            .file => {
                try paths.append(path);
                return paths;
            },
            .directory => {
                try find_files_in_dir(path, &paths, opts);
            },
            else => {},
        }
    } else {
        try find_files_in_dir(".", &paths, opts);
    }

    return paths;
}

fn find_files_in_dir(path: []const u8, paths: *PathList, opts: *Options) !void {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();

    while (try iter.next()) |e| {
        if (opts.ignore_hidden and std.mem.startsWith(u8, e.name, ".")) continue;

        switch (e.kind) {
            .file => {
                if (opts.extension != null and !std.mem.endsWith(u8, e.name, opts.extension.?)) continue;

                const relative = try make_relative(opts.allocator, path, e.name);
                if (opts.respect_gitignore and try opts.gitignorer.?.match(relative) == .excluded) {
                    opts.allocator.free(relative);
                    continue;
                }

                errdefer opts.allocator.free(relative);
                try paths.append(relative);
            },
            .directory => {
                if (std.mem.eql(u8, e.name, ".git")) continue;
                const relative = try make_relative(opts.allocator, path, e.name);
                if (opts.respect_gitignore and try opts.gitignorer.?.match(relative) == .excluded) {
                    opts.allocator.free(relative);
                    continue;
                }

                defer opts.allocator.free(relative);
                try find_files_in_dir(relative, paths, opts);
            },
            else => {},
        }
    }
}

/// caller owns the resulting memory
fn make_relative(allocator: std.mem.Allocator, pre: []const u8, post: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ pre, post });
}

test {
    if (config.running_in_ci) {
        return error.SkipZigTest;
    }

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    var opts: Options = .{
        .allocator = t.allocator,
        .ignore_hidden = false,
        .gitignorer = .init(&arena_state),
    };
    defer {
        // std.debug.print("used: {d} KB\n", .{arena_state.queryCapacity() / 1024});
        opts.deinit();
    }
    const paths = try find_files(&opts);
    defer {
        for (paths.items) |p| {
            opts.allocator.free(p);
        }
        paths.deinit();
    }

    const git_cmd_res = try std.process.Child.run(.{
        .allocator = arena_state.allocator(),
        .cwd_dir = std.fs.cwd(),
        .argv = &.{
            "git",
            "ls-files",
        },
    });
    var git_ls: std.ArrayList([]const u8) = .init(arena_state.allocator());
    var line_iter = std.mem.splitScalar(u8, std.mem.trim(u8, git_cmd_res.stdout, "\n\t "), '\n');
    while (line_iter.next()) |l| try git_ls.append(l);
    const git_ls_lines = git_ls.items;
    // for (git_ls_lines) |line| {
    //     std.debug.print("1: {s}\n", .{line});
    // }
    //
    // for (paths.items) |p| {
    //     std.debug.print("2: {s}\n", .{p});
    // }
    try t.expectEqual(git_ls_lines.len, paths.items.len);
    var found_equal: usize = 0;
    for (git_ls_lines) |line| {
        for (paths.items) |p| {
            if (std.mem.eql(u8, p[2..], line)) found_equal += 1;
        }
    }
    try t.expectEqual(git_ls_lines.len, found_equal);
}

const t = std.testing;
const std = @import("std");
const config = @import("config");
const GitIgnorer = @import("gitignore.zig").GitIgnorer;

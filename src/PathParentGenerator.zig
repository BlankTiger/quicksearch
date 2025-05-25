const PathParentGenerator = @This();

path: []const u8,
path_part: []const u8,
idx_parent: usize,

pub fn init(path: []const u8) PathParentGenerator {
    std.debug.assert(path.len > 2);
    std.debug.assert(std.mem.startsWith(u8, path, "/") or std.mem.startsWith(u8, path, "./"));

    return .{
        .path = path,
        .path_part = path,
        .idx_parent = path.len,
    };
}

pub fn next(self: *PathParentGenerator) ?[]const u8 {
    if (self.path_part.len == 0) return null;

    const idx_prev = self.idx_parent;
    const maybe_idx = std.mem.lastIndexOfScalar(u8, self.path[0..idx_prev-1], '/');
    if (maybe_idx) |idx| {
        self.idx_parent = idx + 1;
        self.path_part = self.path[0..self.idx_parent];
        return self.path[0..idx_prev];
    }
    self.path_part = "";
    return self.path[0..idx_prev];
}

test "relative" {
    const expected: []const []const u8 = &.{
        "./src/search/search.zig",
        "./src/search/",
        "./src/",
        "./",
    };

    var gen: PathParentGenerator = .init("./src/search/search.zig");
    var actual: std.ArrayList([]const u8) = .init(std.testing.allocator);
    defer actual.deinit();
    while (gen.next()) |parent| {
        try actual.append(parent);
    }

    try std.testing.expectEqual(expected.len, actual.items.len);
    for (expected, actual.items) |e, a| {
        try std.testing.expectEqualStrings(e, a);
    }
}

test "absolute" {
    const expected: []const []const u8 = &.{
        "/src/search/search.zig",
        "/src/search/",
        "/src/",
        "/",
    };

    var gen: PathParentGenerator = .init("/src/search/search.zig");
    var actual: std.ArrayList([]const u8) = .init(std.testing.allocator);
    defer actual.deinit();
    while (gen.next()) |parent| {
        try actual.append(parent);
    }

    try std.testing.expectEqual(expected.len, actual.items.len);
    for (expected, actual.items) |e, a| {
        try std.testing.expectEqualStrings(e, a);
    }
}

const std = @import("std");

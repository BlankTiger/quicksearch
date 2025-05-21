pub const PathParentGenerator = struct {
    path: []const u8,
    path_part: []const u8,
    idx_parent: usize = 0,
    absolute: bool = false,

    pub fn init(path: []const u8) PathParentGenerator {
        std.debug.assert(path.len > 2);
        std.debug.assert(std.mem.startsWith(u8, path, "/") or std.mem.startsWith(u8, path, "./"));

        const absolute = std.mem.indexOfScalar(u8, path, '/').? == 0;
        return .{
            .path = path,
            .path_part = "",
            .idx_parent = 0,
            .absolute = absolute,
        };
    }

    pub fn next(self: *PathParentGenerator) ?[]const u8 {
        std.debug.assert(self.path_part.len <= self.path.len);
        if (self.path_part.len == self.path.len) return null;

        const maybe_idx = std.mem.indexOfScalar(u8, self.path[self.idx_parent..], '/');
        if (maybe_idx) |idx| {
            const offset_idx_parent = idx + 1;
            self.idx_parent += offset_idx_parent;
            self.path_part = self.path[0..self.idx_parent];
            return self.path_part;
        }
        self.path_part = self.path;
        return self.path;
    }
};

test "relative" {
    const expected: []const []const u8 = &.{
        "./",
        "./src/",
        "./src/search/",
        "./src/search/search.zig",
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
        "/",
        "/src/",
        "/src/search/",
        "/src/search/search.zig",
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

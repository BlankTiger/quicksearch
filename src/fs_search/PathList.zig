const PathList = @This();

list: std.ArrayList([]const u8),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) PathList {
    return .{
        .list = .init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: PathList) void {
    for (self.list.items) |i| self.allocator.free(i);
    self.list.deinit();
}

pub fn append(self: *PathList, path: []const u8) !bool {
    try self.list.append(path);
    return true;
}

pub fn items(self: PathList) []const []const u8 {
    return self.list.items;
}

const std = @import("std");

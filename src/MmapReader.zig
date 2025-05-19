data: []const align(heap.page_size_min) u8,

const Self = @This();

pub fn init(path: []const u8) !Self {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    const stats = try posix.fstat(file.handle);
    const m = try posix.mmap(
        null,
        @intCast(stats.size),
        posix.PROT.READ,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );
    return .{ .data = m };
}

pub fn deinit(self: Self) void {
    posix.munmap(self.data);
}

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const heap = std.heap;
const fs = std.fs;

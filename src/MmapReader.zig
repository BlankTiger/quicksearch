data: []align(heap.page_size_min) const u8,
has_data: bool = true,

const MmapReader = @This();

pub fn init(path: []const u8) !MmapReader {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    const stats = try posix.fstat(file.handle);
    if (stats.size == 0) {
        return .{
            .data = &.{},
            .has_data = false,
        };
    }
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

pub fn deinit(self: MmapReader) void {
    if (self.has_data) posix.munmap(self.data);
}

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const heap = std.heap;
const fs = std.fs;

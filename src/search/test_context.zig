pub const FNType = *const fn (
    std.mem.Allocator,
    []const u8,
    []const u8,
) anyerror![]lib.SearchResult;

pub const search_fns: [3]struct { FNType, []const u8 } = .{
    .{ lib.linear_search, "linear_search" },
    .{ lib.linear_std_search, "linear_std_search" },
    .{ lib.simd_search, "simd_search" },
};

const std = @import("std");
const lib = @import("search.zig");

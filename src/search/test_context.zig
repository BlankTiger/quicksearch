pub const FNType = *const fn (
    std.mem.Allocator,
    []const u8,
    []const u8,
) anyerror![]SearchResult;

pub const search_all_fns: [3]struct { FNType, []const u8 } = .{
    .{ all.linear_search, "linear_search" },
    .{ all.linear_std_search, "linear_std_search" },
    .{ all.simd_search, "simd_search" },
};

const SearchResult = @import("SearchResult.zig");
const std = @import("std");
const all = @import("search_all.zig");

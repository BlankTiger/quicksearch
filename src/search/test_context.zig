pub const FnType = *const fn (
    std.mem.Allocator,
    []const u8,
    []const u8,
) anyerror![]SearchResult;

pub const FnPair = struct { FnType, []const u8 };

pub const search_fns: []const FnPair = &[_]FnPair{
    .{ search.linear_search, "linear_search" },
    .{ search.simd_search, "simd_search" },
};

const SearchResult = @import("SearchResult.zig");
const std = @import("std");
const search = @import("search.zig");

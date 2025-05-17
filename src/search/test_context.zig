pub const FnType = *const fn (
    std.mem.Allocator,
    []const u8,
    []const u8,
) anyerror![]SearchResult;

pub const FnPair = struct { FnType, []const u8 };

pub const search_all_fns: []const FnPair = &[_]FnPair{
    .{ all.linear_search, "linear_search" },
    .{ all.simd_search, "simd_search" },
};

pub const search_first_fns: []const FnPair = &[_]FnPair{
    .{ first.linear_search, "linear_search" },
    .{ first.simd_search, "simd_search" },
};

const SearchResult = @import("SearchResult.zig");
const std = @import("std");
const all = @import("search_all.zig");
const first = @import("search_first.zig");

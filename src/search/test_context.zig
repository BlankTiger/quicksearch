pub const FnType = *const fn (*ResultHandler, []const u8, []const u8, []const u8) void;
pub const FnPair = struct { FnType, []const u8 };

pub const search_fns: []const FnPair = &[_]FnPair{
    .{ search.linear_search, "linear_search" },
    .{ search.simd_search, "simd_search" },
};

const ResultHandler = @import("ResultHandler.zig");
const SearchResult = @import("SearchResult.zig");
const std = @import("std");
const search = @import("search.zig");

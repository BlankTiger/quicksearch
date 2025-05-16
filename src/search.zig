pub const search = lib.search_simd;
pub const SearchResult = lib.SearchResult;

test {
    _ = lib;
}

pub const lib = @import("search/lib.zig");

pub const SearchResult = search.SearchResult;
pub const ResultHandler = search.ResultHandler;
pub const linear_search = search.linear_search;
pub const linear_std_search = search.linear_std_search;
pub const simd_search = search.simd_search;

test {
    // NOTE: DO NOT MENTION SEARCH HERE BECAUSE IT HAS ITS OWN
    // CUSTOM TEST RUNNER SETUP

    _ = MmapReader;
    _ = gitignore;
    _ = fs_search;
}

pub const search = @import("search.zig");
pub const MmapReader = @import("MmapReader.zig");
pub const gitignore = @import("gitignore.zig");
pub const fs_search = @import("fs_search.zig");

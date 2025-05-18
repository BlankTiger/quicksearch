test {
    _ = @import("std").testing.refAllDecls(@This());
}

pub const search = @import("search/search.zig");
pub const SearchResult = @import("search/SearchResult.zig");
pub const ResultHandler = @import("search/ResultHandler.zig");

test {
    _ = @import("std").testing.refAllDecls(@This());
}

pub const all = @import("search/search_all.zig");
pub const first = @import("search/search_first.zig");

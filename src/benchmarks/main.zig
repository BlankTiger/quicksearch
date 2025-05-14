pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();

    const results: []lib.SearchResult = try lib.search(alloc, "hihihi", "hi");
    defer alloc.free(results);
}

const lib = @import("qslib");
const std = @import("std");

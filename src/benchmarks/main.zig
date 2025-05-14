pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const alloc = gpa_state.allocator();

    const results: []lib.SearchResult = try lib.search(alloc, "hihihi", "hi");
    defer alloc.free(results);
}

const lib = @import("qslib");
const std = @import("std");

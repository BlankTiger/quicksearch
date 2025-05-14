pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const alloc = gpa_state.allocator();

    const linear_results = try lib.linear_search(alloc, "hihihi", "hi");
    defer alloc.free(linear_results);

    const linear_std_results = try lib.linear_std_search(alloc, "hihihi", "hi");
    defer alloc.free(linear_std_results);

    const simd_results = try lib.simd_search(alloc, "hihihi", "hi");
    defer alloc.free(simd_results);
}

const lib = @import("qslib");
const std = @import("std");

const SearchResult = struct {
    line: usize,
    col: usize,
};

fn search(alloc: mem.Allocator, haystack: []const u8, query: []const u8) ![]SearchResult {
    var results = std.ArrayList(SearchResult).init(alloc);
    errdefer results.deinit();

    var count_lines: usize = 1;
    var line_iter = mem.splitScalar(u8, haystack, '\n');
    while (line_iter.next()) |line| : (count_lines += 1) {
        var idx_last: usize = 0;
        while (mem.indexOfPos(u8, line, idx_last, query)) |col| {
            idx_last = col + 1;
            try results.append(.{ .line = count_lines, .col = col + 1 });
        }
    }

    return results.toOwnedSlice();
}

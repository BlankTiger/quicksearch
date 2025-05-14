pub const SearchResult = struct {
    line: usize,
    col: usize,
};

pub fn linear_search(alloc: mem.Allocator, haystack: []const u8, query: []const u8) anyerror![]SearchResult {
    var results = std.ArrayList(SearchResult).init(alloc);
    errdefer results.deinit();

    var count_lines: usize = 1;
    var line_iter = mem.splitScalar(u8, haystack, '\n');
    while (line_iter.next()) |line| : (count_lines += 1) {
        var col_last: usize = 0;
        while (mem.indexOfPos(u8, line, col_last, query)) |col| {
            col_last = col + 1;
            try results.append(.{ .line = count_lines, .col = col_last });
        }
    }

    return results.toOwnedSlice();
}

pub fn linear_std_search(alloc: mem.Allocator, haystack: []const u8, query: []const u8) anyerror![]SearchResult {
    var results = std.ArrayList(SearchResult).init(alloc);
    errdefer results.deinit();

    var count_lines: usize = 1;
    var line_iter = mem.splitScalar(u8, haystack, '\n');
    while (line_iter.next()) |line| : (count_lines += 1) {
        var col_last: usize = 0;
        while (mem.indexOfPos(u8, line, col_last, query)) |col| {
            col_last = col + 1;
            try results.append(.{ .line = count_lines, .col = col_last });
        }
    }

    return results.toOwnedSlice();
}

pub fn simd_search(alloc: mem.Allocator, haystack: []const u8, query: []const u8) anyerror![]SearchResult {
    var results = std.ArrayList(SearchResult).init(alloc);
    errdefer results.deinit();

    var count_lines: usize = 1;
    var line_iter = mem.splitScalar(u8, haystack, '\n');
    while (line_iter.next()) |line| : (count_lines += 1) {
        var col_last: usize = 0;
        while (mem.indexOfPos(u8, line, col_last, query)) |col| {
            col_last = col + 1;
            try results.append(.{ .line = count_lines, .col = col_last });
        }
    }

    return results.toOwnedSlice();
}


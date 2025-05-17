pub fn linear_search(
    alloc: mem.Allocator,
    haystack: []const u8,
    query: []const u8,
) anyerror![]SearchResult {
    if (query.len > haystack.len) return error.QueryLongerThanHaystack;

    var results = std.ArrayList(SearchResult).init(alloc);
    errdefer results.deinit();

    var count_lines: usize = 1;
    var line_iter = mem.splitScalar(u8, haystack, '\n');
    line_loop: while (line_iter.next()) |line| : (count_lines += 1) {
        for (line, 0..) |_, idx_l| {
            if (line[idx_l..].len < query.len) {
                continue :line_loop;
            }

            if (mem.eql(u8, line[idx_l .. idx_l + query.len], query)) {
                try results.append(.{ .line = count_lines, .col = idx_l + 1 });
                continue :line_loop;
            }
        }
    }

    return results.toOwnedSlice();
}

pub fn linear_std_search(
    alloc: mem.Allocator,
    haystack: []const u8,
    query: []const u8,
) anyerror![]SearchResult {
    if (query.len > haystack.len) return error.QueryLongerThanHaystack;

    var results = std.ArrayList(SearchResult).init(alloc);
    errdefer results.deinit();

    var count_lines: usize = 1;
    var line_iter = mem.splitScalar(u8, haystack, '\n');
    line_loop: while (line_iter.next()) |line| : (count_lines += 1) {
        var col_last: usize = 0;
        while (mem.indexOfPos(u8, line, col_last, query)) |col| {
            col_last = col + 1;
            try results.append(.{ .line = count_lines, .col = col_last });
            continue :line_loop;
        }
    }

    return results.toOwnedSlice();
}

pub fn simd_search(
    alloc: mem.Allocator,
    haystack: []const u8,
    query: []const u8,
) anyerror![]SearchResult {
    return linear_std_search(alloc, haystack, query);
}


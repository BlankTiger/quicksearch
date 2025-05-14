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

test {
    _ = Tests;
}

/// THESE TESTS ARE RUN USING A CUSTOM TEST RUNNER
const Tests = struct {
    const t_context = @import("test_context.zig");
    var search_fn: t_context.FNType = undefined;
    var name: []const u8 = undefined;
    var idx_curr_fn: usize = 0;

    // This runs once for every test fn
    test "SETUP SEARCH FN" {
        defer idx_curr_fn += 1;
        search_fn = t_context.search_fns[idx_curr_fn][0];
        name = t_context.search_fns[idx_curr_fn][1];
    }

    const input1 = "some bytes here";
    const query1 = "byte";

    test "search function doesnt return an error" {
        const results = try search_fn(t.allocator, input1, query1);
        defer t.allocator.free(results);
    }

    test "search function returns some search results" {
        const results = try search_fn(t.allocator, input1, query1);
        defer t.allocator.free(results);

        try t.expectEqual(1, results.len);
    }

    test "first result of search function is correct" {
        const results = try search_fn(t.allocator, input1, query1);
        defer t.allocator.free(results);

        try t.expectEqual(1, results[0].line);
        try t.expectEqual(6, results[0].col);
    }

    const input2 = "hi there hi re re";

    test "search function returns 2 matches" {
        const results = try search_fn(t.allocator, input2, "hi");
        defer t.allocator.free(results);

        try t.expectEqual(2, results.len);
    }

    test "search function returns 3 matches" {
        const results = try search_fn(t.allocator, input2, "re");
        defer t.allocator.free(results);

        try t.expectEqual(3, results.len);
    }

    test "search function only finds entire matches" {
        const results = try search_fn(t.allocator, "hi", "hihi");
        defer t.allocator.free(results);

        try t.expectEqual(0, results.len);
    }

    test "search function returns line info per match" {
        const results = try search_fn(t.allocator, "hi hello\nhi hello", "hi");
        defer t.allocator.free(results);

        try t.expectEqual(2, results.len);

        try t.expectEqual(1, results[0].line);
        try t.expectEqual(1, results[0].col);

        try t.expectEqual(2, results[1].line);
        try t.expectEqual(1, results[1].col);
    }

    test "search function returns line info correctly given multiple lines" {
        const results = try search_fn(t.allocator, "hi\n\nhi", "hi");
        defer t.allocator.free(results);

        try t.expectEqual(2, results.len);

        try t.expectEqual(1, results[0].line);
        try t.expectEqual(1, results[0].col);

        try t.expectEqual(3, results[1].line);
        try t.expectEqual(1, results[1].col);
    }

    test "search in empty line yields no results" {
        const results = try search_fn(t.allocator, "", "hi");
        defer t.allocator.free(results);

        try t.expectEqual(0, results.len);
    }
};

const std = @import("std");
const t = std.testing;
const mem = std.mem;

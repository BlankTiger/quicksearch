pub fn linear_search(
    alloc: mem.Allocator,
    haystack: []const u8,
    query: []const u8,
) anyerror![]SearchResult {
    if (query.len > haystack.len) return &[_]SearchResult{};
    if (query.len == 0) return &[_]SearchResult{};

    var results = try std.ArrayList(SearchResult).initCapacity(alloc, 2048);
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

// TODO: maybe I don't need to split on newlines, instead maybe just count them
// as we go, this would make using mem.splitScalar unnecessary, probably increase
// cache coherence too

pub fn simd_search(
    alloc: mem.Allocator,
    haystack: []const u8,
    query: []const u8,
) anyerror![]SearchResult {
    if (haystack.len > 10e6) {
        var results: ResultsStore = .{ .results = try .initCapacity(alloc, 2048) };
        errdefer results.results.deinit();
        const cpu_count = try std.Thread.getCpuCount();
        const threads: []std.Thread = try alloc.alloc(std.Thread, cpu_count);
        defer alloc.free(threads);
        const bytes_per_thread = haystack.len / cpu_count;
        var idx_start: usize = 0;
        for (0..cpu_count) |idx| {
            var idx_end = (idx + 1) * bytes_per_thread;
            if (idx == cpu_count - 1) {
                idx_end = haystack.len - 1;
            } else {
                // make sure we always have chunks with full lines
                while (haystack[idx_end] != '\n') idx_end += 1;
            }
            idx_start = idx_end;

            threads[idx] = try std.Thread.spawn(
                .{ .allocator = alloc },
                simd_search_impl_threaded,
                .{ &results, haystack[idx_start..idx_end], query },
            );
        }
        for (threads) |thread| thread.join();
        return try results.results.toOwnedSlice();
    } else {
        return simd_search_impl(alloc, haystack, query);
    }
}

const ResultsStore = struct {
    mutex: std.Thread.Mutex = .{},
    results: std.ArrayList(SearchResult),

    fn append(self: *@This(), result: SearchResult) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.results.append(result);
    }
};

fn simd_search_impl_threaded(
    results: *ResultsStore,
    haystack: []const u8,
    query: []const u8,
) void {
    if (query.len > haystack.len) return;
    if (query.len == 0) return;

    const MAX_U8 = std.math.maxInt(u8);
    const vector_len = simd.suggestVectorLength(u8) orelse 16;
    const T = @Vector(vector_len, u8);

    const q_start: T = @splat(query[0]);
    const max_vals: T = @splat(MAX_U8);
    const indexes = simd.iota(u8, vector_len);

    var current_line: usize = 1;
    var line_iter = mem.splitScalar(u8, haystack, '\n');

    while (line_iter.next()) |line| : (current_line += 1) {
        if (line.len < query.len) continue;

        var line_pos: usize = 0;

        while (line_pos + vector_len <= line.len) {
            const part: T = line[line_pos .. line_pos + vector_len][0..vector_len].*;
            const matches_start = part == q_start;

            if (@reduce(.Or, matches_start)) {
                const selected_indexes = @select(u8, matches_start, indexes, max_vals);

                for (0..vector_len) |idx| {
                    if (selected_indexes[idx] == MAX_U8) continue; // No match at this position

                    // Check if there's enough room for the full query from the current idx to the end
                    const match_pos = line_pos + idx;
                    if (match_pos + query.len > line.len) continue;

                    // Verify the last character matches to filter out obvious non-matches
                    if (match_pos + query.len - 1 < line.len and
                        line[match_pos + query.len - 1] != query[query.len - 1])
                        continue;

                    if (mem.eql(u8, line[match_pos .. match_pos + query.len], query)) {
                        results.append(SearchResult{
                            .line = current_line,
                            .col = match_pos + 1,
                        }) catch return;
                    }
                }
            }

            line_pos += vector_len;
        }

        // Handle the remaining characters that don't fill a complete vector
        const remaining = line.len - line_pos;
        if (remaining >= query.len) {
            var pos = line_pos;
            while (pos <= line.len - query.len) : (pos += 1) {
                if (mem.eql(u8, line[pos .. pos + query.len], query)) {
                    results.append(SearchResult{
                        .line = current_line,
                        .col = pos + 1,
                    }) catch return;
                }
            }
        }
    }
}

fn simd_search_impl(
    alloc: mem.Allocator,
    haystack: []const u8,
    query: []const u8,
) anyerror![]SearchResult {
    if (query.len > haystack.len) return &[_]SearchResult{};
    if (query.len == 0) return &[_]SearchResult{};

    var results = try std.ArrayList(SearchResult).initCapacity(alloc, 2048);
    errdefer results.deinit();

    const MAX_U8 = std.math.maxInt(u8);
    const vector_len = simd.suggestVectorLength(u8) orelse 16;
    const T = @Vector(vector_len, u8);

    const q_start: T = @splat(query[0]);
    const max_vals: T = @splat(MAX_U8);
    const indexes = simd.iota(u8, vector_len);

    var current_line: usize = 1;
    var line_iter = mem.splitScalar(u8, haystack, '\n');

    while (line_iter.next()) |line| : (current_line += 1) {
        if (line.len < query.len) continue;

        var line_pos: usize = 0;

        while (line_pos + vector_len <= line.len) {
            const part: T = line[line_pos .. line_pos + vector_len][0..vector_len].*;
            const matches_start = part == q_start;

            if (@reduce(.Or, matches_start)) {
                const selected_indexes = @select(u8, matches_start, indexes, max_vals);

                for (0..vector_len) |idx| {
                    if (selected_indexes[idx] == MAX_U8) continue; // No match at this position

                    // Check if there's enough room for the full query from the current idx to the end
                    const match_pos = line_pos + idx;
                    if (match_pos + query.len > line.len) continue;

                    // Verify the last character matches to filter out obvious non-matches
                    if (match_pos + query.len - 1 < line.len and
                        line[match_pos + query.len - 1] != query[query.len - 1])
                        continue;

                    if (mem.eql(u8, line[match_pos .. match_pos + query.len], query)) {
                        try results.append(SearchResult{
                            .line = current_line,
                            .col = match_pos + 1,
                        });
                    }
                }
            }

            line_pos += vector_len;
        }

        // Handle the remaining characters that don't fill a complete vector
        const remaining = line.len - line_pos;
        if (remaining >= query.len) {
            var pos = line_pos;
            while (pos <= line.len - query.len) : (pos += 1) {
                if (mem.eql(u8, line[pos .. pos + query.len], query)) {
                    try results.append(SearchResult{
                        .line = current_line,
                        .col = pos + 1,
                    });
                }
            }
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
    var search_fn: t_context.FnType = undefined;
    var name: []const u8 = undefined;
    var idx_curr_fn: usize = 0;

    // This runs once for every test fn
    test "SETUP SEARCH FN" {
        defer idx_curr_fn += 1;
        search_fn = t_context.search_fns[idx_curr_fn][0];
        name = t_context.search_fns[idx_curr_fn][1];
    }

    test "search function returns empty results when query longer than haystack" {
        const results = try search_fn(t.allocator, "hi", "hih");
        defer t.allocator.free(results);

        try t.expectEqual(0, results.len);
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

    test "search function handles long queries well" {
        const results = try search_fn(
            t.allocator,
            "some some some thisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeah",
            "thisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeah",
        );
        defer t.allocator.free(results);

        try t.expectEqual(3, results.len);
        try t.expectEqual(1, results[0].line);
        try t.expectEqual(16, results[0].col);
        try t.expectEqual(1, results[1].line);
        try t.expectEqual(86, results[1].col);
        try t.expectEqual(1, results[2].line);
        try t.expectEqual(156, results[2].col);
    }
};

const SearchResult = @import("SearchResult.zig");
const std = @import("std");
const t = std.testing;
const mem = std.mem;
const simd = std.simd;

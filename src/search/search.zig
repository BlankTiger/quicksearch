pub fn linear_search(
    result_handler: *ResultHandler,
    haystack: []const u8,
    query: []const u8,
) void {
    if (query.len > haystack.len) return;
    if (query.len == 0) return;

    var count_lines: usize = 1;
    var line_iter = mem.splitScalar(u8, haystack, '\n');
    while (line_iter.next()) |line| : (count_lines += 1) {
        var col_last: usize = 0;
        while (mem.indexOfPos(u8, line, col_last, query)) |col| {
            col_last = col + 1;
            result_handler.handle(.{ .row = count_lines, .col = col_last, .line = line });
        }
    }
}

// TODO: maybe I don't need to split on newlines, instead maybe just count them
// as we go, this would make using mem.splitScalar unnecessary, probably increase
// cache coherence too

const SIMD_THRESHOLD = 10e6;
const MAX_THREADS = 32;
const MAX_U8 = std.math.maxInt(u8);

pub fn simd_search(
    result_handler: *ResultHandler,
    haystack: []const u8,
    query: []const u8,
) void {
    if (haystack.len > SIMD_THRESHOLD) {
        const cpu_count = std.Thread.getCpuCount() catch 16;
        var threads: [MAX_THREADS]std.Thread = undefined;
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

            threads[idx] = std.Thread.spawn(
                .{},
                simd_search_impl,
                .{ result_handler, haystack[idx_start..idx_end], query },
            ) catch return;
        }
        for (0..cpu_count) |idx_cpu| threads[idx_cpu].join();
    } else {
        simd_search_impl(result_handler, haystack, query);
    }
}

fn simd_search_impl(
    result_handler: *ResultHandler,
    haystack: []const u8,
    query: []const u8,
) void {
    if (query.len > haystack.len) return;
    if (query.len == 0) return;

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
                        result_handler.handle(SearchResult{
                            .row = current_line,
                            .col = match_pos + 1,
                            .line = line,
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
                    result_handler.handle(SearchResult{
                        .row = current_line,
                        .col = pos + 1,
                        .line = line,
                    });
                }
            }
        }
    }
}

test {
    _ = Tests;
}

/// THESE TESTS ARE RUN USING A CUSTOM TEST RUNNER
const Tests = struct {
    const WriterWrapper = struct {
        var data = [_]u8{0} ** 10e3;
        var len: usize = 0;
        var write_count: usize = 0;

        const Self = @This();

        fn reset(_: Self) void {
            len = 0;
            write_count = 0;
        }

        fn write(_: *const anyopaque, bytes: []const u8) anyerror!usize {
            write_count += 1;
            @memcpy(data[len .. len + bytes.len], bytes);
            return bytes.len;
        }

        fn writer(self: *Self) std.io.AnyWriter {
            return .{ .context = self, .writeFn = write };
        }

        fn get(_: Self) []const u8 {
            return data[0..len];
        }
    };

    const t_context = @import("test_context.zig");
    var test_writer: WriterWrapper = undefined;
    var test_handler: ResultHandler = undefined;
    var search_fn: t_context.FnType = undefined;
    var name: []const u8 = undefined;
    var idx_curr_fn: usize = 0;

    // This runs once for every test fn
    test "SETUP SEARCH FN" {
        defer idx_curr_fn += 1;
        test_handler = .init(test_writer.writer(), .{});
        search_fn = t_context.search_fns[idx_curr_fn][0];
        name = t_context.search_fns[idx_curr_fn][1];
    }

    // test "SETUP BEFORE EACH SEARCH FN"

    test "TEARDOWN SEARCH FN" {}

    test "search: search function returns empty results when query longer than haystack" {
        defer test_writer.reset();
        search_fn(&test_handler, "hi", "hih");

        try t.expectEqual(0, WriterWrapper.write_count);
    }

    const input1 = "some bytes here";
    const query1 = "byte";

    test "search: search function returns some search results" {
        defer test_writer.reset();
        search_fn(&test_handler, input1, query1);

        try t.expectEqual(1, WriterWrapper.write_count);
    }
    //
    // test "search: first result of search function is correct" {
    //     defer test_writer.reset();
    //     search_fn(&test_handler, input1, query1);
    //
    //     try t.expectEqualStrings("1:6: some bytes here\n", test_writer.get());
    // }
    //
    // const input2 = "hi there hi re re";
    //
    // test "search: search function returns 2 matches" {
    //     defer test_writer.reset();
    //     search_fn(&test_handler, input2, "hi");
    //
    //     try t.expectEqual(2, WriterWrapper.write_count);
    // }
    //
    // test "search: search function returns 3 matches" {
    //     defer test_writer.reset();
    //     search_fn(&test_handler, input2, "re");
    //
    //     try t.expectEqual(3, WriterWrapper.write_count);
    // }
    //
    // test "search: search function returns line info per match" {
    //     defer test_writer.reset();
    //     search_fn(&test_handler, "hi hello\nhi hello", "hi");
    //
    //     try t.expectEqual(2, WriterWrapper.write_count);
    //     try t.expectEqualStrings(
    //         \\1:1: hi hello
    //         \\2:1: hi hello
    //         \\
    //     , test_writer.get());
    // }
    //
    // test "search: search function returns line info correctly given multiple lines" {
    //     defer test_writer.reset();
    //     search_fn(&test_handler, "hi\n\nhi", "hi");
    //
    //     try t.expectEqual(2, WriterWrapper.write_count);
    //     try t.expectEqualStrings(
    //         \\1:1: hi
    //         \\3:1: hi
    //         \\
    //     , test_writer.get());
    // }
    //
    // test "search: search function handles long queries well" {
    //     defer test_writer.reset();
    //     search_fn(
    //         &test_handler,
    //         "some some some thisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeah",
    //         "thisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeah",
    //     );
    //
    //     try t.expectEqual(3, WriterWrapper.write_count);
    //     try t.expectEqualStrings(
    //         \\1:16: some some some thisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeah
    //         \\1:86: some some some thisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeah
    //         \\1:156: some some some thisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeah
    //         \\
    //     , test_writer.get());
    // }

    // TODO: make some nice test that tests handling of passing the .line in the results
};

const ResultHandler = @import("ResultHandler.zig");
const SearchResult = @import("SearchResult.zig");
const std = @import("std");
const t = std.testing;
const mem = std.mem;
const simd = std.simd;

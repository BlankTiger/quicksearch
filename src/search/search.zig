const THREADED_THRESHOLD = 10e6;
const DEFAULT_THREADS = 16;
const MAX_THREADS = 32;
const MAX_U8 = std.math.maxInt(u8);
const LOCAL_CAPACITY = 8192;

pub fn linear_search(
    result_handler: *ResultHandler,
    haystack: []const u8,
    query: []const u8,
) void {
    if (haystack.len > THREADED_THRESHOLD) {
        const cpu_count = @min(MAX_THREADS, std.Thread.getCpuCount() catch DEFAULT_THREADS);
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
            defer idx_start = idx_end;

            threads[idx] = std.Thread.spawn(
                .{},
                linear_search_impl,
                .{ result_handler, haystack[idx_start..idx_end], query },
            ) catch |e| {
                std.debug.print("got an error while trying to spawn a thread: {}\n", .{e});
                return;
            };
        }
        for (0..cpu_count) |idx_cpu| threads[idx_cpu].join();
    } else {
        linear_search_impl(result_handler, haystack, query);
    }
}

pub fn linear_search_impl(
    result_handler: *ResultHandler,
    haystack: []const u8,
    query: []const u8,
) void {
    if (query.len > haystack.len) return;
    if (query.len == 0) return;

    var local = std.ArrayList(u8).initCapacity(std.heap.page_allocator, LOCAL_CAPACITY) catch {
        std.debug.print("encountered an error while trying to allocate a local buffer\n", .{});
        return;
    };
    defer local.deinit();
    const writer = local.writer().any();

    var count_lines: usize = 1;
    var line_iter = mem.splitScalar(u8, haystack, '\n');
    line_loop: while (line_iter.next()) |line| : (count_lines += 1) {
        var col_last: usize = 0;
        while (mem.indexOfPos(u8, line, col_last, query)) |col| {
            col_last = col + 1;
            handle_result(result_handler, &local, writer, .{
                .row = count_lines,
                .col = col_last,
                .line = line,
            }) catch return;

            continue :line_loop;
        }
    }

    write_remaining(result_handler, &local);
}

// TODO: maybe I don't need to split on newlines, instead maybe just count them
// as we go, this would make using mem.splitScalar unnecessary, probably increase
// cache coherence too

pub fn simd_search(
    result_handler: *ResultHandler,
    haystack: []const u8,
    query: []const u8,
) void {
    if (haystack.len > THREADED_THRESHOLD) {
        const cpu_count = @min(MAX_THREADS, std.Thread.getCpuCount() catch DEFAULT_THREADS);
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
            defer idx_start = idx_end;

            threads[idx] = std.Thread.spawn(
                .{},
                simd_search_impl,
                .{ result_handler, haystack[idx_start..idx_end], query },
            ) catch |e| {
                std.debug.print("got an error while trying to spawn a thread: {}\n", .{e});
                return;
            };
        }
        for (0..cpu_count) |idx_cpu| threads[idx_cpu].join();
    } else {
        simd_search_impl(result_handler, haystack, query);
    }
}

const vector_len = simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vector_len, u8);

const max_vals: Vec = @splat(MAX_U8);
const indexes = simd.iota(u8, vector_len);

fn simd_search_impl(
    result_handler: *ResultHandler,
    haystack: []const u8,
    query: []const u8,
) void {
    if (query.len > haystack.len) return;
    if (query.len == 0) return;

    const allocator = std.heap.page_allocator;
    var local = std.ArrayList(u8).initCapacity(allocator, LOCAL_CAPACITY) catch |e| {
        std.debug.print("couldnt create a local buffer for SearchResults: {}\n", .{e});
        return;
    };
    defer local.deinit();
    const writer = local.writer().any();

    const q_start: Vec = @splat(query[0]);

    var current_line: usize = 1;
    var line_iter = mem.splitScalar(u8, haystack, '\n');
    // var line_iter = LineSplitter.init(haystack);

    line_loop: while (line_iter.next()) |line| : (current_line += 1) {
        if (line.len < query.len) continue;

        var line_pos: usize = 0;

        while (line_pos + vector_len <= line.len) {
            const part: Vec = line[line_pos .. line_pos + vector_len][0..vector_len].*;
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
                        handle_result(result_handler, &local, writer, .{
                            .row = current_line,
                            .col = match_pos + 1,
                            .line = line,
                        }) catch return;

                        continue :line_loop;
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
                    handle_result(result_handler, &local, writer, .{
                        .row = current_line,
                        .col = pos + 1,
                        .line = line,
                    }) catch return;

                    continue :line_loop;
                }
            }
        }
    }

    write_remaining(result_handler, &local);
}

inline fn handle_result(handler: *ResultHandler, local: *std.ArrayList(u8), writer: std.io.AnyWriter, result: SearchResult) !void {
    handler.format(writer, result) catch |e| {
        std.debug.print("OOM while trying to append to local buffer\n", .{});
        return e;
    };

    if (local.items.len > local.capacity * 9 / 10) {
        handler.write(local.items) catch |e| {
            std.debug.print("encountered an error while trying to write accumulated local results to an output writer\n", .{});
            return e;
        };
        local.clearRetainingCapacity();
    }
}

inline fn write_remaining(handler: *ResultHandler, local: *std.ArrayList(u8)) void {
    if (local.items.len > 0) {
        handler.write(local.items) catch {
            std.debug.print("encountered an error while trying to write accumulated local results to an output writer\n", .{});
            return;
        };
        local.clearRetainingCapacity();
    }
}

const LineSplitter = struct {
    idx: usize = 0,
    haystack: []const u8,

    const newlines: Vec = @splat('\n');

    fn init(txt: []const u8) LineSplitter {
        return .{ .haystack = txt };
    }

    fn next(self: *LineSplitter) ?[]const u8 {
        if (self.idx >= self.haystack.len) return null;

        var idx_new: usize = self.idx;
        var maybe_idx_first: ?simd.VectorIndex(Vec) = null;

        while (idx_new + vector_len < self.haystack.len) : (idx_new += vector_len) {
            const part: Vec = self.haystack[idx_new .. idx_new + vector_len][0..vector_len].*;
            const mask_newlines = part == newlines;
            maybe_idx_first = simd.firstTrue(mask_newlines);
            if (maybe_idx_first) |idx_first| {
                const idx_old = self.idx;
                idx_new += idx_first;
                self.idx = idx_new + 1;
                return self.haystack[idx_old..idx_new];
            }
        }

        for (self.haystack[idx_new..], 0..) |c, idx_offset| {
            if (c == '\n') {
                const idx_old = self.idx;
                idx_new += idx_offset;
                self.idx = idx_new + 1;
                return self.haystack[idx_old..idx_new];
            }
        }

        const idx_old = self.idx;
        self.idx = self.haystack.len;
        return self.haystack[idx_old..];
    }
};

test {
    _ = Tests;
}

/// THESE TESTS ARE RUN USING A CUSTOM TEST RUNNER
const Tests = struct {
    const WriterWrapper = struct {
        var data = [_]u8{0} ** 10e3;
        var len: usize = 0;
        var format_count: usize = 0;

        const Self = @This();

        fn reset(_: Self) void {
            len = 0;
            format_count = 0;
        }

        fn write(_: *const anyopaque, bytes: []const u8) anyerror!usize {
            @memcpy(data[len .. len + bytes.len], bytes);
            len = len + bytes.len;
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
        const writer = test_writer.writer();
        test_handler = .init(writer, .{
            .handling_type = .testing,
            .testing_format_count = &WriterWrapper.format_count,
        });
        search_fn = t_context.search_fns[idx_curr_fn][0];
        name = t_context.search_fns[idx_curr_fn][1];
    }

    // test "SETUP BEFORE EACH SEARCH FN"

    test "TEARDOWN SEARCH FN" {}

    test "search: search function returns empty results when query longer than haystack" {
        defer test_writer.reset();
        search_fn(&test_handler, "hi", "hih");

        try t.expectEqual(0, WriterWrapper.format_count);
    }

    const input1 = "some bytes here";
    const query1 = "byte";

    test "search: search function returns some search results" {
        defer test_writer.reset();
        search_fn(&test_handler, input1, query1);
        try t.expectEqual(1, WriterWrapper.format_count);
    }

    test "search: first result of search function is correct" {
        defer test_writer.reset();
        search_fn(&test_handler, input1, query1);

        try t.expectEqualStrings("1:6: some bytes here\n", test_writer.get());
    }

    const input2 = "hi there hi re re";

    test "search: search function returns 1 match per line" {
        defer test_writer.reset();
        search_fn(&test_handler, input2, "hi");

        try t.expectEqual(1, WriterWrapper.format_count);
    }

    test "search: search function returns 1 match per line still" {
        defer test_writer.reset();
        search_fn(&test_handler, input2, "re");

        try t.expectEqual(1, WriterWrapper.format_count);
    }

    test "search: search function returns line info per match" {
        defer test_writer.reset();
        search_fn(&test_handler, "hi hello\nhi hello", "hi");

        try t.expectEqual(2, WriterWrapper.format_count);
        try t.expectEqualStrings(
            \\1:1: hi hello
            \\2:1: hi hello
            \\
        , test_writer.get());
    }

    test "search: search function returns line info correctly given multiple lines" {
        defer test_writer.reset();
        search_fn(&test_handler, "hi\n\nhi", "hi");

        try t.expectEqual(2, WriterWrapper.format_count);
        try t.expectEqualStrings(
            \\1:1: hi
            \\3:1: hi
            \\
        , test_writer.get());
    }

    test "search: search function handles long queries well" {
        defer test_writer.reset();
        search_fn(
            &test_handler,
            "some some some thisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeah",
            "thisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeah",
        );

        try t.expectEqual(1, WriterWrapper.format_count);
        try t.expectEqualStrings(
            \\1:16: some some some thisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeahthisisaverylongquerythatwillspanmorethanthesimdlimitlimitlimithellyeah
            \\
        , test_writer.get());
    }

    // TODO: make some nice test that tests handling of passing the .line in the results
};

const ResultHandler = @import("ResultHandler.zig");
const SearchResult = @import("SearchResult.zig");
const std = @import("std");
const t = std.testing;
const mem = std.mem;
const simd = std.simd;

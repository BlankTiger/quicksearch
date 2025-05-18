pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer std.debug.assert(arena_state.reset(.free_all));

    const alloc = arena_state.allocator();

    const search_tests, const normal_tests = t: {
        var list_search = std.ArrayList(std.builtin.TestFn).init(alloc);
        var list_normal = std.ArrayList(std.builtin.TestFn).init(alloc);
        for (builtin.test_functions) |tf| {
            if (std.mem.containsAtLeast(u8, tf.name, 1, "normal: ")) {
                try list_normal.append(tf);
            } else if (std.mem.containsAtLeast(u8, tf.name, 1, "search: ")) {
                try list_search.append(tf);
            } else if (std.mem.containsAtLeast(u8, tf.name, 1, SEARCH_SETUP)) {
                try list_search.append(tf);
            }
        }

        break :t .{ try list_search.toOwnedSlice(), try list_normal.toOwnedSlice() };
    };

    std.debug.print("Running tests for search_fns using a custom runner\n", .{});
    try handle_search_tests(search_tests, t_context.search_fns);

    std.debug.print("Running normal tests\n", .{});
    try handle_normal_tests(normal_tests);
}

const SEARCH_SETUP = "SETUP SEARCH FN";

fn is_setup(name: []const u8) bool {
    return std.mem.eql(u8, name, SEARCH_SETUP);
}

fn handle_search_tests(tests: []const std.builtin.TestFn, fns: []const t_context.FnPair) !void {
    var tests_passed: usize = 0;
    var tests_failed: usize = 0;
    for (fns) |sfn| {
        const name = sfn[1];

        for (tests) |t| {
            if (is_setup(t.name)) {
                try t.func();
            }
        }

        std.debug.print("Running tests for fn '{s}'\n", .{name});

        for (tests) |t| {
            if (is_setup(t.name)) continue;

            t.func() catch |err| {
                if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
                std.debug.print(
                    "Test for fn '{s}': '{s}' failed with an error: {}\n",
                    .{ name, t.name, err },
                );
                tests_failed += 1;
                continue;
            };
            tests_passed += 1;
        }
    }

    std.debug.print(
        "Ran {d} tests. Passed: {d}, failed: {d}\n\n",
        .{
            tests.len * fns.len,
            tests_passed,
            tests_failed,
        },
    );
}

fn handle_normal_tests(tests: []const std.builtin.TestFn) !void {
    var tests_passed: usize = 0;
    var tests_failed: usize = 0;

    for (tests) |t| {
        t.func() catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
            std.debug.print(
                "Test '{s}' failed with an error: {}\n",
                .{ t.name, err },
            );
            tests_failed += 1;
            continue;
        };
        tests_passed += 1;
    }

    std.debug.print(
        "Ran {d} tests. Passed: {d}, failed: {d}\n\n",
        .{ tests.len, tests_passed, tests_failed },
    );
}

const std = @import("std");
const builtin = @import("builtin");
const t_context = @import("test_context.zig");

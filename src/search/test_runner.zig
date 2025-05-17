pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer std.debug.assert(arena_state.reset(.free_all));

    const alloc = arena_state.allocator();

    const search_all_tests, const search_first_tests = t: {
        var list_all = std.ArrayList(std.builtin.TestFn).init(alloc);
        var list_first = std.ArrayList(std.builtin.TestFn).init(alloc);
        for (builtin.test_functions) |tf| {
            if (std.mem.containsAtLeast(u8, tf.name, 1, "search_all")) {
                try list_all.append(tf);
            }
            if (std.mem.containsAtLeast(u8, tf.name, 1, "search_first")) {
                try list_first.append(tf);
            }
        }

        break :t .{try list_all.toOwnedSlice(), try list_first.toOwnedSlice()};
    };

    try handle_search_all(search_all_tests);
    try handle_search_first(search_first_tests);
}

fn handle_search_all(tests: []const std.builtin.TestFn) !void {
    std.debug.print("Running tests for search_all_fns using a custom runner\n", .{});

    var tests_passed: usize = 0;
    var tests_failed: usize = 0;
    for (t_context.search_all_fns) |sfn| {
        const name = sfn[1];

        for (tests) |t| {
            if (is_setup(t.name)) {
                try t.func();
            }
        }

        std.debug.print("Running tests for search_all fn '{s}'\n", .{name});

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
            tests.len * t_context.search_all_fns.len,
            tests_passed,
            tests_failed,
        },
    );
}

fn handle_search_first(tests: []const std.builtin.TestFn) !void {
    std.debug.print("Running tests for search_first_fns using a custom runner\n", .{});

    var tests_passed: usize = 0;
    var tests_failed: usize = 0;

    for (tests) |t| {
        if (is_setup(t.name)) continue;

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
        .{
            tests.len,
            tests_passed,
            tests_failed,
        },
    );
}

fn is_setup(name: []const u8) bool {
    return std.mem.eql(u8, name, "SETUP SEARCH FN");
}

const std = @import("std");
const builtin = @import("builtin");
const t_context = @import("test_context.zig");

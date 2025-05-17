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

        break :t .{ try list_all.toOwnedSlice(), try list_first.toOwnedSlice() };
    };

    std.debug.print("Running tests for search_all_fns using a custom runner\n", .{});
    try handle_tests(search_all_tests, t_context.search_all_fns);
    std.debug.print("Running tests for search_all_fns using a custom runner\n", .{});
    try handle_tests(search_first_tests, t_context.search_first_fns);
}

fn handle_tests(tests: []const std.builtin.TestFn, fns: []const t_context.FnPair) !void {
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

fn is_setup(name: []const u8) bool {
    return std.mem.eql(u8, name, "SETUP SEARCH FN");
}

const std = @import("std");
const builtin = @import("builtin");
const t_context = @import("test_context.zig");

pub fn main() !void {
    std.debug.print("Running tests for search fns using a custom runner\n", .{});

    var tests_passed: usize = 0;
    var tests_failed: usize = 0;
    for (t_context.search_fns) |sfn| {
        const name = sfn[1];

        for (builtin.test_functions) |t| {
            if (is_setup(t.name)) {
                try t.func();
            }
        }

        std.debug.print("Running tests for search fn '{s}'\n", .{name});

        for (builtin.test_functions) |t| {
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
            builtin.test_functions.len * t_context.search_fns.len,
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

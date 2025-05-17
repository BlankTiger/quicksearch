pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const alloc = gpa_state.allocator();

    const _args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, _args);

    const args = _args[1..];
    const path_to_data = args[0];
    const query = args[1];
    const method_txt = args[2];
    const method = get_method(method_txt);

    const data = try get_data(alloc, path_to_data);
    defer alloc.free(data);

    switch (method) {
        .all_linear => {
            const linear_results = try all.linear_search(alloc, data, query);
            defer alloc.free(linear_results);
        },

        .all_linear_std => {
            const linear_std_results = try all.linear_std_search(alloc, data, query);
            defer alloc.free(linear_std_results);
        },

        .all_simd => {
            const simd_results = try all.simd_search(alloc, data, query);
            defer alloc.free(simd_results);
        },

        .first_linear => {
            const linear_results = try first.linear_search(alloc, data, query);
            defer alloc.free(linear_results);
        },

        .first_linear_std => {
            const linear_std_results = try first.linear_std_search(alloc, data, query);
            defer alloc.free(linear_std_results);
        },

        .first_simd => {
            const simd_results = try first.simd_search(alloc, data, query);
            defer alloc.free(simd_results);
        },
    }
}

const Method = enum {
    all_linear,
    all_linear_std,
    all_simd,

    first_linear,
    first_linear_std,
    first_simd,
};

fn get_method(txt: []const u8) Method {
    const eql = std.mem.eql;

    const m_fields = @typeInfo(Method).@"enum".fields;
    inline for (m_fields) |f| {
        if (eql(u8, f.name, txt)) {
            return @enumFromInt(f.value);
        }
    }

    std.debug.panic(
        "You didn't provide a valid function for testing, exiting\nProvided: '{s}'\nAvailable: {s}\n",
        .{
            txt,
            fs: {
                comptime var fs: [m_fields.len][]const u8 = undefined;
                inline for (0..m_fields.len) |idx| fs[idx] = m_fields[idx].name;
                break :fs fs;
            }
        }
    );
}

fn get_data(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return try file.readToEndAlloc(alloc, 500e12);
}

const all = @import("qslib").search.all;
const first = @import("qslib").search.first;
const std = @import("std");

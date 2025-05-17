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

    const data = try get_data(path_to_data);
    defer std.posix.munmap(data);

    var results: []const SearchResult = undefined;
    defer alloc.free(results);

    switch (method) {
        .all_linear => {
            results = try all.linear_search(alloc, data, query);
        },

        .all_simd => {
            results = try all.simd_search(alloc, data, query);
        },

        .first_linear => {
            results = try first.linear_search(alloc, data, query);
        },

        .first_simd => {
            results = try first.simd_search(alloc, data, query);
        },
    }

    log.info("Found: {d}", .{results.len});
}

const Method = enum {
    all_linear,
    all_simd,

    first_linear,
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

fn get_data(path: []const u8) ![]align(std.heap.page_size_min) const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stats = try std.posix.fstat(file.handle);
    const mem = try std.posix.mmap(null, @intCast(stats.size), std.posix.PROT.READ, .{ .TYPE = .SHARED }, file.handle, 0);

    return mem;
}

const all = @import("qslib").search.all;
const first = @import("qslib").search.first;
const SearchResult = @import("qslib").SearchResult;
const log = std.log;
const std = @import("std");

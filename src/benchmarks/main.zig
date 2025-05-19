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

    const reader: MmapReader = try .init(path_to_data);
    defer reader.deinit();

    const writer = std.io.getStdErr().writer().any();
    var handler: ResultHandler = .init(writer, .{});

    switch (method) {
        .linear => {
            search.linear_search(&handler, reader.data, query);
        },

        .simd => {
            search.simd_search(&handler, reader.data, query);
        },
    }
}

const Method = enum {
    linear,
    simd,
};

fn get_method(txt: []const u8) Method {
    const eql = std.mem.eql;

    const m_fields = @typeInfo(Method).@"enum".fields;
    inline for (m_fields) |f| {
        if (eql(u8, f.name, txt)) {
            return @enumFromInt(f.value);
        }
    }

    std.debug.panic("You didn't provide a valid function for testing, exiting\nProvided: '{s}'\nAvailable: {s}\n", .{ txt, fs: {
        comptime var fs: [m_fields.len][]const u8 = undefined;
        inline for (0..m_fields.len) |idx| fs[idx] = m_fields[idx].name;
        break :fs fs;
    } });
}

const search = @import("qslib").search.search;
const MmapReader = @import("qslib").MmapReader;
const SearchResult = @import("qslib").SearchResult;
const ResultHandler = @import("qslib").ResultHandler;
const log = std.log;
const std = @import("std");

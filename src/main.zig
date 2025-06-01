pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const queue: Queue = .init(allocator);
    var opts: finder.Options = .{
        .path = "./src",
        .allocator = allocator,
        .gitignorer = .init(&arena_state),
        .collector = queue,
    };
    const collector = try finder.find_files(&opts);
    for (collector.items()) |f| std.debug.print("found: {s}\n", .{f});
    std.debug.print("T: {s}\n", .{@typeName(@TypeOf(collector))});

fn parse_args(args: []const []const u8) struct { path: []const u8, file_type: []const u8, needle: []const u8 } {
    if (args.len < 2) @panic("must provide at least a search query");

    const count_additional_args = args.len - 2;
    // TODO: make this parser good
    if (count_additional_args % 2 != 0) @panic("additional arguments must be provided in pairs");

    var path: []const u8 = "";
    var file_type: []const u8 = "";
    var err_buf: [20]u8 = undefined;
    if (count_additional_args > 0) {
        for (1..count_additional_args + 1) |idx_arg| {
            if (idx_arg % 2 == 0) continue;

            const arg = args[idx_arg];
            std.debug.assert(arg[0] == '-');
            switch (arg[1]) {
                't' => {
                    file_type = args[idx_arg + 1];
                },

                'g' => {
                    path = args[idx_arg + 1];
                },

                else => @panic(std.fmt.bufPrint(&err_buf, "no flag: {c}", .{arg[1]}) catch "deez"),
            }
        }
    }
    // last argument is always the query
    const needle = args[args.len - 1];

    return .{
        .path = path,
        .file_type = file_type,
        .needle = needle,
    };
}

}

const std = @import("std");
const lib = @import("qslib");
const fss = lib.fs_search;
const Queue = fss.Queue([]const u8);
// const Queue = fss.PathList;
const finder = fss.Finder(Queue);

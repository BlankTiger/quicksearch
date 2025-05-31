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
}

const std = @import("std");
const lib = @import("qslib");
const fss = lib.fs_search;
const Queue = fss.Queue([]const u8);
// const Queue = fss.PathList;
const finder = fss.Finder(Queue);

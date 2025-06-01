pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    const cli_opts = parse_args(args);

    var opts: finder.Options = .{
        .path = cli_opts.path,
        .extension = cli_opts.file_type,
        .allocator = allocator,
        .gitignorer = .init(&arena_state),
        .collector = Queue.init(allocator),
    };
    const finder_thread = try run_finder(&opts);
    defer finder_thread.join();
    try run_search(cli_opts.needle, &opts);
    // for (collector.items()) |f| std.debug.print("found: {s}\n", .{f});
    // std.debug.print("T: {s}\n", .{@typeName(@TypeOf(collector))});
}

fn parse_args(args: []const []const u8) struct {
    path: []const u8,
    file_type: []const u8,
    needle: []const u8,
} {
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

fn run_finder(opts: *finder.Options) !std.Thread {
    return try .spawn(.{}, finder.find_files, .{opts});
}

const MAX_THREAD_COUNT = 32;

fn run_search(needle: []const u8, opts: *finder.Options) !void {
    const count_threads = @min(try std.Thread.getCpuCount(), MAX_THREAD_COUNT);
    var threads: [MAX_THREAD_COUNT]std.Thread = undefined;
    var result_handler: ResultHandler = .init(std.io.getStdOut().writer().any(), .{
        .handling_type = .vimgrep,
    });

    for (0..count_threads) |idx_thread| {
        threads[idx_thread] = try .spawn(.{}, search_thread, .{ needle, &result_handler, &opts.collector.? });
    }

    // TODO: make this wait based on some condvar or something like this
    for (0..count_threads) |idx_thread| {
        threads[idx_thread].join();
    }
}

fn search_thread(needle: []const u8, result_handler: *ResultHandler, collector: *Queue) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const cwd = std.fs.cwd();
    while (!finished and collector.len() > 0) {
        while (collector.pop()) |path| {
            defer std.debug.assert(arena.reset(.retain_capacity));

            const f = cwd.openFile(path, .{}) catch @panic("couldnt open a file");
            defer f.close();
            const haystack = f.readToEndAlloc(arena.allocator(), comptime std.math.maxInt(usize)) catch {
                @panic("couldnt read file to the end");
            };
            lib.search.search.simd_search(result_handler, path, haystack, needle);
        }
    }
}

const std = @import("std");
const lib = @import("qslib");
const fss = lib.fs_search;
const Queue = fss.Queue([]const u8);
// const Queue = fss.PathList;
const finder = fss.Finder(Queue);
const ResultHandler = lib.ResultHandler;

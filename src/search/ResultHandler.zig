writer: std.io.AnyWriter,
opts: Options = .{},
handling_fn: HandlingFn,

const Handler = @This();

const HandlingFn = *const fn (*Handler, SearchResult) void;

pub const Options = struct {
    handling_type: HandlingType = .default,
};

pub const HandlingType = enum {
    /// whatever I thought was nice at the time
    default,

    /// uses the vimgrep format
    vimgrep,

    /// this is supposed to be stable forever, so that I don't have
    /// to change the tests
    testing,
};

pub fn init(writer: std.io.AnyWriter, comptime opts: Options) Handler {
    const hfn = switch (opts.handling_type) {
        .default => handling_fn_default,
        .vimgrep => handling_fn_vimgrep,
        .testing => handling_fn_testing,
    };
    return .{ .writer = writer, .opts = opts, .handling_fn = hfn };
}

fn handling_fn_default(self: *Handler, r: SearchResult) void {
    std.debug.print("{}\n", .{r});
    self.writer.print("{d}:{d}: {s}\n", .{ r.row, r.col, r.line }) catch return;
}

fn handling_fn_vimgrep(self: *Handler, r: SearchResult) void {
    self.writer.print("TODO IMPLEMENT THIS, BUT: {}\n", .{r}) catch return;
}

fn handling_fn_testing(self: *Handler, r: SearchResult) void {
    const to_write = std.fmt.allocPrint(std.testing.allocator, "{d}:{d}: {s}\n", .{ r.row, r.col, r.line }) catch return;
    defer std.testing.allocator.free(to_write);
    self.writer.writeAll(to_write) catch return;
}

pub fn handle(self: *Handler, r: SearchResult) void {
    self.handling_fn(self, r);
}

const std = @import("std");
const SearchResult = @import("SearchResult.zig");

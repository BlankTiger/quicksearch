writer: std.io.AnyWriter,
opts: Options = .{},
handling_fn: HandlingFn,

const Handler = @This();

const HandlingFn = *const fn (*Handler, SearchResult) void;

pub const Options = struct {
    handling_type: HandlingType = .default,
    __testing_handle_count: ?*usize = null,
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
    self.writer.print("{d}:{d}: {s}\n", .{ r.row, r.col, r.line }) catch return;
}

fn handling_fn_vimgrep(self: *Handler, r: SearchResult) void {
    self.writer.print("TODO IMPLEMENT THIS, BUT: {}\n", .{r}) catch return;
}

fn handling_fn_testing(self: *Handler, r: SearchResult) void {
    if (self.opts.__testing_handle_count) |ptr| {
        ptr.* += 1;
    }
    self.writer.print("{d}:{d}: {s}\n", .{ r.row, r.col, r.line }) catch return;
}

pub fn handle(self: *Handler, r: SearchResult) void {
    self.handling_fn(self, r);
}

const std = @import("std");
const SearchResult = @import("SearchResult.zig");

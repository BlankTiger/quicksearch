writer: std.io.AnyWriter,
opts: Options = .{},
handling_fn: HandlingFn,
mutex: std.Thread.Mutex = .{},

const Handler = @This();

const HandlingFn = *const fn (*Handler, SearchResult) void;

pub const Options = if (!builtin.is_test) struct {
    handling_type: HandlingType = .default,
} else struct {
    handling_type: HandlingType = .default,
    testing_handle_count: ?*usize = null,
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
    if (self.opts.testing_handle_count) |ptr| {
        ptr.* += 1;
    }
    self.writer.print("{d}:{d}: {s}\n", .{ r.row, r.col, r.line }) catch return;
}

pub inline fn handle(self: *Handler, r: SearchResult) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.handling_fn(self, r);
}

pub inline fn handle_output(self: *Handler, data: []const u8) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    _ = self.writer.write(data) catch return;
}

pub inline fn handling_fn_output(_: *Handler, writer: std.io.AnyWriter, r: SearchResult) !void {
    try writer.print("{d}:{d}: {s}\n", .{ r.row, r.col, r.line });
}

pub inline fn handle_all(self: *Handler, rs: []const SearchResult) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    for (rs) |r| self.handling_fn(self, r);
}

const std = @import("std");
const SearchResult = @import("SearchResult.zig");
const builtin = @import("builtin");

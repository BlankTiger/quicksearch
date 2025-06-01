writer: std.io.AnyWriter,
opts: Options = .{},
format_fn: FormattingFn,
mutex: std.Thread.Mutex = .{},

const Handler = @This();

const FormattingFn = *const fn (*Handler, std.io.AnyWriter, SearchResult) anyerror!void;

pub const Options = if (!builtin.is_test) struct {
    handling_type: FormatType = .default,
} else struct {
    handling_type: FormatType = .default,
    testing_format_count: ?*usize = null,
};

pub const FormatType = enum {
    /// whatever I thought was nice at the time
    default,

    /// uses the vimgrep format
    vimgrep,

    /// this is supposed to be stable forever, so that I don't have
    /// to change the tests
    testing,
};

pub fn init(writer: std.io.AnyWriter, comptime opts: Options) Handler {
    const ffn = switch (opts.handling_type) {
        .default => format_fn_default,
        .vimgrep => format_fn_vimgrep,
        .testing => format_fn_testing,
    };
    return .{ .writer = writer, .opts = opts, .format_fn = ffn };
}

fn format_fn_default(_: *Handler, writer: std.io.AnyWriter, r: SearchResult) !void {
    try writer.print("{d}:{d}: {s}\n", .{ r.row, r.col, r.line });
}

fn format_fn_vimgrep(_: *Handler, writer: std.io.AnyWriter, r: SearchResult) !void {
    try writer.print("{s}:{d}:{d}: {s}\n", .{r.file_path, r.row, r.col, r.line});
}

fn format_fn_testing(self: *Handler, writer: std.io.AnyWriter, r: SearchResult) !void {
    if (self.opts.testing_format_count) |ptr| {
        ptr.* += 1;
    }
    try writer.print("{d}:{d}: {s}\n", .{ r.row, r.col, r.line });
}

pub inline fn format(self: *Handler, writer: std.io.AnyWriter, r: SearchResult) !void {
    try self.format_fn(self, writer, r);
}

pub inline fn write(self: *Handler, data: []const u8) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    _ = try self.writer.write(data);
}

const std = @import("std");
const SearchResult = @import("SearchResult.zig");
const builtin = @import("builtin");

/// holds paths to directories and if they are git directories,
/// then they hold IgnoreRules, otherwise it's null, which means
/// that directory is not a git directory or it didnt contain
/// any rules
cache: Cache,
allocator: std.mem.Allocator,

const Cache = std.StringHashMap(?IgnoreRules);
const IgnoreRules = struct {};
const Rule = struct {};
const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .cache = .init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: Self) void {
    self.cache.deinit();
}


const std = @import("std");

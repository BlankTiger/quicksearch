const MAX_USIZE = std.math.maxInt(usize);

pub const Rules = struct {
    list: std.ArrayList(Rule),

    pub fn init(allocator: std.mem.Allocator) Rules {
        return .{
            .list = .init(allocator),
        };
    }

    pub inline fn items(self: Rules) []const Rule {
        return self.list.items;
    }

    pub inline fn len(self: Rules) usize {
        return self.list.items.len;
    }

    pub inline fn append(self: *Rules, rule: Rule) !void {
        try self.list.append(rule);
    }

    pub inline fn append_slice(self: *Rules, rules: []const Rule) !void {
        try self.list.appendSlice(rules);
    }

    pub inline fn append_rules(self: *Rules, other: Rules) !void {
        try self.append_slice(other.items());
    }
};

pub const MatchResult = enum { excluded, included, none };

pub const RegexPart = union(enum) {
    literal: []const u8,
    char_range: CharRange,
    asterisk: void,
    double_asterisk: void,
    question_mark: void,
    slash: void,

    pub const CharRange = struct {
        ranges: []const Range,
        is_negated: bool,
    };

    pub const Range = union(enum) {
        single: u8,
        range: struct { start: u8, end: u8 },
    };
};

pub const Rule = struct {
    from_gitignore_in: []const u8,
    pattern: if (builtin.is_test) []const u8 else void,
    parts: []const RegexPart,
    is_negated: bool,
    is_for_dirs: bool,
    has_slashes: bool,
    root_relative: bool,

    ///
    /// `path` MUST:
    /// - BE TERMINATED BY A `/` IF IT'S A DIRECTORY
    /// - must also start with './'
    ///
    pub fn match(self: Rule, path: []const u8) MatchResult {
        std.debug.assert(path.len >= 2 and path[0] == '.' and path[1] == '/');

        var relative_to_gitignore = path;
        const maybe_prefix_offset = std.mem.indexOf(u8, path, self.from_gitignore_in);
        if (maybe_prefix_offset) |prefix_offset| {
            if (!(self.parts.len >= 2 and self.parts[0] == .literal and self.parts[0].literal.len == 1 and self.parts[0].literal[0] == '.' and self.parts[1] == .slash)) {
                relative_to_gitignore = path[prefix_offset + self.from_gitignore_in.len ..];
            }
        }

        var idx: usize = 0;
        if (self.root_relative) {
            // Root relative patterns must match from the beginning of the path
            // Don't skip to filename - match the full path from root
            idx = 0;
        } else {
            if (!self.has_slashes and !self.is_for_dirs and relative_to_gitignore[relative_to_gitignore.len - 1] != '/') {
                if (std.mem.lastIndexOfScalar(u8, relative_to_gitignore, '/')) |idx_slash| {
                    idx = idx_slash + 1;
                }
            }
        }

        const matches_patterns = self.match_from(relative_to_gitignore, idx, 0);
        if (matches_patterns) {
            if (self.is_negated) return .included;
            return .excluded;
        } else {
            return .none;
        }
    }

    fn match_from(self: Rule, path: []const u8, from_idx_path: usize, from_idx_part: usize) bool {
        if (path.len == 0 and from_idx_part >= self.parts.len - 1 and self.parts[self.parts.len - 1] == .double_asterisk) return false;
        if (path.len == 0 or path[from_idx_path..].len == 0) return from_idx_part > self.parts.len - 1;
        if (from_idx_part >= self.parts.len) {
            if (self.is_for_dirs) {
                return true;
            }
            return path.len == 0 or (path[from_idx_path..].len == 1 and path[from_idx_path] == '/');
        }

        std.debug.assert(from_idx_part < self.parts.len);
        std.debug.assert(from_idx_path < path.len);

        const subpath = path[from_idx_path..];
        const part = self.parts[from_idx_part];
        switch (part) {
            .literal => |txt| {
                if (subpath.len < txt.len) return false;
                if (self.is_for_dirs) {
                    const maybe_idx_literal = std.mem.indexOf(u8, subpath, txt);
                    if (maybe_idx_literal) |idx_literal| {
                        const offset = idx_literal + txt.len;
                        return self.match_from(subpath[offset..], 0, from_idx_part + 1);
                    } else {
                        return false;
                    }
                } else {
                    if (!std.mem.eql(u8, subpath[0..txt.len], txt)) return false;
                    return self.match_from(subpath[txt.len..], 0, from_idx_part + 1);
                }
            },

            .char_range => |ch_range| {
                const ranges = ch_range.ranges;
                const char = subpath[0];
                var none_matched = true;

                for (ranges) |r| {
                    switch (r) {
                        .single => |ch| if (char == ch) {
                            none_matched = false;
                            break;
                        },

                        .range => |ran| if (char >= ran.start and char <= ran.end) {
                            none_matched = false;
                            break;
                        },
                    }
                }

                if (none_matched and !ch_range.is_negated) return false;

                return self.match_from(subpath[1..], 0, from_idx_part + 1);
            },

            .question_mark => {
                if (subpath[0] == '/') return false;

                return self.match_from(subpath[1..], 0, from_idx_part + 1);
            },

            .slash => {
                if (subpath[0] != '/') return false;

                return self.match_from(subpath[1..], 0, from_idx_part + 1);
            },

            .asterisk => {
                if (from_idx_part + 1 < self.parts.len) {
                    const next = self.parts[from_idx_part + 1];
                    switch (next) {
                        .literal => |txt| {
                            const maybe_idx_literal = std.mem.indexOf(u8, subpath, txt);
                            if (maybe_idx_literal) |idx_literal| {
                                if (std.mem.indexOfScalar(u8, subpath[0..idx_literal], '/') != null) {
                                    return false;
                                }
                                return self.match_from(subpath[idx_literal + txt.len ..], 0, from_idx_part + 2);
                            } else {
                                return false;
                            }
                        },

                        .char_range => |ch_range| {
                            const ranges = ch_range.ranges;
                            var found_at_offset: usize = MAX_USIZE;

                            for (ranges) |r| {
                                for (subpath, 0..) |path_ch, idx_path_ch| {
                                    switch (r) {
                                        .single => |ch| if (path_ch == ch) {
                                            found_at_offset = idx_path_ch;
                                            break;
                                        },

                                        .range => |ran| if (path_ch >= ran.start and path_ch <= ran.end) {
                                            found_at_offset = idx_path_ch;
                                            break;
                                        },
                                    }
                                }
                            }

                            if (found_at_offset == MAX_USIZE and !ch_range.is_negated) return false;

                            return self.match_from(subpath[found_at_offset..], 0, from_idx_part + 2);
                        },

                        // NOTE: this will go until the next slash or the end of the path
                        .question_mark => {
                            if (from_idx_part + 2 < self.parts.len) {
                                const next_next = self.parts[from_idx_part + 2];
                                std.debug.assert(next_next == .slash);

                                const maybe_idx_slash = std.mem.indexOfScalar(u8, subpath, '/');
                                if (maybe_idx_slash) |idx_slash| {
                                    return self.match_from(subpath[idx_slash + 1 ..], 0, from_idx_part + 3);
                                } else {
                                    return false;
                                }
                            } else {
                                // go to the end of the path
                                std.debug.assert(std.mem.indexOfScalar(u8, subpath, '/') == null);
                                return true;
                            }
                        },

                        .slash => {
                            const maybe_idx_slash = std.mem.indexOfScalar(u8, subpath, '/');
                            if (maybe_idx_slash) |idx_slash| {
                                return self.match_from(subpath[idx_slash + 1 ..], 0, from_idx_part + 2);
                            } else {
                                return false;
                            }
                        },

                        .asterisk => @panic("it shouldnt be possible to have two consecutive .asterisk tokens, they should be a .double_asterisk"),

                        .double_asterisk => @panic("it shouldnt be possible to have a .double_asterisk after a single .asterisk"),
                    }
                } else {
                    // if we are here then this is the end and we match
                    std.debug.assert(self.parts.len - 1 == from_idx_part);
                    return true;
                }
            },

            // NOTE: .slash must always be after a .double_asterisk, or it means its the end of the pattern
            .double_asterisk => {
                return self.match_double_asterisk(subpath, 0, from_idx_part + 1);
            },
        }

        return false;
    }

    fn match_double_asterisk(self: Rule, path: []const u8, from_idx_path: usize, from_idx_part: usize) bool {
        // if there is no more parts to check after .double_asterisk then we match every directory
        if (from_idx_part >= self.parts.len - 1) {
            if (self.parts[self.parts.len - 1] == .double_asterisk) {
                return path.len != 0;
            }

            return path[path.len - 1] == '/';
        }

        std.debug.assert(self.parts[from_idx_part] == .slash);
        if (from_idx_part + 1 >= self.parts.len) @panic("huh");
        const part = self.parts[from_idx_part + 1];
        // we look for all consecutive slashes and try matching by the next part
        const subpath = if (path[from_idx_path] == '/') path[from_idx_path + 1 ..] else path[from_idx_path..];

        var idx_slash: usize = 0;
        var out_buf: [200]u8 = undefined;
        while (true) {
            const path_from_slash = subpath[idx_slash..];
            switch (part) {
                .literal => |txt| {
                    const maybe_idx_literal = std.mem.indexOf(u8, path_from_slash, txt);
                    if (maybe_idx_literal) |idx_literal| {
                        if (std.mem.indexOfScalar(u8, path_from_slash[0..idx_literal], '/') == null) {
                            return true;
                        }
                    }
                },

                .asterisk => {
                    if (from_idx_part + 2 >= self.parts.len) return true;

                    const next_part = self.parts[from_idx_part + 2];
                    switch (next_part) {
                        .literal => |txt| {
                            const maybe_idx_literal = std.mem.indexOf(u8, path_from_slash, txt);
                            if (maybe_idx_literal) |idx_literal| {
                                if (std.mem.indexOfScalar(u8, path_from_slash[0..idx_literal], '/') == null) {
                                    return true;
                                }
                            }
                        },

                        .asterisk, .double_asterisk => @panic("illegal"),

                        else => @panic(std.fmt.bufPrint(&out_buf, "unimplemented for: {s}", .{@tagName(next_part)}) catch "deez"),
                    }
                },

                else => @panic(std.fmt.bufPrint(&out_buf, "unimplemented for: {s}", .{@tagName(part)}) catch "nuts"),
            }

            const maybe_offset_slash = std.mem.indexOfScalar(u8, subpath[idx_slash..], '/');
            if (maybe_offset_slash) |offset_slash| {
                idx_slash += offset_slash + 1;
            } else {
                return false;
            }
        }

        return false;
    }
};

const std = @import("std");
const builtin = @import("builtin");

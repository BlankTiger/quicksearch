test {
    _ = @import("std").testing.refAllDecls(@This());
}

pub const GitIgnorer = @import("gitignore/GitIgnorer.zig");

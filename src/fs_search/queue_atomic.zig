pub fn Queue(T: anytype) type {
    return QueueWithCap(T, 512);
}

pub fn QueueWithCap(T: anytype, cap: usize) type {
    return struct {
        const Self = @This();

        buffer: [cap]T = undefined,
        head: std.atomic.Value(usize) = .init(0),
        tail: std.atomic.Value(usize) = .init(0),

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }

        pub fn deinit(self: Self) void {
            _ = self;
        }

        pub fn append(self: *Self, item: T) !bool {
            const tail_curr = self.tail.load(.acquire);
            const tail_next = (tail_curr + 1) % cap;

            if (tail_next == self.head.load(.acquire)) {
                // queue full
                return false;
            }

            self.buffer[tail_curr] = item;
            self.tail.store(tail_next, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            while (true) {
                const head_curr = self.head.load(.acquire);
                const tail_curr = self.tail.load(.acquire);

                if (head_curr == tail_curr) {
                    // queue empty
                    return null;
                }

                const item = self.buffer[head_curr];
                const head_next = (head_curr + 1) % cap;

                if (self.head.cmpxchgWeak(head_curr, head_next, .acq_rel, .acquire)) |_| {
                    continue;
                } else {
                    return item;
                }
            }
        }

        pub fn len(self: *const Self) usize {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);

            if (tail >= head) {
                return tail - head;
            } else {
                return cap - head + tail;
            }
        }

        // this is obviously wrong and only here to make testing easier
        pub fn items(self: *const Self) []const T {
            if (!builtin.is_test) {
                @panic("only for testing");
            }
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);

            return self.buffer[head..tail];
        }
    };
}

const builtin = @import("builtin");
const std = @import("std");

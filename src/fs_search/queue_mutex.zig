pub fn Queue(T: anytype) type {
    return QueueWithCap(T, 512);
}

pub fn QueueWithCap(T: anytype, cap: usize) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},
        not_empty: std.Thread.Condition = .{},
        not_full: std.Thread.Condition = .{},

        buffer: [cap]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        finished: bool = false,

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }

        pub fn deinit(self: Self) void {
            _ = self;
        }

        /// this does not take into account the `self.shutdown` flag, because
        /// we set it when the producer thread finishes producing all the items
        pub fn append(self: *Self, item: T) !bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count >= cap) {
                self.not_full.wait(&self.mutex);
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % cap;
            self.count += 1;

            self.not_empty.signal();
            return true;
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == 0 and !self.finished) {
                self.not_empty.wait(&self.mutex);
            }

            if (self.finished and self.count == 0) {
                return null;
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % cap;
            self.count -= 1;

            self.not_full.signal();

            return item;
        }

        pub fn finish(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.finished = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        // this is obviously wrong and only here to make testing easier
        pub fn items(self: *const Self) []const T {
            if (!builtin.is_test) {
                @panic("only for testing");
            }
            return self.buffer[self.head..self.tail];
        }
    };
}

const builtin = @import("builtin");
const std = @import("std");

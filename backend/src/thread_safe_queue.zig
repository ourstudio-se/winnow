const std = @import("std");

pub fn ThreadSafeQueue(T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            data: T,
            next: ?*Node,
        };

        allocator: std.mem.Allocator,
        closed: std.atomic.Value(bool),
        cond: std.Thread.Condition = .{},
        head: ?*Node = null,
        m: std.Thread.Mutex = .{},
        tail: ?*Node = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .closed = std.atomic.Value(bool).init(false),
                .m = .{},
                .cond = .{},
                .head = null,
                .tail = null,
            };
        }

        pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*Self {
            const queue = try allocator.create(Self);
            queue.* = Self.init(allocator);
            return queue;
        }

        pub fn close(queue: *Self) void {
            queue.closed.store(true, .release);
            queue.cond.broadcast();
        }

        pub fn destroy(queue: *Self) void {
            defer queue.allocator.destroy(queue);
            var n = queue.head;

            while (n) |node| {
                const next = node.next;
                queue.allocator.destroy(node);
                n = next;
            }
        }

        pub fn push(queue: *Self, data: T) error{ QueueClosed, OutOfMemory }!void {
            queue.m.lock();
            defer queue.m.unlock();

            if (queue.closed.load(.acquire)) {
                return error.QueueClosed;
            }

            var node = try queue.allocator.create(Node);
            node.next = null;
            node.data = data;
            if (queue.tail) |tail| {
                tail.next = node;
            }
            queue.tail = node;

            if (queue.head == null) {
                queue.head = queue.tail;
            }

            queue.cond.signal();
        }

        pub fn pop(queue: *Self) ?T {
            queue.m.lock();
            defer queue.m.unlock();

            while (queue.head == null) {
                if (queue.closed.load(.acquire)) return null;
                queue.cond.wait(&queue.m);
            }

            const head = queue.head.?;

            const next = head.next;
            const data = head.data;

            queue.allocator.destroy(head);

            queue.head = next;

            if (queue.head == null) {
                queue.tail = null;
            }

            return data;
        }
    };
}

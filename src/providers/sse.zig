// SSE (Server-Sent Events) line parser.
//
// Reads from a stream chunk by chunk. Emits complete `data:` lines via a
// callback. Handles:
//   - `data: <payload>\n\n` (one event)
//   - `data: <payload>\n` followed by another `data:` (multi-line event payload)
//   - Lines starting with `:` (comments, ignored)
//   - `event:` / `id:` / `retry:` lines (ignored for our use)
//   - `[DONE]` sentinel (OpenAI streaming terminator)

const std = @import("std");

pub const SseEvent = struct {
    data: []const u8, // owned by the parser; valid until next call
};

pub const SseParser = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    /// Pending event data lines (concatenated with \n)
    pending: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) SseParser {
        return .{
            .buf = std.ArrayList(u8).init(alloc),
            .alloc = alloc,
            .pending = std.ArrayList(u8).init(alloc),
        };
    }

    pub fn deinit(self: *SseParser) void {
        self.buf.deinit();
        self.pending.deinit();
    }

    /// Feed a chunk of bytes. Calls `on_event(data)` for each complete event.
    /// `data` is owned by the parser — caller should dupe if needed.
    pub fn feed(
        self: *SseParser,
        chunk: []const u8,
        ctx: anytype,
        comptime on_event: fn (@TypeOf(ctx), []const u8) anyerror!void,
    ) !void {
        try self.buf.appendSlice(chunk);

        // Process complete lines
        var start: usize = 0;
        var i: usize = 0;
        while (i < self.buf.items.len) : (i += 1) {
            if (self.buf.items[i] == '\n') {
                const line_end = if (i > start and self.buf.items[i - 1] == '\r') i - 1 else i;
                const line = self.buf.items[start..line_end];
                try self.processLine(line, ctx, on_event);
                start = i + 1;
            }
        }
        // Keep the remainder
        if (start > 0) {
            const remaining = self.buf.items[start..];
            std.mem.copyForwards(u8, self.buf.items[0..remaining.len], remaining);
            self.buf.shrinkRetainingCapacity(remaining.len);
        }
    }

    fn processLine(
        self: *SseParser,
        line: []const u8,
        ctx: anytype,
        comptime on_event: fn (@TypeOf(ctx), []const u8) anyerror!void,
    ) !void {
        if (line.len == 0) {
            // Empty line = event boundary. Flush pending data.
            if (self.pending.items.len > 0) {
                try on_event(ctx, self.pending.items);
                self.pending.clearRetainingCapacity();
            }
            return;
        }
        if (line[0] == ':') return; // comment
        if (std.mem.startsWith(u8, line, "data:")) {
            const data = std.mem.trim(u8, line[5..], " \t");
            if (self.pending.items.len > 0) try self.pending.append('\n');
            try self.pending.appendSlice(data);
        }
        // Other fields (event:, id:, retry:) are ignored
    }
};

test "SseParser: single event" {
    const alloc = std.testing.allocator;
    var p = SseParser.init(alloc);
    defer p.deinit();

    const Ctx = struct {
        events: *std.ArrayList([]u8),
        alloc: std.mem.Allocator,
    };
    var events = std.ArrayList([]u8).init(alloc);
    defer {
        for (events.items) |e| alloc.free(e);
        events.deinit();
    }
    const ctx = Ctx{ .events = &events, .alloc = alloc };

    const cb = struct {
        fn run(c: Ctx, data: []const u8) !void {
            try c.events.append(try c.alloc.dupe(u8, data));
        }
    }.run;

    try p.feed("data: hello\n\n", ctx, cb);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("hello", events.items[0]);
}

test "SseParser: multi-line data" {
    const alloc = std.testing.allocator;
    var p = SseParser.init(alloc);
    defer p.deinit();

    const Ctx = struct {
        events: *std.ArrayList([]u8),
        alloc: std.mem.Allocator,
    };
    var events = std.ArrayList([]u8).init(alloc);
    defer {
        for (events.items) |e| alloc.free(e);
        events.deinit();
    }
    const ctx = Ctx{ .events = &events, .alloc = alloc };

    const cb = struct {
        fn run(c: Ctx, data: []const u8) !void {
            try c.events.append(try c.alloc.dupe(u8, data));
        }
    }.run;

    try p.feed("data: line1\ndata: line2\n\n", ctx, cb);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("line1\nline2", events.items[0]);
}

test "SseParser: chunked feed" {
    const alloc = std.testing.allocator;
    var p = SseParser.init(alloc);
    defer p.deinit();

    const Ctx = struct {
        events: *std.ArrayList([]u8),
        alloc: std.mem.Allocator,
    };
    var events = std.ArrayList([]u8).init(alloc);
    defer {
        for (events.items) |e| alloc.free(e);
        events.deinit();
    }
    const ctx = Ctx{ .events = &events, .alloc = alloc };

    const cb = struct {
        fn run(c: Ctx, data: []const u8) !void {
            try c.events.append(try c.alloc.dupe(u8, data));
        }
    }.run;

    try p.feed("data: par", ctx, cb);
    try p.feed("t1\n\ndata: part2\n\n", ctx, cb);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqualStrings("part1", events.items[0]);
    try std.testing.expectEqualStrings("part2", events.items[1]);
}

test "SseParser: ignores comments and other fields" {
    const alloc = std.testing.allocator;
    var p = SseParser.init(alloc);
    defer p.deinit();

    const Ctx = struct {
        events: *std.ArrayList([]u8),
        alloc: std.mem.Allocator,
    };
    var events = std.ArrayList([]u8).init(alloc);
    defer {
        for (events.items) |e| alloc.free(e);
        events.deinit();
    }
    const ctx = Ctx{ .events = &events, .alloc = alloc };

    const cb = struct {
        fn run(c: Ctx, data: []const u8) !void {
            try c.events.append(try c.alloc.dupe(u8, data));
        }
    }.run;

    try p.feed(": comment\nevent: ping\ndata: hello\nid: 42\n\n", ctx, cb);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("hello", events.items[0]);
}

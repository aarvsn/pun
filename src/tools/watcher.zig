// File watcher tool — monitors workspace for file changes.
//
// Uses a background thread that polls the workspace directory tree every 2
// seconds and compares modification times. When a change is detected, the
// watcher appends to an internal event log that the agent can query.
//
// Tools:
//   watch_start    — start watching (idempotent; safe to call multiple times)
//   watch_stop     — stop watching
//   watch_events   — return new events since last call (clears the queue)
//   watch_status   — return current watch state + event count

const std = @import("std");
const types = @import("../types.zig");
const registry = @import("registry.zig");

const WatcherState = struct {
    alloc: std.mem.Allocator,
    workspace: []const u8,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    events: std.ArrayList(WatchEvent),
    events_mu: std.Thread.Mutex = .{},
    /// Map of path → mtime, rebuilt each poll
    snapshot: std.StringHashMap(i128),
};

const WatchEvent = struct {
    kind: enum { created, modified, deleted },
    path: []u8,
    ts: i64,
};

var watcher: ?WatcherState = null;

pub fn registerAll(reg: *registry.Registry, ctx: *registry.ToolContext) !void {
    _ = ctx;
    try reg.add(.{
        .name = "watch_start",
        .description = "Start watching the workspace for file changes. Polls every 2 seconds. Idempotent.",
        .parameters_schema =
            \\{"type":"object","properties":{}}
        ,
        .run = runStart,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "watch_stop",
        .description = "Stop watching the workspace.",
        .parameters_schema =
            \\{"type":"object","properties":{}}
        ,
        .run = runStop,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "watch_events",
        .description = "Return file change events since the last call. Clears the event queue. Each event has kind (created/modified/deleted), path, and timestamp.",
        .parameters_schema =
            \\{"type":"object","properties":{}}
        ,
        .run = runEvents,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "watch_status",
        .description = "Return the current watch state: running (bool) + pending event count.",
        .parameters_schema =
            \\{"type":"object","properties":{}}
        ,
        .run = runStatus,
        .ctx = undefined,
    });
}

fn ensureWatcher(alloc: std.mem.Allocator, workspace: []const u8) !*WatcherState {
    if (watcher == null) {
        watcher = .{
            .alloc = alloc,
            .workspace = workspace,
            .events = std.ArrayList(WatchEvent).init(alloc),
            .snapshot = std.StringHashMap(i128).init(alloc),
        };
    }
    return &watcher.?;
}

fn runStart(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    _ = args;
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const w = try ensureWatcher(alloc, c.workspace);

    if (w.running.load(.seq_cst)) {
        return .{ .content = try alloc.dupe(u8, "already running") };
    }

    // Build initial snapshot
    try buildSnapshot(w);

    w.running.store(true, .seq_cst);
    w.thread = try std.Thread.spawn(.{}, watchLoop, .{w});

    return .{ .content = try alloc.dupe(u8, "watching") };
}

fn runStop(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    _ = args;
    _ = ctx;
    if (watcher == null) return .{ .content = try alloc.dupe(u8, "not running") };
    const w = &watcher.?;
    w.running.store(false, .seq_cst);
    if (w.thread) |t| {
        t.detach();
        w.thread = null;
    }
    return .{ .content = try alloc.dupe(u8, "stopped") };
}

fn runEvents(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    _ = args;
    _ = ctx;
    if (watcher == null) return .{ .content = try alloc.dupe(u8, "[]") };
    const w = &watcher.?;

    w.events_mu.lock();
    defer w.events_mu.unlock();

    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    try buf.append('[');
    for (w.events.items, 0..) |e, i| {
        if (i > 0) try buf.append(',');
        const kind_s = switch (e.kind) {
            .created => "created",
            .modified => "modified",
            .deleted => "deleted",
        };
        try buf.appendSlice("{\"kind\":\"");
        try buf.appendSlice(kind_s);
        try buf.appendSlice("\",\"path\":\"");
        try writeJsonStr(buf.writer(), e.path);
        try buf.writer().print("\",\"ts\":{d}}}", .{e.ts});
    }
    try buf.append(']');

    // Free and clear events
    for (w.events.items) |e| alloc.free(e.path);
    w.events.clearRetainingCapacity();

    return .{ .content = try buf.toOwnedSlice() };
}

fn runStatus(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    _ = args;
    _ = ctx;
    if (watcher == null) {
        return .{ .content = try alloc.dupe(u8, "{\"running\":false,\"pending\":0}") };
    }
    const w = &watcher.?;
    w.events_mu.lock();
    const count = w.events.items.len;
    w.events_mu.unlock();
    const running = w.running.load(.seq_cst);
    const out = try std.fmt.allocPrint(alloc, "{{\"running\":{},\"pending\":{d}}}", .{ running, count });
    return .{ .content = out };
}

fn watchLoop(w: *WatcherState) void {
    while (w.running.load(.seq_cst)) {
        std.time.sleep(2 * std.time.ns_per_s);
        if (!w.running.load(.seq_cst)) break;
        pollOnce(w) catch {};
    }
}

fn buildSnapshot(w: *WatcherState) !void {
    // Free old snapshot
    var it = w.snapshot.iterator();
    while (it.next()) |e| {
        w.alloc.free(e.key_ptr.*);
    }
    w.snapshot.clearRetainingCapacity();

    try walkDir(w, w.workspace);
}

fn walkDir(w: *WatcherState, dir_path: []const u8) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.name[0] == '.') continue; // skip hidden
        const sub = try std.fs.path.join(w.alloc, &.{ dir_path, entry.name });
        defer w.alloc.free(sub);
        if (entry.kind == .directory) {
            try walkDir(w, sub);
        } else if (entry.kind == .file) {
            const stat = std.fs.cwd().statFile(sub) catch continue;
            const path_dup = try w.alloc.dupe(u8, sub);
            try w.snapshot.put(path_dup, stat.mtime);
        }
    }
}

fn pollOnce(w: *WatcherState) !void {
    var current = std.StringHashMap(i128).init(w.alloc);
    defer {
        var it = current.iterator();
        while (it.next()) |e| {
            w.alloc.free(e.key_ptr.*);
        }
        current.deinit();
    }

    // Walk and fill current
    try walkDirInto(w, w.workspace, &current);

    // Compare current vs snapshot
    var events = std.ArrayList(WatchEvent).init(w.alloc);
    defer events.deinit();

    // Check for created/modified
    var cit = current.iterator();
    while (cit.next()) |e| {
        const path = e.key_ptr.*;
        const mtime = e.value_ptr.*;
        if (w.snapshot.get(path)) |old_mtime| {
            if (old_mtime != mtime) {
                try events.append(.{ .kind = .modified, .path = try w.alloc.dupe(u8, path), .ts = std.time.timestamp() });
            }
        } else {
            try events.append(.{ .kind = .created, .path = try w.alloc.dupe(u8, path), .ts = std.time.timestamp() });
        }
    }

    // Check for deleted (in snapshot but not in current)
    var sit = w.snapshot.iterator();
    while (sit.next()) |e| {
        if (!current.contains(e.key_ptr.*)) {
            try events.append(.{ .kind = .deleted, .path = try w.alloc.dupe(u8, e.key_ptr.*), .ts = std.time.timestamp() });
        }
    }

    // Update snapshot: free old, swap in current's data
    var old_it = w.snapshot.iterator();
    while (old_it.next()) |e| {
        w.alloc.free(e.key_ptr.*);
    }
    w.snapshot.clearRetainingCapacity();
    var new_it = current.iterator();
    while (new_it.next()) |e| {
        const path_dup = try w.alloc.dupe(u8, e.key_ptr.*);
        try w.snapshot.put(path_dup, e.value_ptr.*);
    }

    // Append events to the queue
    if (events.items.len > 0) {
        w.events_mu.lock();
        defer w.events_mu.unlock();
        for (events.items) |e| {
            try w.events.append(e);
        }
    } else {
        // Free unused event paths
        for (events.items) |e| w.alloc.free(e.path);
    }
}

fn walkDirInto(w: *WatcherState, dir_path: []const u8, map: *std.StringHashMap(i128)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.name[0] == '.') continue;
        const sub = try std.fs.path.join(w.alloc, &.{ dir_path, entry.name });
        defer w.alloc.free(sub);
        if (entry.kind == .directory) {
            try walkDirInto(w, sub, map);
        } else if (entry.kind == .file) {
            const stat = std.fs.cwd().statFile(sub) catch continue;
            const path_dup = try w.alloc.dupe(u8, sub);
            try map.put(path_dup, stat.mtime);
        }
    }
}

fn writeJsonStr(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.print("\\\"", .{}),
            '\\' => try w.print("\\\\", .{}),
            '\n' => try w.print("\\n", .{}),
            else => try w.writeByte(c),
        }
    }
}

/// Shutdown the watcher (called on process exit).
pub fn shutdown() void {
    if (watcher) |*w| {
        w.running.store(false, .seq_cst);
        if (w.thread) |t| t.detach();
        for (w.events.items) |e| w.alloc.free(e.path);
        w.events.deinit();
        var it = w.snapshot.iterator();
        while (it.next()) |e| w.alloc.free(e.key_ptr.*);
        w.snapshot.deinit();
        watcher = null;
    }
}

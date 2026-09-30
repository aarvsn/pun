// Persistent conversation history (JSONL file at ~/.pun/history.jsonl).
//
// One line per message. Each line: {ts,session,role,content,tool_call_id,name,tool_calls}
//
// saveMessage() appends. loadRecent() reads the last 256KB and parses the
// trailing N messages into owned Message structs.

const std = @import("std");
const types = @import("../types.zig");
const util = @import("../util.zig");

var session_id_storage: ?[]u8 = null;
var session_id_alloc: ?std.mem.Allocator = null;
var id_counter: u64 = 0;

/// Generate a new session id and store it. Must be called once at startup.
pub fn initSession(alloc: std.mem.Allocator) !void {
    deinitSession();
    id_counter += 1;
    const ts: u64 = @intCast(std.time.timestamp());
    session_id_storage = try std.fmt.allocPrint(alloc, "{x}-{x}", .{ ts, id_counter });
    session_id_alloc = alloc;
}

/// Free the stored session id.
pub fn deinitSession() void {
    if (session_id_storage) |s| {
        if (session_id_alloc) |a| a.free(s);
        session_id_storage = null;
        session_id_alloc = null;
    }
}

/// Returns the current session id, or "unknown" if initSession wasn't called.
pub fn sessionId() []const u8 {
    return session_id_storage orelse "unknown";
}

/// Resolve the history file path. Returns owned memory.
fn historyPath(alloc: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch try alloc.dupe(u8, "/tmp");
    defer alloc.free(home);
    return std.fmt.allocPrint(alloc, "{s}/.pun/history.jsonl", .{home});
}

/// Append one message to the history file.
pub fn saveMessage(alloc: std.mem.Allocator, msg: types.Message) !void {
    const path = try historyPath(alloc);
    defer alloc.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }
    var f = try std.fs.cwd().createFile(path, .{ .read = false, .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);

    const ts = try util.isoNow(alloc);
    defer alloc.free(ts);

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"ts\":\"{s}\",\"session\":\"{s}\",\"role\":\"{s}\",\"content\":", .{
        ts,
        sessionId(),
        roleName(msg.role),
    });
    try writeJsonStr(&buf, msg.content);
    if (msg.tool_call_id) |tci| {
        try w.print(",\"tool_call_id\":", .{});
        try writeJsonStr(&buf, tci);
    }
    if (msg.name) |n| {
        try w.print(",\"name\":", .{});
        try writeJsonStr(&buf, n);
    }
    if (msg.tool_calls.len > 0) {
        try w.print(",\"tool_calls\":[", .{});
        for (msg.tool_calls, 0..) |tc, i| {
            if (i > 0) try w.print(",", .{});
            try w.print("{{\"id\":", .{});
            try writeJsonStr(&buf, tc.id);
            try w.print(",\"name\":", .{});
            try writeJsonStr(&buf, tc.name);
            try w.print(",\"arguments_json\":", .{});
            try writeJsonStr(&buf, tc.arguments_json);
            try w.print("}}", .{});
        }
        try w.print("]", .{});
    }
    try w.print("}}\n", .{});

    try f.writeAll(buf.items);
}

/// Load up to `n` most-recent messages from the history file.
/// Returns owned slice of owned Messages (caller must deinit each + free the slice).
pub fn loadRecent(alloc: std.mem.Allocator, n: usize) ![]types.Message {
    const path = try historyPath(alloc);
    defer alloc.free(path);

    var f = std.fs.cwd().openFile(path, .{}) catch return &.{};
    defer f.close();
    const stat = try f.stat();
    if (stat.size == 0) return &.{};

    // Read the last 256KB
    const tail_size: u64 = @min(stat.size, 256 * 1024);
    const buf = try alloc.alloc(u8, tail_size);
    defer alloc.free(buf);
    try f.seekFromEnd(-@as(i64, @intCast(tail_size)));
    const got = try f.readAll(buf);
    const data = buf[0..got];

    // Skip the first partial line (unless we're at the start of the file)
    var start: usize = 0;
    if (stat.size > tail_size) {
        if (std.mem.indexOfScalar(u8, data, '\n')) |nl| {
            start = nl + 1;
        } else {
            return &.{};
        }
    }

    // Collect each complete line into a temp list, then take the last n.
    var lines = std.ArrayList(types.Message).init(alloc);
    errdefer {
        for (lines.items) |*m| m.deinit(alloc);
        lines.deinit();
    }

    var it = std.mem.tokenizeScalar(u8, data[start..], '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const m = parseLine(alloc, line) catch continue;
        try lines.append(m);
    }

    // Take last n
    const total = lines.items.len;
    if (total == 0) {
        lines.deinit();
        return &.{};
    }
    const take_start = if (total > n) total - n else 0;
    const take = total - take_start;
    var out = try alloc.alloc(types.Message, take);
    // Free items we're not keeping
    for (0..take_start) |i| {
        lines.items[i].deinit(alloc);
    }
    // Move kept items into out (struct copy; ownership transferred)
    for (0..take) |i| {
        out[i] = lines.items[take_start + i];
    }
    // Deinit the list storage (the moved slots' pointers are now owned by `out`)
    lines.deinit();
    return out;
}

fn parseLine(alloc: std.mem.Allocator, line: []const u8) !types.Message {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidLine;
    const obj = parsed.value.object;

    const role_str = if (obj.get("role")) |v| (if (v == .string) v.string else "user") else "user";
    const role: types.Role = if (std.mem.eql(u8, role_str, "assistant"))
        .assistant
    else if (std.mem.eql(u8, role_str, "tool"))
        .tool
    else if (std.mem.eql(u8, role_str, "system"))
        .system
    else
        .user;

    const content = if (obj.get("content")) |v| (if (v == .string) v.string else "") else "";
    const tool_call_id: ?[]u8 = blk: {
        if (obj.get("tool_call_id")) |v| {
            if (v == .string) break :blk try alloc.dupe(u8, v.string);
        }
        break :blk null;
    };
    const name: ?[]u8 = blk: {
        if (obj.get("name")) |v| {
            if (v == .string) break :blk try alloc.dupe(u8, v.string);
        }
        break :blk null;
    };

    var tool_calls: []types.ToolCall = &.{};
    if (obj.get("tool_calls")) |v| {
        if (v == .array and v.array.items.len > 0) {
            var tcs = try alloc.alloc(types.ToolCall, v.array.items.len);
            errdefer alloc.free(tcs);
            var ok_count: usize = 0;
            for (v.array.items) |tc_v| {
                if (tc_v != .object) continue;
                const id = if (tc_v.object.get("id")) |x| (if (x == .string) x.string else "") else "";
                const nm = if (tc_v.object.get("name")) |x| (if (x == .string) x.string else "") else "";
                const aj = if (tc_v.object.get("arguments_json")) |x| (if (x == .string) x.string else "") else "{}";
                tcs[ok_count] = .{
                    .id = try alloc.dupe(u8, id),
                    .name = try alloc.dupe(u8, nm),
                    .arguments_json = try alloc.dupe(u8, aj),
                };
                ok_count += 1;
            }
            if (ok_count == 0) {
                alloc.free(tcs);
            } else {
                tool_calls = tcs[0..ok_count];
            }
        }
    }

    return .{
        .role = role,
        .content = try alloc.dupe(u8, content),
        .tool_calls = tool_calls,
        .tool_call_id = tool_call_id,
        .name = name,
    };
}

/// Truncate the history file. Returns the old size in bytes.
pub fn clear(alloc: std.mem.Allocator) !u64 {
    const path = try historyPath(alloc);
    defer alloc.free(path);
    var f = std.fs.cwd().openFile(path, .{}) catch {
        // No file — nothing to clear
        return 0;
    };
    defer f.close();
    const stat = try f.stat();
    try f.setEndPos(0);
    return stat.size;
}

fn roleName(r: types.Role) []const u8 {
    return switch (r) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

fn writeJsonStr(buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append('"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            else => if (c < 0x20) {
                try buf.writer().print("\\u{x:0>4}", .{c});
            } else try buf.append(c),
        }
    }
    try buf.append('"');
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "saveMessage + loadRecent round-trip" {
    const alloc = std.testing.allocator;

    // Force HOME=/tmp so we write to /tmp/.pun/history.jsonl
    const old_home = std.process.getEnvVarOwned(alloc, "HOME") catch null;
    defer if (old_home) |h| alloc.free(h);
    _ = setenv("HOME", "/tmp", 1);

    // Delete any pre-existing file
    std.fs.cwd().deleteFile("/tmp/.pun/history.jsonl") catch {};
    defer std.fs.cwd().deleteFile("/tmp/.pun/history.jsonl") catch {};

    try initSession(alloc);
    defer deinitSession();

    // Empty history → empty slice
    const empty = try loadRecent(alloc, 10);
    defer alloc.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // Save two messages
    try saveMessage(alloc, .{
        .role = .user,
        .content = "hello world",
    });
    try saveMessage(alloc, .{
        .role = .assistant,
        .content = "hi there",
    });

    // Load and verify
    const msgs = try loadRecent(alloc, 10);
    defer {
        for (msgs) |*m| m.deinit(alloc);
        alloc.free(msgs);
    }
    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    try std.testing.expectEqualStrings("hello world", msgs[0].content);
    try std.testing.expectEqualStrings("hi there", msgs[1].content);

    // Restore old HOME
    if (old_home) |h| {
        const h_z = alloc.dupeZ(u8, h) catch return;
        defer alloc.free(h_z);
        _ = setenv("HOME", h_z.ptr, 1);
    } else {
        _ = unsetenv("HOME");
    }
}

// ---- Multi-session support (v0.6) ----

pub const SessionInfo = struct {
    id: []u8,
    first_ts: []u8,
    msg_count: usize,
    first_content: []u8,
};

/// List all distinct sessions found in the history file, with the first
/// message's timestamp + content preview and total message count.
/// Returns owned slice; caller frees each SessionInfo's fields + the slice.
pub fn listSessions(alloc: std.mem.Allocator) ![]SessionInfo {
    const path = try historyPath(alloc);
    defer alloc.free(path);
    var f = std.fs.cwd().openFile(path, .{}) catch return &.{};
    defer f.close();
    const stat = try f.stat();
    if (stat.size == 0) return &.{};

    // Read up to 1MB
    const cap: usize = 1024 * 1024;
    const read_len: u64 = if (stat.size > cap) cap else stat.size;
    const buf = try alloc.alloc(u8, read_len);
    defer alloc.free(buf);
    _ = try f.readAll(buf);

    // Parse all lines, track sessions in a hashmap
    var sessions = std.StringHashMap(SessionInfo).init(alloc);
    defer sessions.deinit();

    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const sid = if (obj.get("session")) |v| (if (v == .string) v.string else "") else "";
        if (sid.len == 0) continue;
        const ts = if (obj.get("ts")) |v| (if (v == .string) v.string else "") else "";
        const content = if (obj.get("content")) |v| (if (v == .string) v.string else "") else "";

        if (sessions.getPtr(sid)) |existing| {
            existing.msg_count += 1;
        } else {
            const sid_dup = try alloc.dupe(u8, sid);
            try sessions.put(sid_dup, .{
                .id = sid_dup,
                .first_ts = try alloc.dupe(u8, ts),
                .msg_count = 1,
                .first_content = try alloc.dupe(u8, if (content.len > 80) content[0..80] else content),
            });
        }
    }

    // Collect into a slice
    var out = std.ArrayList(SessionInfo).init(alloc);
    errdefer out.deinit();
    var it = sessions.iterator();
    while (it.next()) |e| {
        try out.append(.{
            .id = try alloc.dupe(u8, e.value_ptr.id),
            .first_ts = try alloc.dupe(u8, e.value_ptr.first_ts),
            .msg_count = e.value_ptr.msg_count,
            .first_content = try alloc.dupe(u8, e.value_ptr.first_content),
        });
    }

    // Free the hashmap's copies
    var fit = sessions.iterator();
    while (fit.next()) |e| {
        alloc.free(e.value_ptr.id);
        alloc.free(e.value_ptr.first_ts);
        alloc.free(e.value_ptr.first_content);
    }

    return try out.toOwnedSlice();
}

/// Load all messages from a specific session id.
/// Returns owned messages slice.
pub fn loadSession(alloc: std.mem.Allocator, session_id: []const u8) ![]types.Message {
    const path = try historyPath(alloc);
    defer alloc.free(path);
    var f = std.fs.cwd().openFile(path, .{}) catch return &.{};
    defer f.close();
    const stat = try f.stat();
    if (stat.size == 0) return &.{};

    const cap: usize = 1024 * 1024;
    const read_len: u64 = if (stat.size > cap) cap else stat.size;
    const buf = try alloc.alloc(u8, read_len);
    defer alloc.free(buf);
    _ = try f.readAll(buf);

    var all = std.ArrayList(types.Message).init(alloc);
    errdefer {
        for (all.items) |*m| m.deinit(alloc);
        all.deinit();
    }

    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        // Filter by session id
        const sid = if (obj.get("session")) |v| (if (v == .string) v.string else "") else "";
        if (!std.mem.eql(u8, sid, session_id)) continue;

        const role_v = obj.get("role") orelse continue;
        if (role_v != .string) continue;
        const role: types.Role = blk: {
            if (std.mem.eql(u8, role_v.string, "user")) break :blk .user;
            if (std.mem.eql(u8, role_v.string, "assistant")) break :blk .assistant;
            if (std.mem.eql(u8, role_v.string, "tool")) break :blk .tool;
            if (std.mem.eql(u8, role_v.string, "system")) break :blk .system;
            continue;
        };
        const content = if (obj.get("content")) |c| (if (c == .string) c.string else "") else "";

        var tool_calls: []types.ToolCall = &.{};
        if (obj.get("tool_calls")) |tc_arr| {
            if (tc_arr == .array) {
                var tcs = std.ArrayList(types.ToolCall).init(alloc);
                errdefer tcs.deinit();
                for (tc_arr.array.items) |tc_v| {
                    if (tc_v != .object) continue;
                    const id = if (tc_v.object.get("id")) |v| (if (v == .string) v.string else "") else "";
                    const name = if (tc_v.object.get("name")) |v| (if (v == .string) v.string else "") else "";
                    const args = if (tc_v.object.get("arguments")) |v| (if (v == .string) v.string else "{}") else "{}";
                    try tcs.append(.{
                        .id = try alloc.dupe(u8, id),
                        .name = try alloc.dupe(u8, name),
                        .arguments_json = try alloc.dupe(u8, args),
                    });
                }
                tool_calls = try tcs.toOwnedSlice();
            }
        }

        var tool_call_id: ?[]u8 = null;
        if (obj.get("tool_call_id")) |v| {
            if (v == .string) tool_call_id = try alloc.dupe(u8, v.string);
        }
        var name_field: ?[]u8 = null;
        if (obj.get("name")) |v| {
            if (v == .string) name_field = try alloc.dupe(u8, v.string);
        }

        try all.append(.{
            .role = role,
            .content = try alloc.dupe(u8, content),
            .tool_calls = tool_calls,
            .tool_call_id = tool_call_id,
            .name = name_field,
        });
    }

    return try all.toOwnedSlice();
}

/// Switch to an existing session id (just sets the active session for future saveMessage calls).
pub fn switchSession(alloc: std.mem.Allocator, session_id: []const u8) !void {
    deinitSession();
    session_id_storage = try alloc.dupe(u8, session_id);
    session_id_alloc = alloc;
}

pub fn freeSessionList(alloc: std.mem.Allocator, list: []SessionInfo) void {
    for (list) |s| {
        alloc.free(s.id);
        alloc.free(s.first_ts);
        alloc.free(s.first_content);
    }
    alloc.free(list);
}

// ---- Full-text session search (v0.7) ----

pub const SearchResult = struct {
    session_id: []u8,
    role: []u8,
    content: []u8,
    ts: []u8,
};

/// Search across all history entries for a substring (case-insensitive).
/// Returns matching messages with their session id, role, content, and timestamp.
/// Caller frees each SearchResult's fields + the slice.
pub fn searchHistory(alloc: std.mem.Allocator, query: []const u8, max_results: usize) ![]SearchResult {
    const path = try historyPath(alloc);
    defer alloc.free(path);
    var f = std.fs.cwd().openFile(path, .{}) catch return &.{};
    defer f.close();
    const stat = try f.stat();
    if (stat.size == 0) return &.{};

    const cap: usize = 4 * 1024 * 1024; // 4MB
    const read_len: u64 = if (stat.size > cap) cap else stat.size;
    const buf = try alloc.alloc(u8, read_len);
    defer alloc.free(buf);
    _ = try f.readAll(buf);

    var results = std.ArrayList(SearchResult).init(alloc);
    errdefer {
        for (results.items) |r| {
            alloc.free(r.session_id);
            alloc.free(r.role);
            alloc.free(r.content);
            alloc.free(r.ts);
        }
        results.deinit();
    }

    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const content = if (obj.get("content")) |v| (if (v == .string) v.string else "") else "";
        if (content.len == 0) continue;

        // Case-insensitive substring search
        if (std.ascii.indexOfIgnoreCase(content, query) == null) continue;

        const sid = if (obj.get("session")) |v| (if (v == .string) v.string else "") else "";
        const role = if (obj.get("role")) |v| (if (v == .string) v.string else "") else "";
        const ts = if (obj.get("ts")) |v| (if (v == .string) v.string else "") else "";

        try results.append(.{
            .session_id = try alloc.dupe(u8, sid),
            .role = try alloc.dupe(u8, role),
            .content = try alloc.dupe(u8, content),
            .ts = try alloc.dupe(u8, ts),
        });

        if (results.items.len >= max_results) break;
    }

    return try results.toOwnedSlice();
}

pub fn freeSearchResults(alloc: std.mem.Allocator, results: []SearchResult) void {
    for (results) |r| {
        alloc.free(r.session_id);
        alloc.free(r.role);
        alloc.free(r.content);
        alloc.free(r.ts);
    }
    alloc.free(results);
}

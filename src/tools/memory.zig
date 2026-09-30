// Memory tool: cross-session memory with embeddings-based recall.
//
// Storage: ~/.pun/memory.json
// Schema:
//   {
//     "entries": [
//       { "key": "...", "value": "...", "embedding": [0.1, 0.2, ...], "ts": 1234567890 }
//     ]
//   }
//
// Embeddings: 128-dimensional character n-gram hashing (no external deps).
// Each entry's value is tokenized into 3-grams; each gram is hashed into one
// of 128 buckets; the bucket count is normalized to a unit vector.
//
// Recall:
//   - memory_recall(key): exact key match → value
//   - memory_search(query): compute query embedding, return top-N by cosine sim

const std = @import("std");
const types = @import("../types.zig");
const registry = @import("registry.zig");
const util = @import("../util.zig");

const EMBED_DIM: usize = 128;

pub fn registerAll(reg: *registry.Registry, ctx: *registry.ToolContext) !void {
    _ = ctx;
    try reg.add(.{
        .name = "memory_save",
        .description = "Persist a key-value pair to ~/.pun/memory.json for recall across sessions. Computes an embedding for semantic search.",
        .parameters_schema =
            \\{"type":"object","properties":{"key":{"type":"string"},"value":{"type":"string"}},"required":["key","value"]}
        ,
        .run = runSave,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "memory_recall",
        .description = "Recall a value by exact key from ~/.pun/memory.json. Returns '(none)' if not found.",
        .parameters_schema =
            \\{"type":"object","properties":{"key":{"type":"string"}},"required":["key"]}
        ,
        .run = runRecall,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "memory_search",
        .description = "Semantic search over memory entries by cosine similarity. Returns top-N (default 3) matches with key, value, and similarity score.",
        .parameters_schema =
            \\{"type":"object","properties":{"query":{"type":"string"},"n":{"type":"integer","description":"Max results; default 3"}},"required":["query"]}
        ,
        .run = runSearch,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "memory_list",
        .description = "List all keys in memory.",
        .parameters_schema =
            \\{"type":"object","properties":{}}
        ,
        .run = runList,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "memory_delete",
        .description = "Delete a memory entry by key.",
        .parameters_schema =
            \\{"type":"object","properties":{"key":{"type":"string"}},"required":["key"]}
        ,
        .run = runDelete,
        .ctx = undefined,
    });
}

const Entry = struct {
    key: []u8,
    value: []u8,
    embedding: [EMBED_DIM]f32,
    ts: i64,
};

fn memoryPath(alloc: std.mem.Allocator) ![]u8 {
    return util.expandPath(alloc, "~/.pun/memory.json");
}

/// Compute a 128-dim character trigram hashing embedding, normalized to unit length.
fn embed(text: []const u8) [EMBED_DIM]f32 {
    var vec: [EMBED_DIM]f32 = .{0} ** EMBED_DIM;
    if (text.len < 3) {
        // Fall back to unigrams for very short text
        for (text) |c| {
            const h = std.hash.CityHash32.hash(&.{c});
            vec[h % EMBED_DIM] += 1;
        }
    } else {
        var i: usize = 0;
        while (i + 3 <= text.len) : (i += 1) {
            const gram = text[i .. i + 3];
            const h = std.hash.CityHash32.hash(gram);
            vec[h % EMBED_DIM] += 1;
        }
    }
    // Normalize to unit length (L2)
    var norm: f32 = 0;
    for (vec) |v| norm += v * v;
    norm = @sqrt(norm);
    if (norm > 0) {
        for (&vec) |*v| v.* /= norm;
    }
    return vec;
}

fn cosine(a: [EMBED_DIM]f32, b: [EMBED_DIM]f32) f32 {
    var dot: f32 = 0;
    for (a, b) |x, y| dot += x * y;
    return dot;
}

/// Load all entries from disk.
fn loadEntries(alloc: std.mem.Allocator) !std.ArrayList(Entry) {
    var entries = std.ArrayList(Entry).init(alloc);
    errdefer {
        for (entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        entries.deinit();
    }
    const path = try memoryPath(alloc);
    defer alloc.free(path);
    const f = std.fs.cwd().openFile(path, .{}) catch return entries;
    defer f.close();
    const stat = try f.stat();
    if (stat.size == 0) return entries;
    const buf = try alloc.alloc(u8, stat.size);
    defer alloc.free(buf);
    _ = try f.readAll(buf);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, buf, .{}) catch return entries;
    defer parsed.deinit();
    if (parsed.value != .object) return entries;
    const arr_v = parsed.value.object.get("entries") orelse return entries;
    if (arr_v != .array) return entries;

    for (arr_v.array.items) |item| {
        if (item != .object) continue;
        const k = if (item.object.get("key")) |v| (if (v == .string) v.string else "") else "";
        const v = if (item.object.get("value")) |v| (if (v == .string) v.string else "") else "";
        const ts: i64 = if (item.object.get("ts")) |t| (if (t == .integer) t.integer else 0) else 0;
        var emb: [EMBED_DIM]f32 = .{0} ** EMBED_DIM;
        if (item.object.get("embedding")) |e| {
            if (e == .array) {
                for (e.array.items, 0..) |ev, i| {
                    if (i >= EMBED_DIM) break;
                    if (ev == .float) emb[i] = @floatCast(ev.float)
                    else if (ev == .integer) emb[i] = @floatFromInt(ev.integer);
                }
            }
        }
        try entries.append(.{
            .key = try alloc.dupe(u8, k),
            .value = try alloc.dupe(u8, v),
            .embedding = emb,
            .ts = ts,
        });
    }
    return entries;
}

/// Save all entries to disk (atomic via tmp + rename).
fn saveEntries(alloc: std.mem.Allocator, entries: std.ArrayList(Entry)) !void {
    const path = try memoryPath(alloc);
    defer alloc.free(path);
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"entries\":[", .{});
    for (entries.items, 0..) |e, i| {
        if (i > 0) try w.print(",", .{});
        try w.print("{{\"key\":\"", .{});
        try writeJsonStr(w, e.key);
        try w.print("\",\"value\":\"", .{});
        try writeJsonStr(w, e.value);
        try w.print("\",\"embedding\":[", .{});
        for (e.embedding, 0..) |v, j| {
            if (j > 0) try w.print(",", .{});
            try w.print("{d:.6}", .{v});
        }
        try w.print("],\"ts\":{d}}}", .{e.ts});
    }
    try w.print("]}}\n", .{});

    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    var f = try std.fs.cwd().createFile(tmp_path, .{});
    defer f.close();
    try f.writeAll(buf.items);
    try std.fs.cwd().rename(tmp_path, path);
}

fn runSave(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const k_v = args.value.object.get("key") orelse return errorResult(alloc, "missing 'key'");
    const v_v = args.value.object.get("value") orelse return errorResult(alloc, "missing 'value'");
    if (k_v != .string or v_v != .string) return errorResult(alloc, "invalid args");

    var entries = try loadEntries(alloc);
    defer {
        for (entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        entries.deinit();
    }

    // Remove existing entry with same key
    var i: usize = 0;
    while (i < entries.items.len) {
        if (std.mem.eql(u8, entries.items[i].key, k_v.string)) {
            alloc.free(entries.items[i].key);
            alloc.free(entries.items[i].value);
            _ = entries.swapRemove(i);
        } else {
            i += 1;
        }
    }

    // Append new entry
    try entries.append(.{
        .key = try alloc.dupe(u8, k_v.string),
        .value = try alloc.dupe(u8, v_v.string),
        .embedding = embed(v_v.string),
        .ts = std.time.timestamp(),
    });

    try saveEntries(alloc, entries);
    try c.policy.audit_log.log(.vault_access, "memory_save", k_v.string);
    return .{ .content = try alloc.dupe(u8, "ok") };
}

fn runRecall(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    _ = c;
    const k_v = args.value.object.get("key") orelse return errorResult(alloc, "missing 'key'");
    if (k_v != .string) return errorResult(alloc, "'key' must be string");
    var entries = try loadEntries(alloc);
    defer {
        for (entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        entries.deinit();
    }
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.key, k_v.string)) {
            return .{ .content = try alloc.dupe(u8, e.value) };
        }
    }
    return .{ .content = try alloc.dupe(u8, "(none)") };
}

fn runSearch(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    _ = c;
    const q_v = args.value.object.get("query") orelse return errorResult(alloc, "missing 'query'");
    if (q_v != .string) return errorResult(alloc, "'query' must be string");
    const n: usize = if (args.value.object.get("n")) |v| (if (v == .integer) @intCast(v.integer) else 3) else 3;

    var entries = try loadEntries(alloc);
    defer {
        for (entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        entries.deinit();
    }
    if (entries.items.len == 0) {
        return .{ .content = try alloc.dupe(u8, "(memory empty)") };
    }

    const query_emb = embed(q_v.string);

    // Score all entries
    const Scored = struct { idx: usize, score: f32 };
    var scored = try alloc.alloc(Scored, entries.items.len);
    defer alloc.free(scored);
    for (entries.items, 0..) |e, i| {
        scored[i] = .{ .idx = i, .score = cosine(query_emb, e.embedding) };
    }
    // Sort descending by score
    std.mem.sort(Scored, scored, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score;
        }
    }.lt);

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    const limit = if (n < entries.items.len) n else entries.items.len;
    for (scored[0..limit], 0..) |s, i| {
        const e = entries.items[s.idx];
        try out.writer().print("{d}. [score={d:.3}] {s}: {s:.200}\n", .{ i + 1, s.score, e.key, e.value });
    }
    return .{ .content = try out.toOwnedSlice() };
}

fn runList(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    _ = ctx;
    _ = args;
    var entries = try loadEntries(alloc);
    defer {
        for (entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        entries.deinit();
    }
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    if (entries.items.len == 0) {
        try buf.appendSlice("(memory empty)");
        return .{ .content = try buf.toOwnedSlice() };
    }
    for (entries.items) |e| {
        try buf.appendSlice(e.key);
        try buf.append('\n');
    }
    return .{ .content = try buf.toOwnedSlice() };
}

fn runDelete(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const k_v = args.value.object.get("key") orelse return errorResult(alloc, "missing 'key'");
    if (k_v != .string) return errorResult(alloc, "'key' must be string");
    var entries = try loadEntries(alloc);
    defer {
        for (entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        entries.deinit();
    }
    var found = false;
    var i: usize = 0;
    while (i < entries.items.len) {
        if (std.mem.eql(u8, entries.items[i].key, k_v.string)) {
            alloc.free(entries.items[i].key);
            alloc.free(entries.items[i].value);
            _ = entries.swapRemove(i);
            found = true;
        } else {
            i += 1;
        }
    }
    if (!found) return .{ .content = try alloc.dupe(u8, "(not found)") };
    try saveEntries(alloc, entries);
    try c.policy.audit_log.log(.vault_access, "memory_delete", k_v.string);
    return .{ .content = try alloc.dupe(u8, "ok") };
}

fn errorResult(alloc: std.mem.Allocator, msg: []const u8) types.ToolResult {
    return .{
        .content = alloc.dupe(u8, msg) catch "",
        .is_error = true,
    };
}

fn writeJsonStr(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.print("\\\"", .{}),
            '\\' => try w.print("\\\\", .{}),
            '\n' => try w.print("\\n", .{}),
            '\r' => try w.print("\\r", .{}),
            '\t' => try w.print("\\t", .{}),
            else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        }
    }
}

test "embed: zero vector for empty" {
    const e = embed("");
    var sum: f32 = 0;
    for (e) |v| sum += v * v;
    try std.testing.expect(sum == 0);
}

test "embed: unit norm for nonempty" {
    const e = embed("hello world this is a test");
    var sum: f32 = 0;
    for (e) |v| sum += v * v;
    // Should be ~1.0 (within float precision)
    try std.testing.expect(sum > 0.99 and sum < 1.01);
}

test "cosine: identical vectors = 1" {
    const a = embed("the quick brown fox");
    const b = embed("the quick brown fox");
    try std.testing.expect(cosine(a, b) > 0.99);
}

test "cosine: dissimilar vectors < similar" {
    const q = embed("the quick brown fox");
    const similar = embed("the quick brown fox jumps over");
    const dissimilar = embed("zzzzz xxxxx yyyyy");
    try std.testing.expect(cosine(q, similar) > cosine(q, dissimilar));
}

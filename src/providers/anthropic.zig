// Anthropic Messages API adapter.
//
// POST https://api.anthropic.com/v1/messages
// Headers: x-api-key, anthropic-version: 2023-06-01, content-type: application/json
//
// Notes:
// - System prompt is a top-level field, not a message.
// - Tool calls come back in `content` blocks of type `tool_use`.
// - Tool results are sent as messages with role=user containing `tool_result` blocks.

const std = @import("std");
const base = @import("base.zig");
const http = @import("http.zig");
const types = @import("../types.zig");
const config = @import("../config/schema.zig");

const DEFAULT_BASE_URL = "https://api.anthropic.com";

pub const AnthropicProvider = struct {
    alloc: std.mem.Allocator,
    api_key: []u8,
    base_url: []u8,
    default_model: []u8,

    pub fn init(alloc: std.mem.Allocator, api_key: []const u8, base_url: ?[]const u8, default_model: []const u8) !*AnthropicProvider {
        const self = try alloc.create(AnthropicProvider);
        self.* = .{
            .alloc = alloc,
            .api_key = try alloc.dupe(u8, api_key),
            .base_url = try alloc.dupe(u8, base_url orelse DEFAULT_BASE_URL),
            .default_model = try alloc.dupe(u8, default_model),
        };
        return self;
    }

    pub fn deinit(impl: *anyopaque) void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(impl));
        self.alloc.free(self.api_key);
        self.alloc.free(self.base_url);
        self.alloc.free(self.default_model);
        self.alloc.destroy(self);
    }

    pub fn chat(
        impl: *anyopaque,
        alloc: std.mem.Allocator,
        messages: []const types.Message,
        opts: base.ChatOptions,
    ) anyerror!base.ChatResponse {
        const self: *AnthropicProvider = @ptrCast(@alignCast(impl));
        const model = if (opts.model.len > 0) opts.model else self.default_model;
        const url = try std.fmt.allocPrint(alloc, "{s}/v1/messages", .{self.base_url});
        defer alloc.free(url);

        const body = try buildRequestBody(alloc, messages, opts, model);
        defer alloc.free(body);

        const auth_header = try std.fmt.allocPrint(alloc, "{s}", .{self.api_key});
        defer alloc.free(auth_header);
        const headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = auth_header },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "content-type", .value = "application/json" },
        };

        var resp = try http.postJson(alloc, url, &headers, body);
        defer resp.deinit();

        if (resp.status != 200) {
            return mapStatus(resp.status, resp.body);
        }

        return parseResponse(alloc, resp.body);
    }

    /// Streaming chat. Anthropic SSE events:
    ///   {"type":"message_start","message":{...,"usage":{...}}}
    ///   {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    ///   {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"..."}}
    ///   {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"...","name":"...","input":{}}}
    ///   {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"..."}}
    ///   {"type":"content_block_stop","index":0}
    ///   {"type":"message_delta","delta":{"stop_reason":"..."},"usage":{"output_tokens":...}}
    ///   {"type":"message_stop"}
    pub fn chatStream(
        impl: *anyopaque,
        alloc: std.mem.Allocator,
        messages: []const types.Message,
        opts: base.ChatOptions,
        cb: base.StreamCallback,
    ) anyerror!base.ChatResponse {
        const self: *AnthropicProvider = @ptrCast(@alignCast(impl));
        const model = if (opts.model.len > 0) opts.model else self.default_model;
        const url = try std.fmt.allocPrint(alloc, "{s}/v1/messages", .{self.base_url});
        defer alloc.free(url);

        // Build body with stream=true
        var stream_opts = opts;
        stream_opts.stream = true;
        const body = try buildRequestBody(alloc, messages, stream_opts, model);
        defer alloc.free(body);

        const auth_header = try std.fmt.allocPrint(alloc, "{s}", .{self.api_key});
        defer alloc.free(auth_header);
        const headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = auth_header },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "content-type", .value = "application/json" },
        };

        var acc = StreamAccumulator.init(alloc);
        defer acc.deinit();
        acc.cb = cb;

        const status = http.postJsonStream(alloc, url, &headers, body, &acc, StreamAccumulator.onEvent) catch |e| {
            return e;
        };
        if (status != 200) return mapStatus(status, "");

        // Emit final done delta
        try cb.run(cb.ctx, .{ .done = .{
            .finish_reason = acc.finish_reason,
            .usage = acc.usage,
        } });

        // Build the final ChatResponse from accumulated state
        return acc.toResponse(alloc);
    }

    pub fn provider(self: *AnthropicProvider) base.Provider {
        const vt = struct {
            const v = base.Provider.VTable{
                .chat = AnthropicProvider.chat,
                .chat_stream = AnthropicProvider.chatStream,
                .deinit = AnthropicProvider.deinit,
            };
        };
        return .{ .impl = self, .vtable = &vt.v };
    }
};

/// Accumulates Anthropic SSE deltas into a final ChatResponse. Also forwards
/// text/tool_call deltas to the user-provided callback.
const StreamAccumulator = struct {
    alloc: std.mem.Allocator,
    text: std.ArrayList(u8),
    tool_calls: std.ArrayList(types.ToolCall),
    /// Partial JSON arguments being built per tool_call index
    tool_args: std.AutoHashMap(usize, std.ArrayList(u8)),
    finish_reason: []const u8,
    usage: types.Usage,
    cb: base.StreamCallback,

    fn init(alloc: std.mem.Allocator) StreamAccumulator {
        return .{
            .alloc = alloc,
            .text = std.ArrayList(u8).init(alloc),
            .tool_calls = std.ArrayList(types.ToolCall).init(alloc),
            .tool_args = std.AutoHashMap(usize, std.ArrayList(u8)).init(alloc),
            .finish_reason = "stop",
            .usage = .{},
            // cb is set externally before use
            .cb = .{ .ctx = undefined, .run = undefined },
        };
    }

    fn deinit(self: *StreamAccumulator) void {
        self.text.deinit();
        for (self.tool_calls.items) |*tc| {
            self.alloc.free(tc.id);
            self.alloc.free(tc.name);
            self.alloc.free(tc.arguments_json);
        }
        self.tool_calls.deinit();
        var it = self.tool_args.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        self.tool_args.deinit();
    }

    fn onEvent(self: *StreamAccumulator, data: []const u8) anyerror!void {
        if (std.mem.eql(u8, data, "[DONE]")) return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        const type_v = obj.get("type") orelse return;
        if (type_v != .string) return;
        const t = type_v.string;

        if (std.mem.eql(u8, t, "content_block_start")) {
            const idx = if (obj.get("index")) |v| (if (v == .integer) @as(usize, @intCast(v.integer)) else 0) else 0;
            const cb_v = obj.get("content_block") orelse return;
            if (cb_v != .object) return;
            const block = cb_v.object;
            const bt = block.get("type") orelse return;
            if (bt != .string) return;
            if (std.mem.eql(u8, bt.string, "tool_use")) {
                const id = if (block.get("id")) |v| (if (v == .string) v.string else "") else "";
                const name = if (block.get("name")) |v| (if (v == .string) v.string else "") else "";
                try self.tool_calls.append(.{
                    .id = try self.alloc.dupe(u8, id),
                    .name = try self.alloc.dupe(u8, name),
                    .arguments_json = try self.alloc.dupe(u8, ""),
                });
                try self.tool_args.put(idx, std.ArrayList(u8).init(self.alloc));
            }
        } else if (std.mem.eql(u8, t, "content_block_delta")) {
            const idx = if (obj.get("index")) |v| (if (v == .integer) @as(usize, @intCast(v.integer)) else 0) else 0;
            const delta_v = obj.get("delta") orelse return;
            if (delta_v != .object) return;
            const delta = delta_v.object;
            const dt = delta.get("type") orelse return;
            if (dt != .string) return;
            if (std.mem.eql(u8, dt.string, "text_delta")) {
                const txt = if (delta.get("text")) |v| (if (v == .string) v.string else "") else "";
                try self.text.appendSlice(txt);
                // Forward to user callback
                if (self.cb.enabled) {
                    try self.cb.run(self.cb.ctx, .{ .text = txt });
                }
            } else if (std.mem.eql(u8, dt.string, "input_json_delta")) {
                const pj = if (delta.get("partial_json")) |v| (if (v == .string) v.string else "") else "";
                if (self.tool_args.getPtr(idx)) |buf| {
                    try buf.appendSlice(pj);
                }
                if (self.cb.enabled) {
                    try self.cb.run(self.cb.ctx, .{ .tool_call = .{
                        .index = idx,
                        .arguments_chunk = pj,
                    } });
                }
            }
        } else if (std.mem.eql(u8, t, "message_delta")) {
            if (obj.get("delta")) |d| {
                if (d == .object) {
                    if (d.object.get("stop_reason")) |sr| {
                        if (sr == .string) {
                            self.finish_reason = sr.string;
                        }
                    }
                }
            }
            if (obj.get("usage")) |u| {
                if (u == .object) {
                    if (u.object.get("output_tokens")) |v| if (v == .integer) {
                        self.usage.output_tokens = @intCast(v.integer);
                    };
                }
            }
        } else if (std.mem.eql(u8, t, "message_start")) {
            if (obj.get("message")) |m| {
                if (m == .object) {
                    if (m.object.get("usage")) |u| {
                        if (u == .object) {
                            if (u.object.get("input_tokens")) |v| if (v == .integer) {
                                self.usage.input_tokens = @intCast(v.integer);
                            };
                        }
                    }
                }
            }
        }
    }

    fn toResponse(self: *StreamAccumulator, alloc: std.mem.Allocator) !base.ChatResponse {
        // Finalize tool call arguments from accumulated buffers
        var i: usize = 0;
        var it = self.tool_args.iterator();
        while (it.next()) |e| {
            const idx = e.key_ptr.*;
            const buf = e.value_ptr.*;
            if (idx < self.tool_calls.items.len) {
                // Replace the empty arguments_json with the accumulated buffer
                alloc.free(self.tool_calls.items[idx].arguments_json);
                self.tool_calls.items[idx].arguments_json = try alloc.dupe(u8, buf.items);
            }
            i += 1;
        }

        // Build final tool_calls slice (dup since self owns it)
        const tc_dup = try alloc.alloc(types.ToolCall, self.tool_calls.items.len);
        for (self.tool_calls.items, 0..) |tc, j| {
            tc_dup[j] = .{
                .id = try alloc.dupe(u8, tc.id),
                .name = try alloc.dupe(u8, tc.name),
                .arguments_json = try alloc.dupe(u8, tc.arguments_json),
            };
        }

        return .{
            .message = .{
                .role = .assistant,
                .content = try alloc.dupe(u8, self.text.items),
                .tool_calls = tc_dup,
            },
            .finish_reason = try alloc.dupe(u8, self.finish_reason),
            .usage = self.usage,
            .alloc = alloc,
        };
    }
};

fn buildRequestBody(
    alloc: std.mem.Allocator,
    messages: []const types.Message,
    opts: base.ChatOptions,
    model: []const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    var w = buf.writer();

    try w.print("{{\"model\":\"{s}\",\"max_tokens\":{d},\"temperature\":{d:.2}", .{
        model, opts.max_tokens, opts.temperature,
    });

    if (opts.stream) {
        try w.print(",\"stream\":true", .{});
    }

    if (opts.system) |sys| {
        try w.print(",\"system\":\"", .{});
        try writeJsonStr(&w, sys);
        try w.print("\"", .{});
    }

    try w.print(",\"messages\":[", .{});
    for (messages, 0..) |m, i| {
        if (i > 0) try w.print(",", .{});
        try writeMessage(&w, m);
    }
    try w.print("]", .{});

    if (opts.tools.len > 0) {
        try w.print(",\"tools\":[", .{});
        for (opts.tools, 0..) |t, i| {
            if (i > 0) try w.print(",", .{});
            try w.print("{{\"name\":\"{s}\",\"description\":\"", .{t.name});
            try writeJsonStr(&w, t.description);
            try w.print("\",\"input_schema\":{s}}}", .{t.parameters_schema});
        }
        try w.print("]", .{});
    }

    try w.print("}}", .{});
    return try buf.toOwnedSlice();
}

fn writeMessage(w: anytype, m: types.Message) !void {
    const role_s = switch (m.role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "user",
    };
    try w.print("{{\"role\":\"{s}\",", .{role_s});

    if (m.role == .tool) {
        // Tool result → content block of type tool_result
        try w.print("\"content\":[{{\"type\":\"tool_result\",\"tool_use_id\":\"", .{});
        if (m.tool_call_id) |id| try writeJsonStr(w, id) else try w.print("unknown", .{});
        try w.print("\",\"content\":\"", .{});
        try writeJsonStr(w, m.content);
        try w.print("\"}}]", .{});
    } else if (m.tool_calls.len > 0) {
        // Assistant message with tool_use blocks
        try w.print("\"content\":[{{\"type\":\"text\",\"text\":\"", .{});
        try writeJsonStr(w, m.content);
        try w.print("\"}}", .{});
        for (m.tool_calls) |tc| {
            try w.print(",{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{s}}}", .{
                tc.id, tc.name, tc.arguments_json,
            });
        }
        try w.print("]", .{});
    } else {
        try w.print("\"content\":\"", .{});
        try writeJsonStr(w, m.content);
        try w.print("\"", .{});
    }
    try w.print("}}", .{});
}

fn parseResponse(alloc: std.mem.Allocator, body: []const u8) !base.ChatResponse {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const text = blk: {
        const content = obj.get("content") orelse break :blk "";
        if (content != .array) break :blk "";
        for (content.array.items) |item| {
            if (item != .object) continue;
            const t = item.object.get("type") orelse continue;
            if (t != .string) continue;
            if (std.mem.eql(u8, t.string, "text")) {
                const txt = item.object.get("text") orelse continue;
                if (txt == .string) break :blk txt.string;
            }
        }
        break :blk "";
    };

    // Collect tool_use blocks
    var tool_calls: std.ArrayList(types.ToolCall) = std.ArrayList(types.ToolCall).init(alloc);
    errdefer {
        for (tool_calls.items) |tc| {
            alloc.free(tc.id);
            alloc.free(tc.name);
            alloc.free(tc.arguments_json);
        }
        tool_calls.deinit();
    }
    if (obj.get("content")) |content| {
        if (content == .array) {
            for (content.array.items) |item| {
                if (item != .object) continue;
                const t = item.object.get("type") orelse continue;
                if (t != .string) continue;
                if (std.mem.eql(u8, t.string, "tool_use")) {
                    const id_v = item.object.get("id") orelse continue;
                    const name_v = item.object.get("name") orelse continue;
                    const input_v = item.object.get("input") orelse continue;
                    if (id_v != .string or name_v != .string) continue;
                    var input_buf = std.ArrayList(u8).init(alloc);
                    errdefer input_buf.deinit();
                    try std.json.stringify(input_v, .{}, input_buf.writer());
                    try tool_calls.append(.{
                        .id = try alloc.dupe(u8, id_v.string),
                        .name = try alloc.dupe(u8, name_v.string),
                        .arguments_json = try input_buf.toOwnedSlice(),
                    });
                }
            }
        }
    }

    var usage = types.Usage{};
    if (obj.get("usage")) |u| {
        if (u == .object) {
            if (u.object.get("input_tokens")) |v| if (v == .integer) {
                usage.input_tokens = @intCast(v.integer);
            };
            if (u.object.get("output_tokens")) |v| if (v == .integer) {
                usage.output_tokens = @intCast(v.integer);
            };
        }
    }

    const finish = if (obj.get("stop_reason")) |v| (if (v == .string) v.string else "stop") else "stop";

    return .{
        .message = .{
            .role = .assistant,
            .content = try alloc.dupe(u8, text),
            .tool_calls = try tool_calls.toOwnedSlice(),
        },
        .finish_reason = try alloc.dupe(u8, finish),
        .usage = usage,
        .alloc = alloc,
    };
}

fn mapStatus(status: u16, body: []const u8) anyerror {
    _ = body;
    return switch (status) {
        401, 403 => error.ProviderAuthError,
        429 => error.ProviderRateLimit,
        400 => error.ProviderBadRequest,
        else => error.ProviderHttpError,
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

test "buildRequestBody: minimal" {
    const alloc = std.testing.allocator;
    const msgs = [_]types.Message{.{ .role = .user, .content = "hi" }};
    const opts = base.ChatOptions{ .model = "claude-sonnet-4-5", .max_tokens = 100 };
    const body = try buildRequestBody(alloc, &msgs, opts, "claude-sonnet-4-5");
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude-sonnet-4-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"hi\"") != null);
}

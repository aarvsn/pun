// OpenAI Chat Completions adapter.
//
// POST https://api.openai.com/v1/chat/completions
// Headers: Authorization: Bearer <key>, content-type: application/json
//
// OpenAI-compat providers (Groq, Together, OpenRouter, Ollama, vLLM, ...)
// use the same wire format — they're handled by openai_compat.zig which
// just overrides the base_url.

const std = @import("std");
const base = @import("base.zig");
const http = @import("http.zig");
const types = @import("../types.zig");

const DEFAULT_BASE_URL = "https://api.openai.com";

pub const OpenAiProvider = struct {
    alloc: std.mem.Allocator,
    api_key: []u8,
    base_url: []u8,
    default_model: []u8,

    pub fn init(alloc: std.mem.Allocator, api_key: []const u8, base_url: ?[]const u8, default_model: []const u8) !*OpenAiProvider {
        const self = try alloc.create(OpenAiProvider);
        self.* = .{
            .alloc = alloc,
            .api_key = try alloc.dupe(u8, api_key),
            .base_url = try alloc.dupe(u8, base_url orelse DEFAULT_BASE_URL),
            .default_model = try alloc.dupe(u8, default_model),
        };
        return self;
    }

    pub fn deinit(impl: *anyopaque) void {
        const self: *OpenAiProvider = @ptrCast(@alignCast(impl));
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
        const self: *OpenAiProvider = @ptrCast(@alignCast(impl));
        const model = if (opts.model.len > 0) opts.model else self.default_model;
        const url = try std.fmt.allocPrint(alloc, "{s}/v1/chat/completions", .{self.base_url});
        defer alloc.free(url);

        const body = try buildRequestBody(alloc, messages, opts, model);
        defer alloc.free(body);

        const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.api_key});
        defer alloc.free(auth);
        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = auth },
            .{ .name = "content-type", .value = "application/json" },
        };

        var resp = try http.postJson(alloc, url, &headers, body);
        defer resp.deinit();
        if (resp.status != 200) {
            return mapStatus(resp.status);
        }
        return parseResponse(alloc, resp.body);
    }

    /// Streaming chat. OpenAI SSE events:
    ///   {"choices":[{"delta":{"content":"..."}}]}
    ///   {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"...","function":{"name":"...","arguments":"..."}}]}}]}
    ///   {"choices":[{"delta":{},"finish_reason":"stop"}]}
    ///   [DONE]
    pub fn chatStream(
        impl: *anyopaque,
        alloc: std.mem.Allocator,
        messages: []const types.Message,
        opts: base.ChatOptions,
        cb: base.StreamCallback,
    ) anyerror!base.ChatResponse {
        const self: *OpenAiProvider = @ptrCast(@alignCast(impl));
        const model = if (opts.model.len > 0) opts.model else self.default_model;
        const url = try std.fmt.allocPrint(alloc, "{s}/v1/chat/completions", .{self.base_url});
        defer alloc.free(url);

        var stream_opts = opts;
        stream_opts.stream = true;
        const body = try buildRequestBody(alloc, messages, stream_opts, model);
        defer alloc.free(body);

        const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.api_key});
        defer alloc.free(auth);
        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = auth },
            .{ .name = "content-type", .value = "application/json" },
        };

        var acc = StreamAccumulator.init(alloc);
        defer acc.deinit();
        acc.cb = cb;

        const status = http.postJsonStream(alloc, url, &headers, body, &acc, StreamAccumulator.onEvent) catch |e| return e;
        if (status != 200) return mapStatus(status);

        try cb.run(cb.ctx, .{ .done = .{
            .finish_reason = acc.finish_reason,
            .usage = acc.usage,
        } });
        return acc.toResponse(alloc);
    }

    pub fn provider(self: *OpenAiProvider) base.Provider {
        const vt = struct {
            const v = base.Provider.VTable{
                .chat = OpenAiProvider.chat,
                .chat_stream = OpenAiProvider.chatStream,
                .deinit = OpenAiProvider.deinit,
            };
        };
        return .{ .impl = self, .vtable = &vt.v };
    }
};

/// Accumulates OpenAI SSE deltas into a final ChatResponse.
pub const StreamAccumulator = struct {
    pub const ToolMeta = struct { id: []u8, name: []u8 };

    alloc: std.mem.Allocator,
    text: std.ArrayList(u8),
    /// Tool call args being built per index
    tool_args: std.AutoHashMap(usize, std.ArrayList(u8)),
    tool_meta: std.AutoHashMap(usize, ToolMeta),
    finish_reason: []const u8,
    usage: types.Usage,
    cb: base.StreamCallback,

    pub fn init(alloc: std.mem.Allocator) StreamAccumulator {
        return .{
            .alloc = alloc,
            .text = std.ArrayList(u8).init(alloc),
            .tool_args = std.AutoHashMap(usize, std.ArrayList(u8)).init(alloc),
            .tool_meta = std.AutoHashMap(usize, ToolMeta).init(alloc),
            .finish_reason = "stop",
            .usage = .{},
            .cb = .{ .ctx = undefined, .run = undefined },
        };
    }

    pub fn deinit(self: *StreamAccumulator) void {
        self.text.deinit();
        var it = self.tool_args.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        self.tool_args.deinit();
        var mit = self.tool_meta.iterator();
        while (mit.next()) |e| {
            self.alloc.free(e.value_ptr.id);
            self.alloc.free(e.value_ptr.name);
        }
        self.tool_meta.deinit();
    }

    pub fn onEvent(self: *StreamAccumulator, data: []const u8) anyerror!void {
        if (std.mem.eql(u8, data, "[DONE]")) return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const root = parsed.value.object;

        const choices = root.get("choices") orelse return;
        if (choices != .array or choices.array.items.len == 0) return;
        const choice = choices.array.items[0].object;

        if (choice.get("delta")) |delta_v| {
            if (delta_v == .object) {
                const delta = delta_v.object;
                if (delta.get("content")) |c| {
                    if (c == .string and c.string.len > 0) {
                        try self.text.appendSlice(c.string);
                        if (self.cb.enabled) {
                            try self.cb.run(self.cb.ctx, .{ .text = c.string });
                        }
                    }
                }
                if (delta.get("tool_calls")) |tc_arr| {
                    if (tc_arr == .array) {
                        for (tc_arr.array.items) |tc_v| {
                            if (tc_v != .object) continue;
                            const tc = tc_v.object;
                            const idx_v = tc.get("index") orelse continue;
                            if (idx_v != .integer) continue;
                            const idx: usize = @intCast(idx_v.integer);

                            if (tc.get("id")) |id_v| {
                                if (id_v == .string) {
                                    if (tc.get("function")) |fn_v| {
                                        if (fn_v == .object) {
                                            if (fn_v.object.get("name")) |name_v| {
                                                if (name_v == .string) {
                                                    // Store meta
                                                    if (self.tool_meta.getPtr(idx)) |old| {
                                                        self.alloc.free(old.id);
                                                        self.alloc.free(old.name);
                                                    }
                                                    try self.tool_meta.put(idx, .{
                                                        .id = try self.alloc.dupe(u8, id_v.string),
                                                        .name = try self.alloc.dupe(u8, name_v.string),
                                                    });
                                                    if (!self.tool_args.contains(idx)) {
                                                        try self.tool_args.put(idx, std.ArrayList(u8).init(self.alloc));
                                                    }
                                                    if (self.cb.enabled) {
                                                        try self.cb.run(self.cb.ctx, .{ .tool_call = .{
                                                            .index = idx,
                                                            .id = id_v.string,
                                                            .name = name_v.string,
                                                        } });
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            if (tc.get("function")) |fn_v| {
                                if (fn_v == .object) {
                                    if (fn_v.object.get("arguments")) |args_v| {
                                        if (args_v == .string and args_v.string.len > 0) {
                                            if (self.tool_args.getPtr(idx)) |buf| {
                                                try buf.appendSlice(args_v.string);
                                            }
                                            if (self.cb.enabled) {
                                                try self.cb.run(self.cb.ctx, .{ .tool_call = .{
                                                    .index = idx,
                                                    .arguments_chunk = args_v.string,
                                                } });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (choice.get("finish_reason")) |fr| {
            if (fr == .string) {
                self.finish_reason = fr.string;
            }
        }
        if (root.get("usage")) |u| {
            if (u == .object) {
                if (u.object.get("prompt_tokens")) |v| if (v == .integer) {
                    self.usage.input_tokens = @intCast(v.integer);
                };
                if (u.object.get("completion_tokens")) |v| if (v == .integer) {
                    self.usage.output_tokens = @intCast(v.integer);
                };
            }
        }
    }

    pub fn toResponse(self: *StreamAccumulator, alloc: std.mem.Allocator) !base.ChatResponse {
        // Build tool_calls slice from tool_meta + tool_args, sorted by index
        const tool_calls = try alloc.alloc(types.ToolCall, self.tool_meta.count());
        errdefer alloc.free(tool_calls);

        var idx_slice = try alloc.alloc(usize, self.tool_meta.count());
        defer alloc.free(idx_slice);
        var i: usize = 0;
        var mit = self.tool_meta.iterator();
        while (mit.next()) |e| {
            idx_slice[i] = e.key_ptr.*;
            i += 1;
        }
        std.mem.sort(usize, idx_slice, {}, std.sort.asc(usize));

        for (idx_slice, 0..) |idx, j| {
            const meta = self.tool_meta.get(idx).?;
            const args_buf = self.tool_args.get(idx) orelse std.ArrayList(u8).init(alloc);
            tool_calls[j] = .{
                .id = try alloc.dupe(u8, meta.id),
                .name = try alloc.dupe(u8, meta.name),
                .arguments_json = try alloc.dupe(u8, args_buf.items),
            };
        }

        return .{
            .message = .{
                .role = .assistant,
                .content = try alloc.dupe(u8, self.text.items),
                .tool_calls = tool_calls,
            },
            .finish_reason = try alloc.dupe(u8, self.finish_reason),
            .usage = self.usage,
            .alloc = alloc,
        };
    }
};

/// Shared streaming chat for OpenAI-compat providers (Groq, Ollama, GLM,
/// DeepSeek, Mistral, xAI). All of them speak the OpenAI SSE wire format.
pub fn chatStreamOpenAiCompat(
    alloc: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    messages: []const types.Message,
    opts: base.ChatOptions,
    cb: base.StreamCallback,
) !base.ChatResponse {
    const model = opts.model;
    const url = try std.fmt.allocPrint(alloc, "{s}/v1/chat/completions", .{base_url});
    defer alloc.free(url);

    var stream_opts = opts;
    stream_opts.stream = true;
    const body = try buildRequestBody(alloc, messages, stream_opts, model);
    defer alloc.free(body);

    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key});
    defer alloc.free(auth);
    const headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth },
        .{ .name = "content-type", .value = "application/json" },
    };

    var acc = StreamAccumulator.init(alloc);
    defer acc.deinit();
    acc.cb = cb;

    const status = http.postJsonStream(alloc, url, &headers, body, &acc, StreamAccumulator.onEvent) catch |e| return e;
    if (status != 200) return mapStatus(status);

    try cb.run(cb.ctx, .{ .done = .{
        .finish_reason = acc.finish_reason,
        .usage = acc.usage,
    } });
    return acc.toResponse(alloc);
}

/// Shared body builder — also used by openai_compat.zig.
pub fn buildRequestBody(
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

    try w.print(",\"messages\":[", .{});

    if (opts.system) |sys| {
        try w.print("{{\"role\":\"system\",\"content\":\"", .{});
        try writeJsonStr(&w, sys);
        try w.print("\"}},", .{});
    }

    for (messages, 0..) |m, i| {
        if (i > 0) try w.print(",", .{});
        try writeMessage(&w, m);
    }
    try w.print("]", .{});

    if (opts.tools.len > 0) {
        try w.print(",\"tools\":[", .{});
        for (opts.tools, 0..) |t, i| {
            if (i > 0) try w.print(",", .{});
            try w.print("{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"", .{t.name});
            try writeJsonStr(&w, t.description);
            try w.print("\",\"parameters\":{s}}}}}", .{t.parameters_schema});
        }
        try w.print("]", .{});
    }

    try w.print("}}", .{});
    return try buf.toOwnedSlice();
}

fn writeMessage(w: anytype, m: types.Message) !void {
    if (m.role == .tool) {
        try w.print("{{\"role\":\"tool\",\"tool_call_id\":\"{s}\",\"content\":\"", .{m.tool_call_id orelse "unknown"});
        try writeJsonStr(w, m.content);
        try w.print("\"}}", .{});
        return;
    }
    const role_s = switch (m.role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "user",
    };
    try w.print("{{\"role\":\"{s}\",", .{role_s});
    if (m.tool_calls.len > 0) {
        try w.print("\"content\":\"", .{});
        try writeJsonStr(w, m.content);
        try w.print("\",\"tool_calls\":[", .{});
        for (m.tool_calls, 0..) |tc, i| {
            if (i > 0) try w.print(",", .{});
            try w.print("{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":", .{
                tc.id, tc.name,
            });
            // arguments_json is already JSON; embed as-is
            try w.print("{s}", .{tc.arguments_json});
            try w.print("}}}}", .{});
        }
        try w.print("]", .{});
    } else {
        try w.print("\"content\":\"", .{});
        try writeJsonStr(w, m.content);
        try w.print("\"", .{});
    }
    try w.print("}}", .{});
}

/// Shared response parser — also used by openai_compat.zig.
pub fn parseResponse(alloc: std.mem.Allocator, body: []const u8) !base.ChatResponse {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const choices = root.get("choices") orelse return error.ProviderError;
    if (choices != .array or choices.array.items.len == 0) return error.ProviderError;
    const choice = choices.array.items[0].object;
    const msg = choice.get("message") orelse return error.ProviderError;
    const msg_obj = msg.object;

    const text = if (msg_obj.get("content")) |c| (if (c == .string) c.string else "") else "";

    var tool_calls: std.ArrayList(types.ToolCall) = std.ArrayList(types.ToolCall).init(alloc);
    errdefer {
        for (tool_calls.items) |tc| {
            alloc.free(tc.id);
            alloc.free(tc.name);
            alloc.free(tc.arguments_json);
        }
        tool_calls.deinit();
    }
    if (msg_obj.get("tool_calls")) |tc_arr| {
        if (tc_arr == .array) {
            for (tc_arr.array.items) |item| {
                if (item != .object) continue;
                const id = item.object.get("id") orelse continue;
                const fn_obj_v = item.object.get("function") orelse continue;
                if (id != .string or fn_obj_v != .object) continue;
                const name = fn_obj_v.object.get("name") orelse continue;
                const args = fn_obj_v.object.get("arguments") orelse continue;
                if (name != .string) continue;
                const args_s = if (args == .string) args.string else "";
                try tool_calls.append(.{
                    .id = try alloc.dupe(u8, id.string),
                    .name = try alloc.dupe(u8, name.string),
                    .arguments_json = try alloc.dupe(u8, args_s),
                });
            }
        }
    }

    var usage = types.Usage{};
    if (root.get("usage")) |u| {
        if (u == .object) {
            if (u.object.get("prompt_tokens")) |v| if (v == .integer) {
                usage.input_tokens = @intCast(v.integer);
            };
            if (u.object.get("completion_tokens")) |v| if (v == .integer) {
                usage.output_tokens = @intCast(v.integer);
            };
        }
    }

    const finish = if (choice.get("finish_reason")) |v| (if (v == .string) v.string else "stop") else "stop";

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

pub fn mapStatus(status: u16) anyerror {
    return switch (status) {
        401, 403 => error.ProviderAuthError,
        429 => error.ProviderRateLimit,
        400 => error.ProviderBadRequest,
        else => error.ProviderHttpError,
    };
}

pub fn writeJsonStr(w: anytype, s: []const u8) !void {
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

test "buildRequestBody: with system" {
    const alloc = std.testing.allocator;
    const msgs = [_]types.Message{.{ .role = .user, .content = "hi" }};
    const opts = base.ChatOptions{ .model = "gpt-4.1", .system = "be brief", .max_tokens = 100 };
    const body = try buildRequestBody(alloc, &msgs, opts, "gpt-4.1");
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
}

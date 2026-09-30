// Google Gemini adapter.
//
// POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent?key=<key>
// Body: { contents: [...], systemInstruction: {...}, tools: [...], generationConfig: {...} }

const std = @import("std");
const base = @import("base.zig");
const http = @import("http.zig");
const types = @import("../types.zig");

const DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com";

pub const GoogleProvider = struct {
    alloc: std.mem.Allocator,
    api_key: []u8,
    base_url: []u8,
    default_model: []u8,

    pub fn init(alloc: std.mem.Allocator, api_key: []const u8, base_url: ?[]const u8, default_model: []const u8) !*GoogleProvider {
        const self = try alloc.create(GoogleProvider);
        self.* = .{
            .alloc = alloc,
            .api_key = try alloc.dupe(u8, api_key),
            .base_url = try alloc.dupe(u8, base_url orelse DEFAULT_BASE_URL),
            .default_model = try alloc.dupe(u8, default_model),
        };
        return self;
    }

    pub fn deinit(impl: *anyopaque) void {
        const self: *GoogleProvider = @ptrCast(@alignCast(impl));
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
        const self: *GoogleProvider = @ptrCast(@alignCast(impl));
        const model = if (opts.model.len > 0) opts.model else self.default_model;
        const url = try std.fmt.allocPrint(alloc, "{s}/v1beta/models/{s}:generateContent?key={s}", .{
            self.base_url, model, self.api_key,
        });
        defer alloc.free(url);

        const body = try buildRequestBody(alloc, messages, opts);
        defer alloc.free(body);

        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        var resp = try http.postJson(alloc, url, &headers, body);
        defer resp.deinit();
        if (resp.status != 200) {
            return switch (resp.status) {
                401, 403 => error.ProviderAuthError,
                429 => error.ProviderRateLimit,
                400 => error.ProviderBadRequest,
                else => error.ProviderHttpError,
            };
        }
        return parseResponse(alloc, resp.body);
    }

    /// Streaming chat for Google Gemini.
    /// Uses streamGenerateContent?alt=sse which emits SSE data: lines,
    /// each containing a chunk of the response.
    pub fn chatStream(
        impl: *anyopaque,
        alloc: std.mem.Allocator,
        messages: []const types.Message,
        opts: base.ChatOptions,
        cb: base.StreamCallback,
    ) anyerror!base.ChatResponse {
        const self: *GoogleProvider = @ptrCast(@alignCast(impl));
        const model = if (opts.model.len > 0) opts.model else self.default_model;
        const url = try std.fmt.allocPrint(alloc, "{s}/v1beta/models/{s}:streamGenerateContent?alt=sse&key={s}", .{
            self.base_url, model, self.api_key,
        });
        defer alloc.free(url);

        const body = try buildRequestBody(alloc, messages, opts);
        defer alloc.free(body);

        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        var acc = StreamAccumulator.init(alloc);
        defer acc.deinit();
        acc.cb = cb;

        const status = http.postJsonStream(alloc, url, &headers, body, &acc, StreamAccumulator.onEvent) catch |e| return e;
        if (status != 200) {
            return switch (status) {
                401, 403 => error.ProviderAuthError,
                429 => error.ProviderRateLimit,
                400 => error.ProviderBadRequest,
                else => error.ProviderHttpError,
            };
        }

        try cb.run(cb.ctx, .{ .done = .{
            .finish_reason = acc.finish_reason,
            .usage = acc.usage,
        } });
        return acc.toResponse(alloc);
    }

    pub fn provider(self: *GoogleProvider) base.Provider {
        const vt = struct {
            const v = base.Provider.VTable{
                .chat = GoogleProvider.chat,
                .chat_stream = GoogleProvider.chatStream,
                .deinit = GoogleProvider.deinit,
            };
        };
        return .{ .impl = self, .vtable = &vt.v };
    }
};

fn buildRequestBody(alloc: std.mem.Allocator, messages: []const types.Message, opts: base.ChatOptions) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    var w = buf.writer();

    try w.print("{{\"contents\":[", .{});
    var first = true;
    for (messages) |m| {
        if (m.role == .system) continue;
        if (!first) try w.print(",", .{});
        first = false;
        const role = if (m.role == .assistant) "model" else "user";
        try w.print("{{\"role\":\"{s}\",\"parts\":[{{\"text\":\"", .{role});
        try writeJsonStr(&w, m.content);
        try w.print("\"}}]", .{});
        // Tool call / tool result encoding omitted for v0.1 simplicity
        try w.print("}}", .{});
    }
    try w.print("]", .{});

    if (opts.system) |sys| {
        try w.print(",\"systemInstruction\":{{\"parts\":[{{\"text\":\"", .{});
        try writeJsonStr(&w, sys);
        try w.print("\"}}]}}", .{});
    }

    try w.print(",\"generationConfig\":{{\"temperature\":{d:.2},\"maxOutputTokens\":{d}}}", .{
        opts.temperature, opts.max_tokens,
    });

    if (opts.tools.len > 0) {
        try w.print(",\"tools\":[{{\"functionDeclarations\":[", .{});
        for (opts.tools, 0..) |t, i| {
            if (i > 0) try w.print(",", .{});
            try w.print("{{\"name\":\"{s}\",\"description\":\"", .{t.name});
            try writeJsonStr(&w, t.description);
            try w.print("\",\"parameters\":{s}}}", .{t.parameters_schema});
        }
        try w.print("]}}]", .{});
    }

    try w.print("}}", .{});
    return try buf.toOwnedSlice();
}

fn parseResponse(alloc: std.mem.Allocator, body: []const u8) !base.ChatResponse {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    var text_buf = std.ArrayList(u8).init(alloc);
    errdefer text_buf.deinit();

    if (root.get("candidates")) |cands| {
        if (cands == .array and cands.array.items.len > 0) {
            const cand = cands.array.items[0].object;
            if (cand.get("content")) |content| {
                if (content == .object) {
                    if (content.object.get("parts")) |parts| {
                        if (parts == .array) {
                            for (parts.array.items) |part| {
                                if (part != .object) continue;
                                if (part.object.get("text")) |t| {
                                    if (t == .string) try text_buf.appendSlice(t.string);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    var usage = types.Usage{};
    if (root.get("usageMetadata")) |u| {
        if (u == .object) {
            if (u.object.get("promptTokenCount")) |v| if (v == .integer) {
                usage.input_tokens = @intCast(v.integer);
            };
            if (u.object.get("candidatesTokenCount")) |v| if (v == .integer) {
                usage.output_tokens = @intCast(v.integer);
            };
        }
    }

    return .{
        .message = .{
            .role = .assistant,
            .content = try text_buf.toOwnedSlice(),
        },
        .finish_reason = try alloc.dupe(u8, "stop"),
        .usage = usage,
        .alloc = alloc,
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

/// Accumulates Google Gemini SSE deltas into a final ChatResponse.
/// Each SSE event is a JSON object of the same shape as the non-streaming
/// response (candidates[].content.parts[].text + usageMetadata).
const StreamAccumulator = struct {
    alloc: std.mem.Allocator,
    text: std.ArrayList(u8),
    finish_reason: []const u8,
    usage: types.Usage,
    cb: base.StreamCallback,

    fn init(alloc: std.mem.Allocator) StreamAccumulator {
        return .{
            .alloc = alloc,
            .text = std.ArrayList(u8).init(alloc),
            .finish_reason = "stop",
            .usage = .{},
            .cb = .{ .ctx = undefined, .run = undefined },
        };
    }

    fn deinit(self: *StreamAccumulator) void {
        self.text.deinit();
    }

    fn onEvent(self: *StreamAccumulator, data: []const u8) anyerror!void {
        if (std.mem.eql(u8, data, "[DONE]")) return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const root = parsed.value.object;

        if (root.get("candidates")) |cands| {
            if (cands == .array and cands.array.items.len > 0) {
                const cand = cands.array.items[0].object;
                if (cand.get("content")) |content| {
                    if (content == .object) {
                        if (content.object.get("parts")) |parts| {
                            if (parts == .array) {
                                for (parts.array.items) |part| {
                                    if (part != .object) continue;
                                    if (part.object.get("text")) |t| {
                                        if (t == .string and t.string.len > 0) {
                                            try self.text.appendSlice(t.string);
                                            if (self.cb.enabled) {
                                                try self.cb.run(self.cb.ctx, .{ .text = t.string });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if (cand.get("finishReason")) |fr| {
                    if (fr == .string) self.finish_reason = fr.string;
                }
            }
        }
        if (root.get("usageMetadata")) |u| {
            if (u == .object) {
                if (u.object.get("promptTokenCount")) |v| if (v == .integer) {
                    self.usage.input_tokens = @intCast(v.integer);
                };
                if (u.object.get("candidatesTokenCount")) |v| if (v == .integer) {
                    self.usage.output_tokens = @intCast(v.integer);
                };
            }
        }
    }

    fn toResponse(self: *StreamAccumulator, alloc: std.mem.Allocator) !base.ChatResponse {
        return .{
            .message = .{
                .role = .assistant,
                .content = try alloc.dupe(u8, self.text.items),
            },
            .finish_reason = try alloc.dupe(u8, self.finish_reason),
            .usage = self.usage,
            .alloc = alloc,
        };
    }
};

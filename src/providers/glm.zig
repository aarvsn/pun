// Z.ai GLM adapter — OpenAI-compatible.
// Base: https://open.bigmodel.cn/api/paas/v4

const std = @import("std");
const base = @import("base.zig");
const http = @import("http.zig");
const types = @import("../types.zig");
const openai = @import("openai.zig");

const DEFAULT_BASE_URL = "https://open.bigmodel.cn/api/paas/v4";

pub const GlmProvider = struct {
    alloc: std.mem.Allocator,
    api_key: []u8,
    base_url: []u8,
    default_model: []u8,

    pub fn init(alloc: std.mem.Allocator, api_key: []const u8, base_url: ?[]const u8, default_model: []const u8) !*GlmProvider {
        const self = try alloc.create(GlmProvider);
        self.* = .{
            .alloc = alloc,
            .api_key = try alloc.dupe(u8, api_key),
            .base_url = try alloc.dupe(u8, base_url orelse DEFAULT_BASE_URL),
            .default_model = try alloc.dupe(u8, default_model),
        };
        return self;
    }

    pub fn deinit(impl: *anyopaque) void {
        const self: *GlmProvider = @ptrCast(@alignCast(impl));
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
        const self: *GlmProvider = @ptrCast(@alignCast(impl));
        const model = if (opts.model.len > 0) opts.model else self.default_model;
        const url = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{self.base_url});
        defer alloc.free(url);

        const body = try openai.buildRequestBody(alloc, messages, opts, model);
        defer alloc.free(body);

        const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.api_key});
        defer alloc.free(auth);
        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = auth },
            .{ .name = "content-type", .value = "application/json" },
        };

        var resp = try http.postJson(alloc, url, &headers, body);
        defer resp.deinit();
        if (resp.status != 200) return openai.mapStatus(resp.status);
        return openai.parseResponse(alloc, resp.body);
    }

    pub fn chatStream(
        impl: *anyopaque,
        alloc: std.mem.Allocator,
        messages: []const types.Message,
        opts: base.ChatOptions,
        cb: base.StreamCallback,
    ) anyerror!base.ChatResponse {
        const self: *GlmProvider = @ptrCast(@alignCast(impl));
        const model = if (opts.model.len > 0) opts.model else self.default_model;
        // GLM uses a different path: /chat/completions (no /v1 prefix)
        const url = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{self.base_url});
        defer alloc.free(url);
        var stream_opts = opts;
        stream_opts.stream = true;
        stream_opts.model = model;
        const body = try openai.buildRequestBody(alloc, messages, stream_opts, model);
        defer alloc.free(body);
        const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.api_key});
        defer alloc.free(auth);
        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = auth },
            .{ .name = "content-type", .value = "application/json" },
        };
        // Reuse OpenAI accumulator
        const OpenAiAcc = @import("openai.zig").StreamAccumulator;
        var acc = OpenAiAcc.init(alloc);
        defer acc.deinit();
        acc.cb = cb;
        const status = http.postJsonStream(alloc, url, &headers, body, &acc, OpenAiAcc.onEvent) catch |e| return e;
        if (status != 200) return openai.mapStatus(status);
        try cb.run(cb.ctx, .{ .done = .{ .finish_reason = acc.finish_reason, .usage = acc.usage } });
        return acc.toResponse(alloc);
    }

    pub fn provider(self: *GlmProvider) base.Provider {
        const vt = struct {
            const v = base.Provider.VTable{
                .chat = GlmProvider.chat,
                .chat_stream = GlmProvider.chatStream,
                .deinit = GlmProvider.deinit,
            };
        };
        return .{ .impl = self, .vtable = &vt.v };
    }
};

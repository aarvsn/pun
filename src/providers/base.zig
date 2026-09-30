// Provider interface + shared types.

const std = @import("std");
const types = @import("../types.zig");

pub const ChatOptions = struct {
    model: []const u8,
    temperature: f32 = 0.3,
    max_tokens: u32 = 4096,
    /// JSON-schema-as-string for each available tool. Empty = no tools.
    tools: []const ToolSpec = &.{},
    /// Optional system prompt (some providers want this as a separate field).
    system: ?[]const u8 = null,
    /// If true, request streaming.
    stream: bool = false,
};

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema: []const u8, // JSON
};

pub const ChatResponse = struct {
    message: types.Message,
    finish_reason: []u8,
    usage: types.Usage,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *ChatResponse) void {
        self.message.deinit(self.alloc);
        self.alloc.free(self.finish_reason);
    }
};

/// One streaming delta. `text` is appended to the running output.
/// `tool_call_index` + `tool_call_delta` incrementally build tool calls.
/// `done` is sent once at the end with the final usage + finish reason.
pub const StreamDelta = union(enum) {
    text: []const u8,
    tool_call: struct {
        index: usize,
        /// Id of the tool call (only present on the first delta for this index)
        id: ?[]const u8 = null,
        /// Name of the tool (only present on the first delta for this index)
        name: ?[]const u8 = null,
        /// Partial JSON arguments to append
        arguments_chunk: ?[]const u8 = null,
    },
    done: struct {
        finish_reason: []const u8,
        usage: types.Usage,
    },
};

/// Streaming callback context. The callback receives owned `delta` slices
/// (caller must free `delta.text` / `delta.tool_call.*` if keeping them).
pub const StreamCallback = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, delta: StreamDelta) anyerror!void,
    /// Set to false to suppress forwarding (used by accumulators when no
    /// user callback is provided).
    enabled: bool = true,
};

pub const Provider = struct {
    impl: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        chat: *const fn (impl: *anyopaque, alloc: std.mem.Allocator, messages: []const types.Message, opts: ChatOptions) anyerror!ChatResponse,
        chat_stream: *const fn (impl: *anyopaque, alloc: std.mem.Allocator, messages: []const types.Message, opts: ChatOptions, cb: StreamCallback) anyerror!ChatResponse,
        deinit: *const fn (impl: *anyopaque) void,
    };

    pub fn chat(self: *Provider, alloc: std.mem.Allocator, messages: []const types.Message, opts: ChatOptions) !ChatResponse {
        return self.vtable.chat(self.impl, alloc, messages, opts);
    }

    /// Streaming chat. Calls `cb.run(cb.ctx, delta)` for each chunk, then
    /// returns the final assembled ChatResponse. The final response owns
    /// its memory; delta slices passed to the callback are NOT owned by the
    /// callback (they're valid only during the call).
    pub fn chatStream(self: *Provider, alloc: std.mem.Allocator, messages: []const types.Message, opts: ChatOptions, cb: StreamCallback) !ChatResponse {
        return self.vtable.chat_stream(self.impl, alloc, messages, opts, cb);
    }

    pub fn deinit(self: *Provider) void {
        self.vtable.deinit(self.impl);
    }
};

/// Helper: free a slice of messages.
pub fn freeMessages(alloc: std.mem.Allocator, messages: []types.Message) void {
    for (messages) |*m| m.deinit(alloc);
    alloc.free(messages);
}

// Core type aliases used across pun.

const std = @import("std");

/// A chat message in the unified internal format. Provider adapters convert
/// to/from this. `tool_calls` and `tool_call_id` are only populated when
/// role == .assistant or .tool respectively.
pub const Role = enum { system, user, assistant, tool };

pub const ToolCall = struct {
    id: []const u8, // provider-issued id (e.g. "call_abc")
    name: []const u8,
    arguments_json: []const u8, // raw JSON string as emitted by the model
};

pub const Message = struct {
    role: Role,
    content: []const u8, // plain text; for tool results, the tool output
    tool_calls: []const ToolCall = &.{},
    tool_call_id: ?[]const u8 = null, // for role==.tool
    name: ?[]const u8 = null, // tool name for role==.tool

    pub fn deinit(self: *Message, alloc: std.mem.Allocator) void {
        alloc.free(self.content);
        for (self.tool_calls) |tc| {
            alloc.free(tc.id);
            alloc.free(tc.name);
            alloc.free(tc.arguments_json);
        }
        if (self.tool_calls.len > 0) alloc.free(self.tool_calls);
        if (self.tool_call_id) |s| alloc.free(s);
        if (self.name) |s| alloc.free(s);
    }
};

/// A tool the model can call. Implemented by tools/* and registered in tools/mod.zig.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON-schema-as-string for the parameters object. Sent to the model.
    parameters_schema: []const u8,
    /// Function pointer to the implementation.
    run: *const fn (
        alloc: std.mem.Allocator,
        ctx: *anyopaque,
        arguments: std.json.Parsed(std.json.Value),
    ) anyerror!ToolResult,
    /// Context pointer passed to `run`.
    ctx: *anyopaque,
};

pub const ToolResult = struct {
    /// Free-form text fed back to the model as the tool result.
    content: []u8,
    /// True if the tool errored; the model will see the error string in `content`.
    is_error: bool = false,
    /// Optional structured metadata for the audit log.
    meta: ?[]u8 = null,
    /// Optional structured content blocks (v0.7 MCP content types).
    /// If non-empty, the MCP server sends these instead of a single text block.
    /// Each block is either text, image (base64 data URL), or resource (URI).
    blocks: ?[]ContentBlock = null,

    pub fn deinit(self: *ToolResult, alloc: std.mem.Allocator) void {
        alloc.free(self.content);
        if (self.meta) |m| alloc.free(m);
        if (self.blocks) |bs| {
            for (bs) |*b| b.deinit(alloc);
            alloc.free(bs);
        }
    }
};

/// MCP content block (v0.7). Tools can return structured output with
/// multiple content types: text, image, or resource reference.
pub const ContentBlock = union(enum) {
    text: []u8,
    image: struct {
        data: []u8, // base64-encoded
        mime_type: []u8,
    },
    resource: struct {
        uri: []u8,
        mime_type: []u8,
    },

    pub fn deinit(self: *ContentBlock, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .text => |t| alloc.free(t),
            .image => |img| {
                alloc.free(img.data);
                alloc.free(img.mime_type);
            },
            .resource => |r| {
                alloc.free(r.uri);
                alloc.free(r.mime_type);
            },
        }
    }

    /// Serialize as MCP content block JSON: {"type":"text","text":"..."} etc.
    pub fn toJson(self: ContentBlock, buf: *std.ArrayList(u8)) !void {
        switch (self) {
            .text => |t| {
                try buf.appendSlice("{\"type\":\"text\",\"text\":");
                try writeJsonStr(buf, t);
                try buf.append('}');
            },
            .image => |img| {
                try buf.appendSlice("{\"type\":\"image\",\"data\":\"");
                try buf.appendSlice(img.data);
                try buf.appendSlice("\",\"mimeType\":\"");
                try buf.appendSlice(img.mime_type);
                try buf.appendSlice("\"}");
            },
            .resource => |r| {
                try buf.appendSlice("{\"type\":\"resource\",\"uri\":\"");
                try buf.appendSlice(r.uri);
                try buf.appendSlice("\",\"mimeType\":\"");
                try buf.appendSlice(r.mime_type);
                try buf.appendSlice("\"}");
            },
        }
    }
};

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

/// One LLM response chunk during streaming.
pub const StreamDelta = union(enum) {
    text: []const u8,
    tool_call: ToolCall,
    done: struct {
        finish_reason: []const u8,
        usage: Usage,
    },
};

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
};

/// One entry in the audit log.
pub const AuditEntry = struct {
    ts_ms: i64,
    kind: enum {
        model_request,
        model_response,
        tool_call,
        tool_result,
        shell_exec,
        file_write,
        network_fetch,
        vault_access,
        confirmation_granted,
        confirmation_denied,
        injection_blocked,
        budget_warning,
        budget_exceeded,
    },
    summary: []const u8,
    payload_json: ?[]const u8 = null,
};

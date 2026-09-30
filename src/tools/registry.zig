// Tool registry + shared context.
//
// The ToolContext is passed to every tool's run() function and gives tools
// access to the allocator, the security policy, the audit log, and the
// workspace path.

const std = @import("std");
const types = @import("../types.zig");
const config = @import("../config/schema.zig");
const security = @import("../security/mod.zig");
const providers = @import("../providers/mod.zig");
const base = @import("../providers/base.zig");

pub const ToolContext = struct {
    alloc: std.mem.Allocator,
    cfg: *config.Config,
    policy: *security.SecurityPolicy,
    /// Provider for sub-agent delegation (may be null in pure tool tests).
    provider: ?*providers.Provider = null,
    /// Workspace absolute path (jail root).
    workspace: []const u8,
    /// Optional streaming callback for tools that want to forward deltas.
    stream_cb: ?*const base.StreamCallback = null,
};

pub const Registry = struct {
    tools: std.ArrayList(types.Tool),

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .tools = std.ArrayList(types.Tool).init(alloc) };
    }

    pub fn deinit(self: *Registry) void {
        self.tools.deinit();
    }

    pub fn add(self: *Registry, t: types.Tool) !void {
        try self.tools.append(t);
    }

    pub fn find(self: *Registry, name: []const u8) ?*const types.Tool {
        for (self.tools.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    /// Run the named tool with `arguments_json`. Returns owned ToolResult.
    pub fn run(
        self: *Registry,
        alloc: std.mem.Allocator,
        ctx: *ToolContext,
        name: []const u8,
        arguments_json: []const u8,
    ) !types.ToolResult {
        const t = self.find(name) orelse return error.ToolError;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch {
            return types.ToolResult{
                .content = try alloc.dupe(u8, "invalid JSON arguments"),
                .is_error = true,
            };
        };
        defer parsed.deinit();
        return t.run(alloc, ctx, parsed);
    }

    /// Build a JSON array of tool specs for the provider.
    pub fn specsJson(self: *Registry, alloc: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(alloc);
        errdefer buf.deinit();
        try buf.append('[');
        for (self.tools.items, 0..) |t, i| {
            if (i > 0) try buf.append(',');
            try buf.appendSlice("{\"name\":\"");
            try buf.appendSlice(t.name);
            try buf.appendSlice("\",\"description\":\"");
            try writeJsonStr(&buf, t.description);
            try buf.appendSlice("\",\"parameters\":");
            try buf.appendSlice(t.parameters_schema);
            try buf.append('}');
        }
        try buf.append(']');
        return try buf.toOwnedSlice();
    }
};

fn writeJsonStr(buf: *std.ArrayList(u8), s: []const u8) !void {
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
}

/// Register all enabled built-in tools. Call after constructing the registry.
pub fn registerAll(reg: *Registry, ctx: *ToolContext) !void {
    try @import("file.zig").registerAll(reg, ctx);
    try @import("shell.zig").registerAll(reg, ctx);
    try @import("web.zig").registerAll(reg, ctx);
    try @import("code.zig").registerAll(reg, ctx);
    try @import("git.zig").registerAll(reg, ctx);
    try @import("todo.zig").registerAll(reg, ctx);
    try @import("subagent.zig").registerAll(reg, ctx);
    try @import("browser.zig").registerAll(reg, ctx);
    try @import("memory.zig").registerAll(reg, ctx);
    try @import("orchestration.zig").registerAll(reg, ctx);
    try @import("watcher.zig").registerAll(reg, ctx);
    @import("plugin.zig").loadAll(reg.tools.allocator, reg, ctx);
    @import("plugin.zig").registerReloadTool(reg, ctx) catch {};
}

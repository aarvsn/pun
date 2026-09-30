// MCP server: JSON-RPC 2.0 over stdio.
//
// Implements the Model Context Protocol (https://modelcontextprotocol.io) so
// pun can act as a tool/resource/prompt provider for any MCP-compatible host
// (Claude Desktop, Zed, etc.).
//
// Transport: line-delimited JSON over stdin/stdout (the "stdio" transport).
// Server-initiated notifications go to stderr.

const std = @import("std");
const config = @import("../config/schema.zig");
const security = @import("../security/mod.zig");
const tools = @import("../tools/mod.zig");
const types = @import("../types.zig");
const util = @import("../util.zig");

/// Entry point: install security policy + tool registry, then read lines.
pub fn run(alloc: std.mem.Allocator, cfg: *config.Config) !void {
    var policy = try security.SecurityPolicy.init(alloc, cfg);
    defer policy.deinit();

    var reg = tools.Registry.init(alloc);
    defer reg.deinit();

    const ctx = try alloc.create(tools.ToolContext);
    defer alloc.destroy(ctx);
    ctx.* = .{
        .alloc = alloc,
        .cfg = cfg,
        .policy = &policy,
        .provider = null,
        .workspace = cfg.security.workspace,
    };
    try tools.registerAll(&reg, ctx);

    // Send an initial server notification (to stderr; stdout is reserved for JSON-RPC).
    stderrPrint("pun MCP server ready (tools={d})\n", .{reg.tools.items.len}) catch {};

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    var line_buf = std.ArrayList(u8).init(alloc);
    defer line_buf.deinit();

    while (true) {
        line_buf.clearRetainingCapacity();
        stdin.readUntilDelimiterArrayList(&line_buf, '\n', 1 << 20) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (line_buf.items.len == 0) continue;

        handleLine(alloc, stdout, line_buf.items, cfg, &policy, &reg, ctx) catch |e| {
            stderrPrint("pun mcp: error handling line: {}\n", .{e}) catch {};
        };
    }
}

fn handleLine(
    alloc: std.mem.Allocator,
    stdout: anytype,
    line: []const u8,
    cfg: *config.Config,
    policy: *security.SecurityPolicy,
    reg: *tools.Registry,
    ctx: *tools.ToolContext,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    const method_v = obj.get("method") orelse return;
    if (method_v != .string) return;
    const method = method_v.string;

    const id_v = obj.get("id");

    const params: std.json.Value = obj.get("params") orelse .null;

    if (std.mem.eql(u8, method, "initialize")) {
        try handleInitialize(alloc, stdout, id_v);
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        // notification — no response
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try handleToolsList(alloc, stdout, id_v, reg);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try handleToolsCall(alloc, stdout, id_v, params, reg, ctx);
    } else if (std.mem.eql(u8, method, "resources/list")) {
        try handleResourcesList(alloc, stdout, id_v, cfg);
    } else if (std.mem.eql(u8, method, "resources/read")) {
        try handleResourcesRead(alloc, stdout, id_v, params, policy);
    } else if (std.mem.eql(u8, method, "resources/subscribe")) {
        // v0.7: accept subscription, return empty result (file watcher integration)
        try writeResult(alloc, stdout, id_v, "{}");
    } else if (std.mem.eql(u8, method, "resources/unsubscribe")) {
        try writeResult(alloc, stdout, id_v, "{}");
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        try handlePromptsList(alloc, stdout, id_v);
    } else if (std.mem.eql(u8, method, "prompts/get")) {
        try handlePromptsGet(alloc, stdout, id_v, params);
    } else if (std.mem.eql(u8, method, "shutdown")) {
        try writeResult(alloc, stdout, id_v, "{}");
    } else if (std.mem.eql(u8, method, "ping")) {
        try writeResult(alloc, stdout, id_v, "{}");
    } else {
        try writeError(stdout, id_v, -32601, "method not found");
    }
}

fn handleInitialize(alloc: std.mem.Allocator, stdout: anytype, id_v: ?std.json.Value) !void {
    const result =
        \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":true},"resources":{"listChanged":false,"subscribe":true},"prompts":{"listChanged":false}},"serverInfo":{"name":"pun","version":"0.7.0"}}
    ;
    try writeResult(alloc, stdout, id_v, result);
}

fn handleToolsList(alloc: std.mem.Allocator, stdout: anytype, id_v: ?std.json.Value, reg: *tools.Registry) !void {
    const specs = try reg.specsJson(alloc);
    defer alloc.free(specs);
    // Wrap as {"tools":[...]}
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("{\"tools\":");
    try buf.appendSlice(specs);
    try buf.append('}');
    try writeResult(alloc, stdout, id_v, buf.items);
}

fn handleToolsCall(
    alloc: std.mem.Allocator,
    stdout: anytype,
    id_v: ?std.json.Value,
    params: std.json.Value,
    reg: *tools.Registry,
    ctx: *tools.ToolContext,
) !void {
    if (params != .object) {
        try writeError(stdout, id_v, -32602, "invalid params");
        return;
    }
    const name_v = params.object.get("name") orelse {
        try writeError(stdout, id_v, -32602, "missing 'name'");
        return;
    };
    if (name_v != .string) {
        try writeError(stdout, id_v, -32602, "'name' must be string");
        return;
    }
    const name = name_v.string;
    const arguments_v = params.object.get("arguments") orelse .null;
    // Serialize arguments back to JSON string for the registry
    var args_buf = std.ArrayList(u8).init(alloc);
    defer args_buf.deinit();
    try std.json.stringify(arguments_v, .{}, args_buf.writer());

    var result = reg.run(alloc, ctx, name, args_buf.items) catch |e| {
        const msg = try std.fmt.allocPrint(alloc, "tool error: {}", .{e});
        defer alloc.free(msg);
        try writeToolResult(alloc, stdout, id_v, msg, true, null);
        return;
    };
    defer result.deinit(alloc);

    try writeToolResult(alloc, stdout, id_v, result.content, result.is_error, result.blocks);
}

fn writeToolResult(
    alloc: std.mem.Allocator,
    stdout: anytype,
    id_v: ?std.json.Value,
    text: []const u8,
    is_error: bool,
    blocks: ?[]@import("../types.zig").ContentBlock,
) !void {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("{\"content\":[");
    if (blocks) |bs| {
        // Structured content blocks (v0.7)
        for (bs, 0..) |b, i| {
            if (i > 0) try buf.append(',');
            try b.toJson(&buf);
        }
    } else {
        // Default: single text block
        try buf.appendSlice("{\"type\":\"text\",\"text\":");
        try writeJsonStr(&buf, text);
        try buf.append('}');
    }
    try buf.appendSlice("],\"isError\":");
    try buf.appendSlice(if (is_error) "true" else "false");
    try buf.append('}');
    try writeResult(alloc, stdout, id_v, buf.items);
}

fn handleResourcesList(
    alloc: std.mem.Allocator,
    stdout: anytype,
    id_v: ?std.json.Value,
    cfg: *config.Config,
) !void {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("{\"resources\":[");
    var dir = std.fs.openDirAbsolute(cfg.security.workspace, .{ .iterate = true }) catch {
        try buf.appendSlice("]}");
        try writeResult(alloc, stdout, id_v, buf.items);
        return;
    };
    defer dir.close();
    var it = dir.iterate();
    var first = true;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!first) try buf.append(',');
        first = false;
        const full_uri = try std.fmt.allocPrint(alloc, "file://{s}", .{entry.name});
        defer alloc.free(full_uri);
        try buf.appendSlice("{\"uri\":");
        try writeJsonStr(&buf, full_uri);
        try buf.appendSlice(",\"name\":");
        try writeJsonStr(&buf, entry.name);
        try buf.append('}');
    }
    try buf.appendSlice("]}");
    try writeResult(alloc, stdout, id_v, buf.items);
}

fn handleResourcesRead(
    alloc: std.mem.Allocator,
    stdout: anytype,
    id_v: ?std.json.Value,
    params: std.json.Value,
    policy: *security.SecurityPolicy,
) !void {
    if (params != .object) {
        try writeError(stdout, id_v, -32602, "invalid params");
        return;
    }
    const uri_v = params.object.get("uri") orelse {
        try writeError(stdout, id_v, -32602, "missing 'uri'");
        return;
    };
    if (uri_v != .string) {
        try writeError(stdout, id_v, -32602, "'uri' must be string");
        return;
    }
    const uri = uri_v.string;
    if (!std.mem.startsWith(u8, uri, "file://")) {
        try writeError(stdout, id_v, -32602, "only file:// URIs supported");
        return;
    }
    const rel = uri["file://".len..];
    const abs = policy.resolvePath(rel) catch {
        try writeError(stdout, id_v, -32602, "path outside workspace jail");
        return;
    };
    defer alloc.free(abs);
    const content = util.readFile(alloc, abs) catch {
        try writeError(stdout, id_v, -32602, "cannot read file");
        return;
    };
    defer alloc.free(content);

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("{\"contents\":[{\"uri\":");
    try writeJsonStr(&buf, uri);
    try buf.appendSlice(",\"mimeType\":\"text/plain\",\"text\":");
    try writeJsonStr(&buf, content);
    try buf.appendSlice("}]}");
    try writeResult(alloc, stdout, id_v, buf.items);
}

const PromptTemplate = struct {
    name: []const u8,
    description: []const u8,
    arguments: []const struct {
        name: []const u8,
        description: []const u8,
        required: bool,
    },
    template: []const u8,
};

const prompt_templates = [_]PromptTemplate{
    .{
        .name = "code_review",
        .description = "Review code for issues, style, and improvements.",
        .arguments = &.{
            .{ .name = "file", .description = "File path to review", .required = true },
            .{ .name = "focus", .description = "What to focus on (e.g. security, performance)", .required = false },
        },
        .template = "Please review the code in {file}. Focus on: {focus}. Identify bugs, style issues, and suggest concrete improvements.",
    },
    .{
        .name = "explain",
        .description = "Explain a piece of code or concept.",
        .arguments = &.{
            .{ .name = "topic", .description = "What to explain", .required = true },
            .{ .name = "level", .description = "Audience level: beginner, intermediate, expert", .required = false },
        },
        .template = "Explain {topic} at a {level} level. Be concise and use examples where helpful.",
    },
    .{
        .name = "refactor",
        .description = "Refactor code for clarity, performance, or maintainability.",
        .arguments = &.{
            .{ .name = "file", .description = "File path to refactor", .required = true },
            .{ .name = "goal", .description = "Refactoring goal (e.g. extract function, simplify)", .required = true },
        },
        .template = "Refactor {file} with this goal: {goal}. Preserve behavior. Show the diff and explain your changes.",
    },
};

fn handlePromptsList(alloc: std.mem.Allocator, stdout: anytype, id_v: ?std.json.Value) !void {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("{\"prompts\":[");
    for (prompt_templates, 0..) |tpl, i| {
        if (i > 0) try buf.append(',');
        try buf.appendSlice("{\"name\":");
        try writeJsonStr(&buf, tpl.name);
        try buf.appendSlice(",\"description\":");
        try writeJsonStr(&buf, tpl.description);
        try buf.appendSlice(",\"arguments\":[");
        for (tpl.arguments, 0..) |arg, j| {
            if (j > 0) try buf.append(',');
            try buf.appendSlice("{\"name\":");
            try writeJsonStr(&buf, arg.name);
            try buf.appendSlice(",\"description\":");
            try writeJsonStr(&buf, arg.description);
            try buf.appendSlice(",\"required\":");
            try buf.appendSlice(if (arg.required) "true" else "false");
            try buf.append('}');
        }
        try buf.appendSlice("]}");
    }
    try buf.appendSlice("]}");
    try writeResult(alloc, stdout, id_v, buf.items);
}

fn handlePromptsGet(
    alloc: std.mem.Allocator,
    stdout: anytype,
    id_v: ?std.json.Value,
    params: std.json.Value,
) !void {
    if (params != .object) {
        try writeError(stdout, id_v, -32602, "invalid params");
        return;
    }
    const name_v = params.object.get("name") orelse {
        try writeError(stdout, id_v, -32602, "missing 'name'");
        return;
    };
    if (name_v != .string) {
        try writeError(stdout, id_v, -32602, "'name' must be string");
        return;
    }
    const name = name_v.string;
    var tpl: ?PromptTemplate = null;
    for (prompt_templates) |t| {
        if (std.mem.eql(u8, t.name, name)) {
            tpl = t;
            break;
        }
    }
    if (tpl == null) {
        try writeError(stdout, id_v, -32602, "unknown prompt");
        return;
    }
    const args_v = params.object.get("arguments") orelse .null;

    // Substitute {key} placeholders
    var rendered = std.ArrayList(u8).init(alloc);
    defer rendered.deinit();
    var i: usize = 0;
    const tmpl = tpl.?.template;
    while (i < tmpl.len) {
        if (tmpl[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, tmpl, i + 1, '}') orelse {
                try rendered.append(tmpl[i]);
                i += 1;
                continue;
            };
            const key = tmpl[i + 1 .. end];
            // Look up in args
            var found = false;
            if (args_v == .object) {
                if (args_v.object.get(key)) |kv| {
                    if (kv == .string) {
                        try rendered.appendSlice(kv.string);
                        found = true;
                    }
                }
            }
            if (!found) {
                try rendered.append('{');
                try rendered.appendSlice(key);
                try rendered.append('}');
            }
            i = end + 1;
        } else {
            try rendered.append(tmpl[i]);
            i += 1;
        }
    }

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(&buf, rendered.items);
    try buf.appendSlice("}}]}");
    try writeResult(alloc, stdout, id_v, buf.items);
}

// ---- JSON-RPC framing helpers ----

fn writeResult(alloc: std.mem.Allocator, stdout: anytype, id_v: ?std.json.Value, result_json: []const u8) !void {
    var buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer buf.deinit();
    try buf.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&buf, id_v);
    try buf.appendSlice(",\"result\":");
    try buf.appendSlice(result_json);
    try buf.append('}');
    try buf.append('\n');
    try stdout.writeAll(buf.items);
    _ = alloc;
}

fn writeError(stdout: anytype, id_v: ?std.json.Value, code: i32, message: []const u8) !void {
    var buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer buf.deinit();
    try buf.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&buf, id_v);
    try buf.appendSlice(",\"error\":{\"code\":");
    try buf.writer().print("{d}", .{code});
    try buf.appendSlice(",\"message\":");
    try writeJsonStr(&buf, message);
    try buf.appendSlice("}}");
    try buf.append('\n');
    try stdout.writeAll(buf.items);
}

fn writeId(buf: *std.ArrayList(u8), id_v: ?std.json.Value) !void {
    if (id_v) |v| {
        switch (v) {
            .integer => |i| try buf.writer().print("{d}", .{i}),
            .string => |s| {
                try writeJsonStr(buf, s);
            },
            .null => try buf.appendSlice("null"),
            else => try buf.appendSlice("null"),
        }
    } else {
        try buf.appendSlice("null");
    }
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

fn stderrPrint(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, fmt, args);
    try std.io.getStdErr().writer().writeAll(out);
}

test "MCP: writeJsonStr escapes" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try writeJsonStr(&buf, "hello \"world\"\n");
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\n\"", buf.items);
}

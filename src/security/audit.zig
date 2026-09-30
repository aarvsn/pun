// AuditLog — append-only JSONL of every tool call / model request / security event.

const std = @import("std");
const util = @import("../util.zig");
const types = @import("../types.zig");

pub const AuditLog = struct {
    path: []const u8,
    alloc: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator, path: []const u8) !AuditLog {
        if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
        return .{ .path = try alloc.dupe(u8, path), .alloc = alloc };
    }

    pub fn deinit(self: *AuditLog) void {
        self.alloc.free(self.path);
    }

    pub fn log(self: *AuditLog, kind: anytype, summary: []const u8, payload_json: ?[]const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();

        var f = try std.fs.cwd().createFile(self.path, .{ .truncate = false });
        defer f.close();
        try f.seekFromEnd(0);

        const ts = try util.isoNow(self.alloc);
        defer self.alloc.free(ts);

        // Build a one-line JSON object: {"ts": "...", "kind": "...", "summary": "...", "payload": <json or null>}
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        try buf.appendSlice("{\"ts\":\"");
        try writeJsonString(&buf, ts);
        try buf.appendSlice("\",\"kind\":\"");
        try buf.appendSlice(@tagName(kind));
        try buf.appendSlice("\",\"summary\":\"");
        try writeJsonString(&buf, summary);
        try buf.appendSlice("\"");
        if (payload_json) |p| {
            try buf.appendSlice(",\"payload\":");
            try buf.appendSlice(p);
        }
        try buf.appendSlice("}\n");

        try f.writeAll(buf.items);
    }

    /// Convenience: log a tool_call + its result.
    pub fn logToolCall(self: *AuditLog, tool_name: []const u8, args_json: []const u8, result: []const u8, is_error: bool) !void {
        const summary = try std.fmt.allocPrint(self.alloc, "tool:{s} {}", .{ tool_name, is_error });
        defer self.alloc.free(summary);
        const payload = try std.fmt.allocPrint(self.alloc, "{{\"tool\":\"{s}\",\"args\":{s},\"result_len\":{d}}}", .{
            tool_name,
            args_json,
            result.len,
        });
        defer self.alloc.free(payload);
        try self.log(.tool_call, summary, payload);
    }

    pub fn logModelRequest(self: *AuditLog, provider: []const u8, model: []const u8, tokens_in: u64) !void {
        const summary = try std.fmt.allocPrint(self.alloc, "model:{s}/{s} in={d}", .{ provider, model, tokens_in });
        defer self.alloc.free(summary);
        try self.log(.model_request, summary, null);
    }

    pub fn logModelResponse(self: *AuditLog, provider: []const u8, model: []const u8, tokens_out: u64, finish: []const u8) !void {
        const summary = try std.fmt.allocPrint(self.alloc, "model:{s}/{s} out={d} finish={s}", .{
            provider, model, tokens_out, finish,
        });
        defer self.alloc.free(summary);
        try self.log(.model_response, summary, null);
    }

    pub fn logShellExec(self: *AuditLog, command: []const u8, exit_code: i32) !void {
        const summary = try std.fmt.allocPrint(self.alloc, "shell exit={d}: {s}", .{ exit_code, command });
        defer self.alloc.free(summary);
        try self.log(.shell_exec, summary, null);
    }

    pub fn logConfirmation(self: *AuditLog, granted: bool, what: []const u8) !void {
        const Kind = @TypeOf(@as(types.AuditEntry, undefined).kind);
        const kind: Kind = if (granted) .confirmation_granted else .confirmation_denied;
        const summary = try std.fmt.allocPrint(self.alloc, "{s}: {s}", .{ if (granted) "granted" else "denied", what });
        defer self.alloc.free(summary);
        try self.log(kind, summary, null);
    }

    pub fn logInjectionBlocked(self: *AuditLog, patterns: []const []const u8) !void {
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        for (patterns, 0..) |p, i| {
            if (i > 0) try buf.appendSlice(",");
            try buf.appendSlice(p);
        }
        const summary = try std.fmt.allocPrint(self.alloc, "blocked: {s}", .{buf.items});
        defer self.alloc.free(summary);
        try self.log(.injection_blocked, summary, null);
    }
};

fn writeJsonString(buf: *std.ArrayList(u8), s: []const u8) !void {
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

test "AuditLog: append" {
    const alloc = std.testing.allocator;
    const tmp = "/tmp/pun_audit_test.jsonl";
    defer std.fs.cwd().deleteFile(tmp) catch {};
    var log = try AuditLog.init(alloc, tmp);
    defer log.deinit();
    try log.log(.tool_call, "shell: ls -la", null);
    try log.log(.shell_exec, "ls -la", null);
    try log.logConfirmation(true, "shell: zig build");

    // Verify file has 3 lines
    var f = try std.fs.cwd().openFile(tmp, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try alloc.alloc(u8, stat.size);
    defer alloc.free(buf);
    _ = try f.readAll(buf);
    var lines: usize = 0;
    for (buf) |c| {
        if (c == '\n') lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), lines);
}

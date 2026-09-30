// HTTP client wrapper using std.http.
//
// All provider adapters go through this so we have one place to enforce
// network policy, retries, and audit logging.

const std = @import("std");
const network = @import("../security/network.zig");
const sse = @import("sse.zig");

pub const HttpResponse = struct {
    status: u16,
    body: []u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *HttpResponse) void {
        self.alloc.free(self.body);
    }
};

pub fn postJson(
    alloc: std.mem.Allocator,
    url: []const u8,
    headers: []const std.http.Header,
    body: []const u8,
) !HttpResponse {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var server_header_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.POST, try std.Uri.parse(url), .{
        .server_header_buffer = &server_header_buf,
        .extra_headers = headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    req.send() catch |e| return mapHttpError(e);
    try req.writeAll(body);
    try req.finish();
    try req.wait();

    const status: u16 = @intFromEnum(req.response.status);
    const reader = req.reader();
    const body_buf = try reader.readAllAlloc(alloc, 8 * 1024 * 1024);
    return .{ .status = status, .body = body_buf, .alloc = alloc };
}

pub fn get(
    alloc: std.mem.Allocator,
    url: []const u8,
    headers: []const std.http.Header,
) !HttpResponse {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var server_header_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, try std.Uri.parse(url), .{
        .server_header_buffer = &server_header_buf,
        .extra_headers = headers,
    });
    defer req.deinit();

    req.send() catch |e| return mapHttpError(e);
    try req.finish();
    try req.wait();

    const status: u16 = @intFromEnum(req.response.status);
    const reader = req.reader();
    const body_buf = try reader.readAllAlloc(alloc, 8 * 1024 * 1024);
    return .{ .status = status, .body = body_buf, .alloc = alloc };
}

/// Streaming POST: sends `body`, then reads the response chunk by chunk,
/// feeding each chunk to an SSE parser. Calls `on_event(ctx, data)` for each
/// complete SSE event. Returns the HTTP status code.
pub fn postJsonStream(
    alloc: std.mem.Allocator,
    url: []const u8,
    headers: []const std.http.Header,
    body: []const u8,
    ctx: anytype,
    comptime on_event: fn (@TypeOf(ctx), []const u8) anyerror!void,
) !u16 {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var server_header_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.POST, try std.Uri.parse(url), .{
        .server_header_buffer = &server_header_buf,
        .extra_headers = headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    req.send() catch |e| return mapHttpError(e);
    try req.writeAll(body);
    try req.finish();
    try req.wait();

    const status: u16 = @intFromEnum(req.response.status);
    if (status != 200) {
        // Drain the body so the connection can close cleanly
        const reader = req.reader();
        _ = reader.readAllAlloc(alloc, 1024) catch null;
        return status;
    }

    var parser = sse.SseParser.init(alloc);
    defer parser.deinit();

    var buf: [16 * 1024]u8 = undefined;
    const reader = req.reader();
    while (true) {
        const n = reader.read(&buf) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return mapHttpError(e),
        };
        if (n == 0) break;
        try parser.feed(buf[0..n], ctx, on_event);
    }
    // Flush any pending event
    try parser.feed("\n", ctx, on_event);
    return status;
}

fn mapHttpError(e: anyerror) anyerror {
    return switch (e) {
        error.UnknownStatus, error.HttpConnectionFailed, error.NetworkUnreachable => error.ProviderHttpError,
        error.AuthenticationFailed => error.ProviderAuthError,
        else => e,
    };
}

/// Tiny JSON value type used by adapters to build request bodies without
/// pulling in std.json.Parsed overhead everywhere.
pub fn buildJsonString(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
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
    return try buf.toOwnedSlice();
}

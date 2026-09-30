// web.zig — fetch_url + web_search (Brave Search API).
//
// web_search: queries the Brave Search API.
//   - API key stored in the vault under "brave_search_key"
//   - Endpoint: https://api.search.brave.com/res/v1/web/search
//   - Returns up to N results as text (title, url, snippet)

const std = @import("std");
const types = @import("../types.zig");
const registry = @import("registry.zig");
const http = @import("../providers/http.zig");

pub fn registerAll(reg: *registry.Registry, ctx: *registry.ToolContext) !void {
    _ = ctx;
    try reg.add(.{
        .name = "fetch_url",
        .description = "Fetch a URL (HTTP GET) and return up to 64KB of the response body. Subject to network policy.",
        .parameters_schema =
            \\{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}
        ,
        .run = runFetchUrl,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "web_search",
        .description = "Search the web via Brave Search API. Store your Brave Search API key in the vault under 'brave_search_key' (pun vault set brave_search_key <key>). Returns up to N results with title, URL, and snippet.",
        .parameters_schema =
            \\{"type":"object","properties":{"query":{"type":"string"},"count":{"type":"integer","description":"Max results; default 5"}},"required":["query"]}
        ,
        .run = runWebSearch,
        .ctx = undefined,
    });
}

fn runFetchUrl(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const url_v = args.value.object.get("url") orelse return errorResult(alloc, "missing 'url'");
    if (url_v != .string) return errorResult(alloc, "'url' must be string");
    const url = url_v.string;

    c.policy.checkNetwork(url) catch |e| return errorResult(alloc, @errorName(e));

    const headers = [_]std.http.Header{};
    var resp = http.get(alloc, url, &headers) catch |e| return errorResult(alloc, @errorName(e));
    defer resp.deinit();

    const cap: usize = 64 * 1024;
    const len = if (resp.body.len > cap) cap else resp.body.len;
    const body = try alloc.dupe(u8, resp.body[0..len]);
    try c.policy.audit_log.log(.network_fetch, url, null);

    // Scan for injection
    const annotated = try c.policy.annotateInjection(body);
    if (annotated.ptr != body.ptr) {
        alloc.free(body);
        return .{ .content = annotated };
    }
    return .{ .content = body };
}

fn runWebSearch(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const q_v = args.value.object.get("query") orelse return errorResult(alloc, "missing 'query'");
    if (q_v != .string) return errorResult(alloc, "'query' must be string");
    const count: i64 = if (args.value.object.get("count")) |v| (if (v == .integer) v.integer else 5) else 5;

    // Get the Brave Search API key from the vault
    const brave_key = (c.policy.getApiKey("brave_search_key")) catch null;
    if (brave_key == null) {
        return errorResult(alloc, "web_search requires a Brave Search API key. Store it via: pun vault set brave_search_key <your-key>");
    }
    const key = brave_key.?;

    // Build URL with query params
    var url_buf = std.ArrayList(u8).init(alloc);
    defer url_buf.deinit();
    try url_buf.appendSlice("https://api.search.brave.com/res/v1/web/search?q=");
    try urlEncode(&url_buf, q_v.string);
    try url_buf.writer().print("&count={d}", .{count});

    c.policy.checkNetwork(url_buf.items) catch |e| return errorResult(alloc, @errorName(e));

    const headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "x-subscription-token", .value = key },
    };

    var resp = http.get(alloc, url_buf.items, &headers) catch |e| return errorResult(alloc, @errorName(e));
    defer resp.deinit();

    if (resp.status != 200) {
        const msg = try std.fmt.allocPrint(alloc, "Brave Search returned HTTP {d}", .{resp.status});
        return .{ .content = msg, .is_error = true };
    }

    // Parse JSON response and format as text
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch {
        return .{ .content = try alloc.dupe(u8, resp.body), .is_error = true };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return errorResult(alloc, "bad Brave response");

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();

    // Brave response: { "web": { "results": [ { "title":..., "url":..., "description":... }, ... ] } }
    if (parsed.value.object.get("web")) |web_v| {
        if (web_v == .object) {
            if (web_v.object.get("results")) |results_v| {
                if (results_v == .array) {
                    for (results_v.array.items, 0..) |item, i| {
                        if (item != .object) continue;
                        const title = if (item.object.get("title")) |v| (if (v == .string) v.string else "") else "";
                        const url = if (item.object.get("url")) |v| (if (v == .string) v.string else "") else "";
                        const desc = if (item.object.get("description")) |v| (if (v == .string) v.string else "") else "";
                        try out.writer().print("{d}. {s}\n   {s}\n   {s}\n\n", .{ i + 1, title, url, desc });
                    }
                }
            }
        }
    }

    if (out.items.len == 0) {
        return .{ .content = try alloc.dupe(u8, "(no results)") };
    }

    try c.policy.audit_log.log(.network_fetch, "brave_search", q_v.string);

    // Annotate for injection
    const annotated = try c.policy.annotateInjection(out.items);
    if (annotated.ptr != out.items.ptr) {
        out.deinit();
        return .{ .content = annotated };
    }
    return .{ .content = try out.toOwnedSlice() };
}

fn urlEncode(buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.append(c);
        } else if (c == ' ') {
            try buf.append('+');
        } else {
            try buf.writer().print("%{X:0>2}", .{c});
        }
    }
}

fn errorResult(alloc: std.mem.Allocator, msg: []const u8) types.ToolResult {
    return .{
        .content = alloc.dupe(u8, msg) catch "",
        .is_error = true,
    };
}

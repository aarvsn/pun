// Playwright browser tool — drives a real headless Chromium via a small Node
// helper script. The Node script is spawned as a subprocess; it speaks
// JSON-over-stdio (one request per line, one response per line).
//
// Actions supported (v0.3):
//   navigate  — go to a URL, return rendered HTML + text
//   click     — click a CSS selector
//   type      — type text into a CSS selector
//   snapshot  — return current page text + URL + title
//   scroll    — scroll by N pixels
//   close     — close the page (next navigate reopens)
//
// The Node helper installs Playwright on first use (slow) and reuses it after.

const std = @import("std");
const types = @import("../types.zig");
const registry = @import("registry.zig");
const util = @import("../util.zig");

const HELPER_SCRIPT =
    \\// pun-playwright-helper.js — driven by the pun Zig binary via stdio JSON lines.
    \\// Each request: {"action":"navigate|click|type|snapshot|scroll|close", ...}
    \\// Each response: {"ok":true,"text":"...","url":"...","title":"..."} or {"ok":false,"error":"..."}
    \\
    \\const fs = require('fs');
    \\const path = require('path');
    \\const os = require('os');
    \\
    \\let playwright = null;
    \\let browser = null;
    \\let page = null;
    \\
    \\async function ensurePlaywright() {
    \\  if (playwright) return;
    \\  try {
    \\    playwright = require('playwright');
    \\  } catch (e) {
    \\    // Try installing it
    \\    const { execSync } = require('child_process');
    \\    const puppeteer_dir = path.join(os.homedir(), '.pun', 'node_modules');
    \\    fs.mkdirSync(path.join(os.homedir(), '.pun'), { recursive: true });
    \\    if (!fs.existsSync(puppeteer_dir)) {
    \\      process.stderr.write('Installing playwright (one-time, ~100MB)...\n');
    \\      execSync(`npm install --prefix ${path.join(os.homedir(), '.pun')} playwright`, { stdio: 'inherit' });
    \\    }
    \\    process.chdir(path.join(os.homedir(), '.pun'));
    \\    playwright = require('playwright');
    \\  }
    \\}
    \\
    \\async function ensurePage() {
    \\  await ensurePlaywright();
    \\  if (!browser) {
    \\    browser = await playwright.chromium.launch({ headless: true });
    \\  }
    \\  if (!page) {
    \\    page = await browser.newPage();
    \\  }
    \\  return page;
    \\}
    \\
    \\async function handle(req) {
    \\  await ensurePage();
    \\  switch (req.action) {
    \\    case 'navigate': {
    \\      await page.goto(req.url, { waitUntil: 'domcontentloaded', timeout: 30000 });
    \\      const text = await page.evaluate(() => document.body ? document.body.innerText : '');
    \\      return { ok: true, url: page.url(), title: await page.title(), text: text.slice(0, 65536) };
    \\    }
    \\    case 'click': {
    \\      await page.click(req.selector, { timeout: 5000 });
    \\      return { ok: true, url: page.url() };
    \\    }
    \\    case 'type': {
    \\      await page.fill(req.selector, req.text, { timeout: 5000 });
    \\      return { ok: true };
    \\    }
    \\    case 'snapshot': {
    \\      const text = await page.evaluate(() => document.body ? document.body.innerText : '');
    \\      return { ok: true, url: page.url(), title: await page.title(), text: text.slice(0, 65536) };
    \\    }
    \\    case 'scroll': {
    \\      await page.evaluate(y => window.scrollBy(0, y), req.amount || 500);
    \\      return { ok: true };
    \\    }
    \\    case 'close': {
    \\      if (page) { await page.close(); page = null; }
    \\      return { ok: true };
    \\    }
    \\    default:
    \\      return { ok: false, error: 'unknown action: ' + req.action };
    \\  }
    \\}
    \\
    \\let buf = '';
    \\process.stdin.on('data', async (chunk) => {
    \\  buf += chunk.toString();
    \\  let i;
    \\  while ((i = buf.indexOf('\n')) >= 0) {
    \\    const line = buf.slice(0, i);
    \\    buf = buf.slice(i + 1);
    \\    if (!line.trim()) continue;
    \\    try {
    \\      const req = JSON.parse(line);
    \\      const resp = await handle(req).catch(e => ({ ok: false, error: String(e) }));
    \\      process.stdout.write(JSON.stringify(resp) + '\n');
    \\    } catch (e) {
    \\      process.stdout.write(JSON.stringify({ ok: false, error: 'bad json: ' + String(e) }) + '\n');
    \\    }
    \\  }
    \\});
    \\process.stdin.on('end', async () => {
    \\  if (browser) await browser.close();
    \\  process.exit(0);
    \\});
;

pub fn registerAll(reg: *registry.Registry, ctx: *registry.ToolContext) !void {
    _ = ctx;
    try reg.add(.{
        .name = "browser_navigate",
        .description = "Navigate the headless browser to a URL. Returns the rendered page text (up to 64KB), URL, and title. Spawns Chromium on first use.",
        .parameters_schema =
            \\{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}
        ,
        .run = runNavigate,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "browser_click",
        .description = "Click an element in the headless browser by CSS selector.",
        .parameters_schema =
            \\{"type":"object","properties":{"selector":{"type":"string"}},"required":["selector"]}
        ,
        .run = runClick,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "browser_type",
        .description = "Type text into an element in the headless browser by CSS selector.",
        .parameters_schema =
            \\{"type":"object","properties":{"selector":{"type":"string"},"text":{"type":"string"}},"required":["selector","text"]}
        ,
        .run = runType,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "browser_snapshot",
        .description = "Return the current page text, URL, and title without navigating.",
        .parameters_schema =
            \\{"type":"object","properties":{}}
        ,
        .run = runSnapshot,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "browser_scroll",
        .description = "Scroll the page by N pixels (default 500).",
        .parameters_schema =
            \\{"type":"object","properties":{"amount":{"type":"integer","description":"Pixels to scroll; default 500"}}}
        ,
        .run = runScroll,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "browser_close",
        .description = "Close the current page. Next navigate will open a fresh page.",
        .parameters_schema =
            \\{"type":"object","properties":{}}
        ,
        .run = runClose,
        .ctx = undefined,
    });
}

/// Per-process helper state. The Node subprocess is started on first use
/// and kept alive for the rest of the process.
const HelperState = struct {
    alloc: std.mem.Allocator,
    child: ?std.process.Child = null,
    helper_script_path: ?[]u8 = null,
    started: bool = false,
};

var helper_state: ?HelperState = null;

fn ensureHelper(alloc: std.mem.Allocator, policy: *anyopaque) !void {
    _ = policy;
    if (helper_state == null) {
        helper_state = .{
            .alloc = alloc,
        };
    }
    const st = &helper_state.?;

    if (st.started) return;

    // Write helper script to ~/.pun/playwright-helper.js
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch try alloc.dupe(u8, "/tmp");
    defer alloc.free(home);
    const script_path = try std.fmt.allocPrint(alloc, "{s}/.pun/playwright-helper.js", .{home});
    errdefer alloc.free(script_path);
    try std.fs.cwd().makePath(std.fs.path.dirname(script_path).?);
    try util.writeFile(alloc, script_path, HELPER_SCRIPT);
    st.helper_script_path = script_path;

    // Spawn node
    const argv = [_][]const u8{ "node", script_path };
    var child = std.process.Child.init(&argv, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    st.child = child;
    st.started = true;
}

/// Send a JSON request and read one JSON response.
fn callHelper(alloc: std.mem.Allocator, policy: *anyopaque, req_json: []const u8) ![]u8 {
    try ensureHelper(alloc, policy);
    const st = &helper_state.?;
    const child = &st.child.?;

    if (child.stdin) |stdin| {
        try stdin.writeAll(req_json);
        try stdin.writeAll("\n");
    } else return error.ToolError;

    // Read one line of response
    var buf: [256 * 1024]u8 = undefined;
    var len: usize = 0;
    if (child.stdout) |stdout| {
        while (len < buf.len) {
            const n = stdout.read(buf[len .. len + 1]) catch 0;
            if (n == 0) break;
            if (buf[len] == '\n') break;
            len += 1;
        }
    }
    return try alloc.dupe(u8, buf[0..len]);
}

fn runNavigate(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const url_v = args.value.object.get("url") orelse return errorResult(alloc, "missing 'url'");
    if (url_v != .string) return errorResult(alloc, "'url' must be string");
    const url = url_v.string;
    c.policy.checkNetwork(url) catch |e| return errorResult(alloc, @errorName(e));

    const req = try std.fmt.allocPrint(alloc, "{{\"action\":\"navigate\",\"url\":\"{s}\"}}", .{url});
    defer alloc.free(req);
    const resp = callHelper(alloc, c.policy, req) catch |e| return errorResult(alloc, @errorName(e));
    defer alloc.free(resp);
    try c.policy.audit_log.log(.network_fetch, url, null);

    // Parse response and inject-annotate the text
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, resp, .{}) catch return errorResult(alloc, "bad response from helper");
    defer parsed.deinit();
    if (parsed.value != .object) return errorResult(alloc, "bad response");
    const ok_v = parsed.value.object.get("ok") orelse return errorResult(alloc, "no 'ok' field");
    if (ok_v != .bool or !ok_v.bool) {
        const err = if (parsed.value.object.get("error")) |e| (if (e == .string) e.string else "unknown") else "unknown";
        return errorResult(alloc, err);
    }
    const text = if (parsed.value.object.get("text")) |t| (if (t == .string) t.string else "") else "";
    const title = if (parsed.value.object.get("title")) |t| (if (t == .string) t.string else "") else "";
    const final_url = if (parsed.value.object.get("url")) |u| (if (u == .string) u.string else url) else url;

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    try out.writer().print("url: {s}\ntitle: {s}\n\n{s}", .{ final_url, title, text });
    const annotated = try c.policy.annotateInjection(out.items);
    if (annotated.ptr != out.items.ptr) {
        out.deinit();
        return .{ .content = annotated };
    }
    return .{ .content = try out.toOwnedSlice() };
}

fn runClick(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const sel_v = args.value.object.get("selector") orelse return errorResult(alloc, "missing 'selector'");
    if (sel_v != .string) return errorResult(alloc, "'selector' must be string");
    const sel = sel_v.string;
    var escaped = std.ArrayList(u8).init(alloc);
    defer escaped.deinit();
    try escapeJsonStr(&escaped, sel);
    const req = try std.fmt.allocPrint(alloc, "{{\"action\":\"click\",\"selector\":\"{s}\"}}", .{escaped.items});
    defer alloc.free(req);
    const resp = callHelper(alloc, c.policy, req) catch |e| return errorResult(alloc, @errorName(e));
    defer alloc.free(resp);
    return simpleResult(alloc, resp);
}

fn runType(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const sel_v = args.value.object.get("selector") orelse return errorResult(alloc, "missing 'selector'");
    const txt_v = args.value.object.get("text") orelse return errorResult(alloc, "missing 'text'");
    if (sel_v != .string or txt_v != .string) return errorResult(alloc, "invalid args");
    var esc_sel = std.ArrayList(u8).init(alloc);
    defer esc_sel.deinit();
    try escapeJsonStr(&esc_sel, sel_v.string);
    var esc_txt = std.ArrayList(u8).init(alloc);
    defer esc_txt.deinit();
    try escapeJsonStr(&esc_txt, txt_v.string);
    const req = try std.fmt.allocPrint(alloc, "{{\"action\":\"type\",\"selector\":\"{s}\",\"text\":\"{s}\"}}", .{ esc_sel.items, esc_txt.items });
    defer alloc.free(req);
    const resp = callHelper(alloc, c.policy, req) catch |e| return errorResult(alloc, @errorName(e));
    defer alloc.free(resp);
    return simpleResult(alloc, resp);
}

fn runSnapshot(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    _ = args;
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const resp = callHelper(alloc, c.policy, "{\"action\":\"snapshot\"}") catch |e| return errorResult(alloc, @errorName(e));
    defer alloc.free(resp);
    return simpleResult(alloc, resp);
}

fn runScroll(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const amount: i64 = if (args.value.object.get("amount")) |v| (if (v == .integer) v.integer else 500) else 500;
    const req = try std.fmt.allocPrint(alloc, "{{\"action\":\"scroll\",\"amount\":{d}}}", .{amount});
    defer alloc.free(req);
    const resp = callHelper(alloc, c.policy, req) catch |e| return errorResult(alloc, @errorName(e));
    defer alloc.free(resp);
    return simpleResult(alloc, resp);
}

fn runClose(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    _ = args;
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const resp = callHelper(alloc, c.policy, "{\"action\":\"close\"}") catch |e| return errorResult(alloc, @errorName(e));
    defer alloc.free(resp);
    return simpleResult(alloc, resp);
}

fn simpleResult(alloc: std.mem.Allocator, resp: []const u8) types.ToolResult {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, resp, .{}) catch {
        return .{ .content = alloc.dupe(u8, resp) catch "", .is_error = true };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .content = alloc.dupe(u8, resp) catch "" };
    const ok_v = parsed.value.object.get("ok") orelse return .{ .content = alloc.dupe(u8, resp) catch "" };
    if (ok_v == .bool and ok_v.bool) {
        const text = if (parsed.value.object.get("text")) |t| (if (t == .string) t.string else "") else "";
        if (text.len > 0) return .{ .content = alloc.dupe(u8, text) catch "" };
        return .{ .content = alloc.dupe(u8, "ok") catch "" };
    }
    const err = if (parsed.value.object.get("error")) |e| (if (e == .string) e.string else "error") else "error";
    return .{ .content = alloc.dupe(u8, err) catch "", .is_error = true };
}

fn escapeJsonStr(buf: *std.ArrayList(u8), s: []const u8) !void {
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

fn errorResult(alloc: std.mem.Allocator, msg: []const u8) types.ToolResult {
    return .{
        .content = alloc.dupe(u8, msg) catch "",
        .is_error = true,
    };
}

/// Called by main.zig on shutdown to kill the helper.
pub fn shutdown(alloc: std.mem.Allocator) void {
    _ = alloc;
    if (helper_state) |*st| {
        if (st.child) |*child| {
            if (child.stdin) |stdin| stdin.close();
            _ = child.wait() catch {};
        }
        if (st.helper_script_path) |p| st.alloc.free(p);
    }
    helper_state = null;
}

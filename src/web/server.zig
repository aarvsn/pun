// HTTP server exposing pun over a local socket with a chat web UI.
//
// Routes:
//   GET  /              → INDEX_HTML (chat UI)
//   POST /api/chat      → {message} → {response, steps, tool_calls, input_tokens, output_tokens}
//   GET  /api/history   → {messages: [{role, content}, ...]}
//   POST /api/clear     → clears agent.messages, returns {ok:true}
//   GET  /api/health    → {ok:true}
//
// Listens on 127.0.0.1:port (default 7878).

const std = @import("std");
const config = @import("../config/schema.zig");
const security = @import("../security/mod.zig");
const providers = @import("../providers/mod.zig");
const loop = @import("../loop/mod.zig");
const ws = @import("websocket.zig");
const base = @import("../providers/base.zig");

const INDEX_HTML =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>pun — web UI</title>
    \\<style>
    \\* { box-sizing: border-box; }
    \\body { margin: 0; background: #1a1a1a; color: #e0e0e0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    \\#app { display: flex; flex-direction: column; height: 100vh; max-width: 900px; margin: 0 auto; }
    \\header { padding: 12px 16px; background: #242424; border-bottom: 1px solid #333; }
    \\header h1 { margin: 0; font-size: 16px; font-weight: 600; }
    \\header span { font-size: 12px; color: #888; }
    \\#chat { flex: 1; overflow-y: auto; padding: 16px; }
    \\.msg { margin-bottom: 12px; padding: 10px 14px; border-radius: 8px; max-width: 80%; white-space: pre-wrap; word-wrap: break-word; }
    \\.msg.user { background: #2563eb; margin-left: auto; }
    \\.msg.assistant { background: #2a2a2a; border: 1px solid #3a3a3a; }
    \\.msg .role { font-size: 11px; color: #888; margin-bottom: 4px; text-transform: uppercase; }
    \\#input-bar { display: flex; gap: 8px; padding: 12px 16px; background: #242424; border-top: 1px solid #333; }
    \\#msg-input { flex: 1; background: #1a1a1a; border: 1px solid #3a3a3a; color: #e0e0e0; padding: 10px 12px; border-radius: 6px; font-size: 14px; font-family: inherit; }
    \\#msg-input:focus { outline: none; border-color: #2563eb; }
    \\button { background: #2563eb; color: white; border: none; padding: 10px 16px; border-radius: 6px; cursor: pointer; font-size: 14px; }
    \\button:hover { background: #1d4ed8; }
    \\button.secondary { background: #3a3a3a; }
    \\button.secondary:hover { background: #4a4a4a; }
    \\button:disabled { background: #444; cursor: not-allowed; }
    \\.meta { font-size: 11px; color: #666; margin-top: 4px; }
    \\</style>
    \\</head>
    \\<body>
    \\<div id="app">
    \\  <header>
    \\    <h1>pun</h1>
    \\    <span id="status">connecting...</span>
    \\  </header>
    \\  <div id="chat"></div>
    \\  <div id="input-bar">
    \\    <input id="msg-input" placeholder="Message pun..." autocomplete="off">
    \\    <button id="send-btn">Send</button>
    \\    <button id="clear-btn" class="secondary">Clear</button>
    \\  </div>
    \\</div>
    \\<script>
    \\const chat = document.getElementById('chat');
    \\const input = document.getElementById('msg-input');
    \\const sendBtn = document.getElementById('send-btn');
    \\const clearBtn = document.getElementById('clear-btn');
    \\const statusEl = document.getElementById('status');
    \\
    \\function addMsg(role, content, meta) {
    \\  const div = document.createElement('div');
    \\  div.className = 'msg ' + role;
    \\  const roleDiv = document.createElement('div');
    \\  roleDiv.className = 'role';
    \\  roleDiv.textContent = role;
    \\  div.appendChild(roleDiv);
    \\  const txt = document.createElement('div');
    \\  txt.textContent = content;
    \\  div.appendChild(txt);
    \\  if (meta) {
    \\    const m = document.createElement('div');
    \\    m.className = 'meta';
    \\    m.textContent = meta;
    \\    div.appendChild(m);
    \\  }
    \\  chat.appendChild(div);
    \\  chat.scrollTop = chat.scrollHeight;
    \\  return txt;
    \\}
    \\
    \\async function loadHistory() {
    \\  try {
    \\    const r = await fetch('/api/history');
    \\    const data = await r.json();
    \\    chat.innerHTML = '';
    \\    (data.messages || []).forEach(m => addMsg(m.role, m.content));
    \\  } catch (e) { console.error(e); }
    \\}
    \\
    \\async function send() {
    \\  const text = input.value.trim();
    \\  if (!text) return;
    \\  input.value = '';
    \\  sendBtn.disabled = true;
    \\  addMsg('user', text);
    \\  const respDiv = addMsg('assistant', '');
    \\  // Use WebSocket for live streaming
    \\  const wsUrl = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws';
    \\  const sock = new WebSocket(wsUrl);
    \\  let gotText = false;
    \\  sock.onopen = () => sock.send(JSON.stringify({ message: text }));
    \\  sock.onmessage = (ev) => {
    \\    try {
    \\      const d = JSON.parse(ev.data);
    \\      if (d.type === 'text') { respDiv.textContent += d.content; gotText = true; chat.scrollTop = chat.scrollHeight; }
    \\      else if (d.type === 'tool') { respDiv.textContent += (gotText ? '\n' : '') + '[' + d.name + ']'; chat.scrollTop = chat.scrollHeight; }
    \\      else if (d.type === 'done') {
    \\        const meta = `steps=${d.steps} tools=${d.tool_calls} in=${d.input_tokens} out=${d.output_tokens}`;
    \\        const m = document.createElement('div'); m.className = 'meta'; m.textContent = meta;
    \\        respDiv.parentElement.appendChild(m); chat.scrollTop = chat.scrollHeight;
    \\      }
    \\      else if (d.type === 'error') { respDiv.textContent = 'Error: ' + d.message; }
    \\    } catch(e) {}
    \\  };
    \\  sock.onclose = () => { sendBtn.disabled = false; input.focus(); };
    \\  sock.onerror = () => { respDiv.textContent = 'Connection error'; sendBtn.disabled = false; };
    \\}
    \\
    \\async function clearChat() {
    \\  if (!confirm('Clear conversation?')) return;
    \\  await fetch('/api/clear', { method: 'POST' });
    \\  chat.innerHTML = '';
    \\}
    \\
    \\sendBtn.addEventListener('click', send);
    \\input.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } });
    \\clearBtn.addEventListener('click', clearChat);
    \\
    \\(async () => {
    \\  try {
    \\    const r = await fetch('/api/health');
    \\    const d = await r.json();
    \\    statusEl.textContent = d.ok ? 'ready' : 'error';
    \\  } catch { statusEl.textContent = 'offline'; }
    \\  await loadHistory();
    \\  input.focus();
    \\})();
    \\</script>
    \\</body>
    \\</html>
;

pub fn run(alloc: std.mem.Allocator, cfg: *config.Config, port: u16) !void {
    var policy = try security.SecurityPolicy.init(alloc, cfg);
    defer policy.deinit();

    const profile = cfg.getActiveProfile() orelse {
        try stderrPrint("error: no active profile configured. Run `pun config init`.\n", .{});
        std.process.exit(1);
    };
    if (cfg.active_provider == null) {
        if (cfg.providers.get(profile.provider)) |p| {
            try cfg.setActiveProvider(p.name);
        }
    }
    if (cfg.active_model == null) {
        if (profile.model) |m| cfg.setActiveModel(m);
    }
    const provider = providers.getProvider(alloc, cfg, &policy, cfg.active_provider.?) catch |e| {
        try stderrPrint("error: failed to init provider {s}: {}\n", .{ profile.provider, e });
        std.process.exit(1);
    };
    defer providers.freeProvider(alloc, provider);

    var agent = try loop.Agent.init(alloc, cfg, &policy, provider);
    defer agent.deinit();

    var addr: std.net.Address = try std.net.Address.parseIp("127.0.0.1", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    try stderrPrint("pun web server listening on http://127.0.0.1:{d}\n", .{port});

    while (true) {
        const conn = server.accept() catch |e| {
            try stderrPrint("accept error: {}\n", .{e});
            continue;
        };
        // Handle each connection synchronously (good enough for a single-user local UI).
        handleConnection(alloc, conn, &agent) catch |e| {
            try stderrPrint("connection error: {}\n", .{e});
        };
    }
}

fn handleConnection(alloc: std.mem.Allocator, conn: std.net.Server.Connection, agent: *loop.Agent) !void {
    defer conn.stream.close();

    // Read request (limited buffer; we expect small bodies)
    var req_buf: [65536]u8 = undefined;
    const n = conn.stream.read(&req_buf) catch |e| {
        if (e == error.WouldBlock) return;
        return e;
    };
    if (n == 0) return;
    const req = req_buf[0..n];

    // Parse METHOD SP PATH
    const first_space = std.mem.indexOfScalar(u8, req, ' ') orelse return;
    const second_space = std.mem.indexOfScalarPos(u8, req, first_space + 1, ' ') orelse return;
    const method = req[0..first_space];
    const path = req[first_space + 1 .. second_space];

    // Split path on '?'
    const path_only = blk: {
        if (std.mem.indexOfScalar(u8, path, '?')) |q| break :blk path[0..q];
        break :blk path;
    };

    // Find body (after \r\n\r\n)
    const body: []const u8 = blk: {
        if (std.mem.indexOf(u8, req, "\r\n\r\n")) |idx| break :blk req[idx + 4 ..];
        break :blk "";
    };

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path_only, "/")) {
        try sendHtml(conn, INDEX_HTML);
    } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path_only, "/api/health")) {
        try sendJson(conn, "{\"ok\":true}");
    } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path_only, "/api/history")) {
        try handleHistory(alloc, conn, agent);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path_only, "/api/chat")) {
        try handleChat(alloc, conn, agent, body);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path_only, "/api/clear")) {
        for (agent.messages.items) |*m| m.deinit(alloc);
        agent.messages.clearRetainingCapacity();
        try sendJson(conn, "{\"ok\":true}");
    } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path_only, "/ws")) {
        // WebSocket upgrade
        if (std.mem.indexOf(u8, req, "Upgrade: websocket") != null or
            std.mem.indexOf(u8, req, "upgrade: websocket") != null)
        {
            try handleWebSocket(alloc, conn, agent, req);
        } else {
            try sendStatus(conn, 400, "Bad Request");
        }
    } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path_only, "/api/sessions")) {
        try handleSessionsList(alloc, conn);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path_only, "/api/search")) {
        try handleSearch(alloc, conn, body);
    } else {
        try sendStatus(conn, 404, "Not Found");
    }
}

/// GET /api/sessions — list all conversation sessions
fn handleSessionsList(alloc: std.mem.Allocator, conn: std.net.Server.Connection) !void {
    const sessions = loop.history.listSessions(alloc) catch {
        try sendJson(conn, "{\"sessions\":[]}");
        return;
    };
    defer loop.history.freeSessionList(alloc, sessions);

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("{\"sessions\":[");
    for (sessions, 0..) |s, i| {
        if (i > 0) try buf.append(',');
        try buf.appendSlice("{\"id\":");
        try writeJsonStr(&buf, s.id);
        try buf.appendSlice(",\"first_ts\":");
        try writeJsonStr(&buf, s.first_ts);
        try buf.writer().print(",\"msg_count\":{d}", .{s.msg_count});
        try buf.appendSlice(",\"preview\":");
        try writeJsonStr(&buf, s.first_content);
        try buf.append('}');
    }
    try buf.appendSlice("]}");
    try sendJson(conn, buf.items);
}

/// POST /api/search — full-text search across all history
/// Body: {"query":"...","max":20}
fn handleSearch(alloc: std.mem.Allocator, conn: std.net.Server.Connection, body: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        try sendJson(conn, "{\"error\":\"invalid JSON\"}");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try sendJson(conn, "{\"error\":\"expected object\"}");
        return;
    }
    const q_v = parsed.value.object.get("query") orelse {
        try sendJson(conn, "{\"error\":\"missing 'query'\"}");
        return;
    };
    if (q_v != .string) {
        try sendJson(conn, "{\"error\":\"'query' must be string\"}");
        return;
    }
    const max: usize = if (parsed.value.object.get("max")) |v| (if (v == .integer) @intCast(v.integer) else 20) else 20;

    const results = loop.history.searchHistory(alloc, q_v.string, max) catch {
        try sendJson(conn, "{\"results\":[]}");
        return;
    };
    defer loop.history.freeSearchResults(alloc, results);

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("{\"results\":[");
    for (results, 0..) |r, i| {
        if (i > 0) try buf.append(',');
        try buf.appendSlice("{\"session\":");
        try writeJsonStr(&buf, r.session_id);
        try buf.appendSlice(",\"role\":");
        try writeJsonStr(&buf, r.role);
        try buf.appendSlice(",\"ts\":");
        try writeJsonStr(&buf, r.ts);
        try buf.appendSlice(",\"content\":");
        try writeJsonStr(&buf, r.content);
        try buf.append('}');
    }
    try buf.appendSlice("]}");
    try sendJson(conn, buf.items);
}

/// Handle a WebSocket connection. Upgrades, reads one message, runs the agent
/// with streaming, sends text deltas as WS text frames, then a done/error frame.
fn handleWebSocket(alloc: std.mem.Allocator, conn: std.net.Server.Connection, agent: *loop.Agent, req: []const u8) !void {
    // Extract Sec-WebSocket-Key
    const key = ws.extractKey(req) orelse {
        try sendStatus(conn, 400, "Missing Sec-WebSocket-Key");
        return;
    };
    const accept = ws.handshake(key);

    // Send 101 Switching Protocols
    var hdr_buf: [512]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    );
    try conn.stream.writeAll(hdr);

    // Read the first message: {"message":"..."}
    const msg_data = (ws.readFrame(alloc, conn.stream) catch null) orelse return;
    defer alloc.free(msg_data);

    // Parse JSON
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, msg_data, .{}) catch {
        try wsSendJson(alloc, conn.stream, "{\"type\":\"error\",\"message\":\"invalid JSON\"}");
        try ws.sendClose(conn.stream);
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try wsSendJson(alloc, conn.stream, "{\"type\":\"error\",\"message\":\"expected object\"}");
        try ws.sendClose(conn.stream);
        return;
    }
    const msg_v = parsed.value.object.get("message") orelse {
        try wsSendJson(alloc, conn.stream, "{\"type\":\"error\",\"message\":\"missing 'message'\"}");
        try ws.sendClose(conn.stream);
        return;
    };
    if (msg_v != .string) {
        try wsSendJson(alloc, conn.stream, "{\"type\":\"error\",\"message\":\"'message' must be string\"}");
        try ws.sendClose(conn.stream);
        return;
    }
    const message = msg_v.string;

    // Set up a streaming callback that sends WS text frames
    const WsCtx = struct {
        stream: std.net.Stream,
        alloc: std.mem.Allocator,
    };
    var ws_ctx = WsCtx{ .stream = conn.stream, .alloc = alloc };

    const cb = base.StreamCallback{
        .ctx = &ws_ctx,
        .run = struct {
            fn run(ctx: *anyopaque, delta: base.StreamDelta) anyerror!void {
                const c: *WsCtx = @ptrCast(@alignCast(ctx));
                switch (delta) {
                    .text => |t| {
                        // Send as {"type":"text","content":"..."}
                        var buf = std.ArrayList(u8).init(c.alloc);
                        defer buf.deinit();
                        try buf.appendSlice("{\"type\":\"text\",\"content\":");
                        try writeJsonStr(&buf, t);
                        try buf.append('}');
                        try ws.sendText(c.stream, buf.items);
                    },
                    .tool_call => |tc| {
                        if (tc.name) |name| {
                            var buf = std.ArrayList(u8).init(c.alloc);
                            defer buf.deinit();
                            try buf.appendSlice("{\"type\":\"tool\",\"name\":");
                            try writeJsonStr(&buf, name);
                            try buf.append('}');
                            try ws.sendText(c.stream, buf.items);
                        }
                    },
                    .done => {},
                }
            }
        }.run,
        .enabled = true,
    };
    agent.stream_cb = cb;
    defer agent.stream_cb = null;

    // Run the agent
    var result = agent.run(message) catch |e| {
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice("{\"type\":\"error\",\"message\":");
        try writeJsonStr(&buf, @errorName(e));
        try buf.append('}');
        try wsSendJson(alloc, conn.stream, buf.items);
        try ws.sendClose(conn.stream);
        return;
    };
    defer result.deinit(alloc);

    // Send done frame
    var done_buf = std.ArrayList(u8).init(alloc);
    defer done_buf.deinit();
    try done_buf.writer().print(
        "{{\"type\":\"done\",\"steps\":{d},\"tool_calls\":{d},\"input_tokens\":{d},\"output_tokens\":{d}}}",
        .{ result.steps_taken, result.tool_calls_made, result.usage.input_tokens, result.usage.output_tokens },
    );
    try wsSendJson(alloc, conn.stream, done_buf.items);
    try ws.sendClose(conn.stream);
}

fn wsSendJson(alloc: std.mem.Allocator, stream: std.net.Stream, json: []const u8) !void {
    _ = alloc;
    try ws.sendText(stream, json);
}

fn handleChat(alloc: std.mem.Allocator, conn: std.net.Server.Connection, agent: *loop.Agent, body: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        try sendJson(conn, "{\"error\":\"invalid JSON\"}");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try sendJson(conn, "{\"error\":\"expected object\"}");
        return;
    }
    const msg_v = parsed.value.object.get("message") orelse {
        try sendJson(conn, "{\"error\":\"missing 'message'\"}");
        return;
    };
    if (msg_v != .string) {
        try sendJson(conn, "{\"error\":\"'message' must be string\"}");
        return;
    }
    const message = msg_v.string;

    var result = agent.run(message) catch |e| {
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        try buf.appendSlice("{\"error\":\"agent failed: ");
        try writeJsonStr(&buf, @errorName(e));
        try buf.appendSlice("\"}");
        try sendJson(conn, buf.items);
        return;
    };
    defer result.deinit(alloc);

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("{\"response\":");
    try writeJsonStr(&buf, result.answer);
    try buf.writer().print(
        ",\"steps\":{d},\"tool_calls\":{d},\"input_tokens\":{d},\"output_tokens\":{d}}}",
        .{
            result.steps_taken,
            result.tool_calls_made,
            result.usage.input_tokens,
            result.usage.output_tokens,
        },
    );
    try sendJson(conn, buf.items);
}

fn handleHistory(alloc: std.mem.Allocator, conn: std.net.Server.Connection, agent: *loop.Agent) !void {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice("{\"messages\":[");
    for (agent.messages.items, 0..) |m, i| {
        if (i > 0) try buf.append(',');
        const role_s = switch (m.role) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
        try buf.appendSlice("{\"role\":\"");
        try buf.appendSlice(role_s);
        try buf.appendSlice("\",\"content\":");
        try writeJsonStr(&buf, m.content);
        try buf.append('}');
    }
    try buf.appendSlice("]}");
    try sendJson(conn, buf.items);
}

fn sendHtml(conn: std.net.Server.Connection, body: []const u8) !void {
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
    try conn.stream.writeAll(hdr);
    try conn.stream.writeAll(body);
}

fn sendJson(conn: std.net.Server.Connection, body: []const u8) !void {
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
    try conn.stream.writeAll(hdr);
    try conn.stream.writeAll(body);
}

fn sendStatus(conn: std.net.Server.Connection, code: u16, msg: []const u8) !void {
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ code, msg });
    try conn.stream.writeAll(hdr);
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

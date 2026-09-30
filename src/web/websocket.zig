// Minimal WebSocket server for live streaming of agent output.
//
// Implements RFC 6455 framing (server side, no masking on send, unmask on recv).
// Used by the web UI's /ws endpoint to stream agent text deltas as they arrive.
//
// Protocol: pun sends JSON frames:
//   {"type":"text","content":"..."}     — a text delta
//   {"type":"tool","name":"..."}        — a tool call started
//   {"type":"done","steps":N,...}       — agent finished
//   {"type":"error","message":"..."}    — error
//
// The client sends one message: {"message":"..."} to start the agent.

const std = @import("std");

pub const WsError = error{
    InvalidHandshake,
    InvalidFrame,
    ConnectionClosed,
};

/// Perform the WebSocket handshake on an accepted connection.
/// `key` is the value of the `Sec-WebSocket-Key` request header.
pub fn handshake(key: []const u8) [28]u8 {
    // Concatenate key + magic GUID, SHA-1, base64
    const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var concat: [60]u8 = undefined;
    @memcpy(concat[0..24], key);
    @memcpy(concat[24..60], guid);

    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(&concat);
    var digest: [20]u8 = undefined;
    sha.final(&digest);

    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

/// Parse the Sec-WebSocket-Key from a raw HTTP request.
pub fn extractKey(request: []const u8) ?[]const u8 {
    const needle = "Sec-WebSocket-Key:";
    const idx = std.mem.indexOf(u8, request, needle) orelse return null;
    const start = idx + needle.len;
    var s = start;
    while (s < request.len and (request[s] == ' ' or request[s] == '\t')) s += 1;
    var e = s;
    while (e < request.len and request[e] != '\r' and request[e] != '\n') e += 1;
    return request[s..e];
}

/// Send a WebSocket text frame.
pub fn sendText(stream: std.net.Stream, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    var header_len: usize = 2;

    header[0] = 0x81; // FIN + text frame

    if (payload.len <= 125) {
        header[1] = @intCast(payload.len);
    } else if (payload.len <= 65535) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        header_len = 10;
    }

    try stream.writeAll(header[0..header_len]);
    try stream.writeAll(payload);
}

/// Send a WebSocket close frame.
pub fn sendClose(stream: std.net.Stream) !void {
    const frame = [_]u8{ 0x88, 0x00 }; // FIN + close, no payload
    try stream.writeAll(&frame);
}

/// Read one WebSocket frame from the stream. Returns the unmasked payload
/// (allocated from `alloc`; caller frees). Only handles text frames (0x1)
/// and close frames (0x8). Returns null on close frame.
pub fn readFrame(alloc: std.mem.Allocator, stream: std.net.Stream) !?[]u8 {
    var header: [2]u8 = undefined;
    _ = try stream.readAll(&header);

    const opcode = header[0] & 0x0f;
    const masked = (header[1] & 0x80) != 0;
    var payload_len: u64 = header[1] & 0x7f;

    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        _ = try stream.readAll(&ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        _ = try stream.readAll(&ext);
        payload_len = std.mem.readInt(u64, &ext, .big);
    }

    var mask: [4]u8 = undefined;
    if (masked) {
        _ = try stream.readAll(&mask);
    }

    const payload = try alloc.alloc(u8, payload_len);
    errdefer alloc.free(payload);
    _ = try stream.readAll(payload);

    if (masked) {
        for (payload, 0..) |*b, i| b.* ^= mask[i % 4];
    }

    if (opcode == 0x8) {
        // Close frame
        alloc.free(payload);
        return null;
    }

    return payload;
}

test "handshake: RFC 6455 example" {
    // From RFC 6455 Section 4.2.2
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = handshake(key);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "extractKey: from request" {
    const req = "GET /ws HTTP/1.1\r\nHost: example.com\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    const key = extractKey(req).?;
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", key);
}

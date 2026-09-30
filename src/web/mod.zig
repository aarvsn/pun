// Web UI subsystem: HTTP server with a chat interface + WebSocket streaming.
pub const server = @import("server.zig");
pub const websocket = @import("websocket.zig");
pub const tls = @import("tls.zig");
pub const run = server.run;
test {
    @import("std").testing.refAllDecls(@This());
}

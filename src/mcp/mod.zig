// MCP subsystem: pun can act as an MCP server (JSON-RPC 2.0 over stdio).
pub const server = @import("server.zig");
pub const run = server.run;
test {
    @import("std").testing.refAllDecls(@This());
}

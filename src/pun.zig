// pun — top-level module re-exporting all subsystems.
//
// All other source files import this as `@import("pun.zig")` to reach siblings.
// Adding a new subsystem = create a folder under src/ + add it here.

pub const version = "0.7.0";

pub const types = @import("types.zig");
pub const errors = @import("errors.zig");
pub const util = @import("util.zig");
pub const regex = @import("regex.zig");

pub const config = @import("config/mod.zig");
pub const security = @import("security/mod.zig");
pub const providers = @import("providers/mod.zig");
pub const tools = @import("tools/mod.zig");
pub const loop = @import("loop/mod.zig");
pub const tui = @import("tui/mod.zig");
pub const cli = @import("cli/mod.zig");
pub const mcp = @import("mcp/mod.zig");
pub const web = @import("web/mod.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

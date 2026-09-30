// CLI subsystem: oneshot + batch.

pub const oneshot = @import("oneshot.zig");
pub const batch = @import("batch.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

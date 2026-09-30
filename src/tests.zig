// Test entrypoint — `zig build test` runs this.
//
// Each module already has inline tests; this file just refs them all.

const std = @import("std");

test {
    _ = @import("pun.zig");
}

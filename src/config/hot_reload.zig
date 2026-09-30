// Hot-reload: SIGHUP handler that signals the agent loop to refresh its config.
//
// install() registers a signal handler for SIGHUP that sets a global atomic
// flag. The main loop (or TUI) periodically calls reloadRequested() and,
// if true, calls apply() to swap in a fresh config.

const std = @import("std");
const config = @import("schema.zig");

var reload_flag = std.atomic.Value(bool).init(false);
var cfg_path_storage: ?[]u8 = null;
var cfg_path_alloc: ?std.mem.Allocator = null;

/// Install the SIGHUP handler. `cfg_path` is dup'd into the provided allocator
/// and stored for later reloads. Safe to call once at startup.
pub fn install(alloc: std.mem.Allocator, cfg_path: ?[]const u8) !void {
    if (cfg_path) |p| {
        if (cfg_path_storage) |old| {
            if (cfg_path_alloc) |a| a.free(old);
        }
        cfg_path_storage = try alloc.dupe(u8, p);
        cfg_path_alloc = alloc;
    }

    const sa = std.posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.HUP, &sa, null);
}

/// Signal handler — sets the reload flag.
fn handler(_: c_int) callconv(.c) void {
    const expected: bool = false;
    _ = reload_flag.cmpxchgStrong(expected, true, .seq_cst, .seq_cst);
}

/// Returns true once after each SIGHUP (then resets the flag).
pub fn reloadRequested() bool {
    return reload_flag.swap(false, .seq_cst);
}

/// Apply a reload: deinit the old config and replace it with fresh defaults
/// (the caller can then reload from disk on top of defaults if it wants).
/// NOTE: the caller owns the `cfg_ptr` storage and the new Config; this
/// function only deinit's the old one and constructs defaults in place.
pub fn apply(cfg_ptr: **config.Config) !void {
    const alloc = cfg_ptr.*.alloc;
    cfg_ptr.*.deinit();
    cfg_ptr.* = try config.defaultConfig(alloc);
}

test "hot_reload: reloadRequested flag toggles" {
    // Cannot actually install SIGHUP in a unit test (racey with other tests),
    // but we can verify the swap logic by manually setting the flag.
    reload_flag.store(true, .seq_cst);
    try std.testing.expect(reloadRequested());
    try std.testing.expect(!reloadRequested());
}

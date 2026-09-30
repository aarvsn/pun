// uuid.zig — example pun plugin written in Zig.
//
// Provides one tool, "uuid4", that generates a random RFC 4122 v4 UUID.
//
// Build:
//   zig build-lib -dynamic -fPIC uuid.zig
// Install:
//   mkdir -p ~/.pun/plugins && cp uuid.so ~/.pun/plugins/
//
// NOTE: the run_fn uses [*c] pointer types (not *) to match the C ABI.

const std = @import("std");

// Match the C SDK from pun_plugin.h.
const PluginRegistry = extern struct {
    add: *const fn (
        self: ?*PluginRegistry,
        name: [*c]const u8,
        description: [*c]const u8,
        parameters_json: [*c]const u8,
        run_fn: PluginRunFn,
    ) callconv(.C) c_int,
    reg_ctx: ?*anyopaque,
};

const PluginRunFn = *const fn (
    tool_ctx: ?*anyopaque,
    alloc: ?*anyopaque,
    args_json: [*c]const u8,
    out_ptr: [*c][*c]u8,
    out_len: [*c]usize,
    is_error: [*c]bool,
) callconv(.C) c_int;

export fn pun_plugin_register(reg: ?*PluginRegistry, tool_ctx: ?*anyopaque) callconv(.C) c_int {
    const r = reg orelse return -1;
    _ = tool_ctx;
    return r.add(
        r,
        "uuid4",
        "Generate a random RFC 4122 v4 UUID and return it as a 36-char lowercase string.",
        "{\"type\":\"object\",\"properties\":{}}",
        uuid_run,
    );
}

fn uuid_run(
    tool_ctx: ?*anyopaque,
    alloc: ?*anyopaque,
    args_json: [*c]const u8,
    out_ptr: [*c][*c]u8,
    out_len: [*c]usize,
    is_error: [*c]bool,
) callconv(.C) c_int {
    _ = tool_ctx;
    _ = alloc;
    _ = args_json;
    is_error.* = false;

    // 16 random bytes
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    // Set version (4) and variant (10xx)
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    // Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    var uuid: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 0;
    var p: usize = 0;
    while (i < 16) : (i += 1) {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            uuid[p] = '-';
            p += 1;
        }
        uuid[p] = hex[bytes[i] >> 4];
        uuid[p + 1] = hex[bytes[i] & 0x0F];
        p += 2;
    }

    // malloc a buffer + copy
    const buf = std.c.malloc(36);
    if (buf == null) return 1;
    @memcpy(@as([*]u8, @ptrCast(buf))[0..36], &uuid);
    out_ptr.* = @ptrCast(buf);
    out_len.* = 36;
    return 0;
}

test "uuid format is 36 chars" {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    var uuid: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 0;
    var p: usize = 0;
    while (i < 16) : (i += 1) {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            uuid[p] = '-';
            p += 1;
        }
        uuid[p] = hex[bytes[i] >> 4];
        uuid[p + 1] = hex[bytes[i] & 0x0F];
        p += 2;
    }
    try std.testing.expectEqual(@as(usize, 36), uuid.len);
    try std.testing.expectEqual(@as(u8, '-'), uuid[8]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[13]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[18]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[23]);
}

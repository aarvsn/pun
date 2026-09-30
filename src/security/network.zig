// Network policy guard — per-host egress allowlist.

const std = @import("std");
const regex = @import("../regex.zig");
const PunError = @import("../errors.zig").PunError;

pub const NetworkGuard = struct {
    allowlist: [][]u8,
    denylist_compiled: []regex.Regex,
    default_allow: bool,
    alloc: std.mem.Allocator,

    pub fn init(
        alloc: std.mem.Allocator,
        allowlist: [][]u8,
        denylist: [][]u8,
        default_allow: bool,
    ) !NetworkGuard {
        var compiled = try alloc.alloc(regex.Regex, denylist.len);
        errdefer alloc.free(compiled);
        for (denylist, 0..) |p, i| compiled[i] = try regex.Regex.compile(alloc, p);
        return .{
            .allowlist = allowlist,
            .denylist_compiled = compiled,
            .default_allow = default_allow,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *NetworkGuard) void {
        for (self.denylist_compiled) |*rx| rx.deinit();
        self.alloc.free(self.denylist_compiled);
    }

    pub fn check(self: *NetworkGuard, url: []const u8) !void {
        const host = extractHost(url) orelse return error.NetworkBlocked;
        for (self.denylist_compiled) |*rx| {
            if (rx.match(host) != null) return error.NetworkBlocked;
        }
        for (self.allowlist) |a| {
            if (std.ascii.eqlIgnoreCase(a, host)) return;
        }
        if (self.allowlist.len == 0 and self.default_allow) return;
        return error.NetworkBlocked;
    }
};

fn extractHost(url: []const u8) ?[]const u8 {
    // strip scheme
    var rest = url;
    if (std.mem.indexOf(u8, url, "://")) |i| rest = url[i + 3 ..];
    // strip path
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest = rest[0..i];
    // strip user@ and :port
    if (std.mem.indexOfScalar(u8, rest, '@')) |i| rest = rest[i + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, ':')) |i| rest = rest[0..i];
    if (rest.len == 0) return null;
    return rest;
}

test "extractHost" {
    try std.testing.expectEqualStrings("api.example.com", extractHost("https://api.example.com/v1/chat").?);
    try std.testing.expectEqualStrings("api.example.com", extractHost("http://api.example.com").?);
    try std.testing.expectEqualStrings("api.example.com", extractHost("api.example.com:8080/path").?);
    try std.testing.expectEqualStrings("api.example.com", extractHost("https://user:pass@api.example.com").?);
}

test "NetworkGuard: allowlist" {
    const alloc = std.testing.allocator;
    var allow: [][]u8 = try alloc.alloc([]u8, 1);
    defer {
        for (allow) |s| alloc.free(s);
        alloc.free(allow);
    }
    allow[0] = try alloc.dupe(u8, "api.anthropic.com");
    const deny: [][]u8 = try alloc.alloc([]u8, 0);
    defer alloc.free(deny);
    var g = try NetworkGuard.init(alloc, allow, deny, false);
    defer g.deinit();
    try g.check("https://api.anthropic.com/v1/messages");
    try std.testing.expectError(error.NetworkBlocked, g.check("https://evil.example.com"));
}

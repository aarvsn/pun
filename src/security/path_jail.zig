// PathJail — confine file reads/writes to a workspace root.

const std = @import("std");
const util = @import("../util.zig");
const PunError = @import("../errors.zig").PunError;

pub const PathJail = struct {
    root: []const u8, // already expanded, absolute
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, root: []const u8) !PathJail {
        const expanded = try util.expandPath(alloc, root);
        defer alloc.free(expanded);
        // Make absolute if not already
        const abs: []u8 = if (std.fs.path.isAbsolute(expanded))
            try alloc.dupe(u8, expanded)
        else
            try std.fs.cwd().realpathAlloc(alloc, expanded);
        // Ensure exists
        std.fs.cwd().makePath(abs) catch {};
        return .{ .root = abs, .alloc = alloc };
    }

    pub fn deinit(self: *PathJail) void {
        self.alloc.free(self.root);
    }

    /// Resolve `p` relative to the jail root. Returns owned absolute path.
    /// Returns error.PathJailViolation if the resolved path escapes root.
    pub fn resolve(self: *PathJail, p: []const u8) ![]u8 {
        const expanded = try util.expandPath(self.alloc, p);
        defer self.alloc.free(expanded);

        var resolved: []u8 = undefined;
        if (std.fs.path.isAbsolute(expanded)) {
            resolved = try self.alloc.dupe(u8, expanded);
        } else {
            resolved = try std.fs.path.join(self.alloc, &.{ self.root, expanded });
        }
        defer self.alloc.free(resolved);

        // Normalize ".." by walking components
        const normalized = try normalize(self.alloc, resolved);
        defer self.alloc.free(normalized);

        // Symlink-resolve the parent dir if it exists
        var final: []u8 = undefined;
        if (std.fs.cwd().realpathAlloc(self.alloc, normalized)) |real| {
            final = real;
        } else |_| {
            // File doesn't exist yet — resolve parent and append basename
            if (std.fs.path.dirname(normalized)) |dir| {
                if (std.fs.cwd().realpathAlloc(self.alloc, dir)) |real_dir| {
                    defer self.alloc.free(real_dir);
                    if (std.fs.path.basename(normalized).len > 0) {
                        final = try std.fs.path.join(self.alloc, &.{ real_dir, std.fs.path.basename(normalized) });
                    } else {
                        final = try self.alloc.dupe(u8, real_dir);
                    }
                } else |_| {
                    final = try self.alloc.dupe(u8, normalized);
                }
            } else {
                final = try self.alloc.dupe(u8, normalized);
            }
        }

        if (!util.isPathInside(self.root, final)) {
            self.alloc.free(final);
            return error.PathJailViolation;
        }
        return final;
    }

    pub fn assertInside(self: *PathJail, p: []const u8) PunError!void {
        const r = try self.resolve(p);
        defer self.alloc.free(r);
    }
};

/// Normalize a path: remove "." segments, collapse ".." with previous segment.
fn normalize(alloc: std.mem.Allocator, p: []const u8) ![]u8 {
    var parts = std.ArrayList([]const u8).init(alloc);
    defer parts.deinit();
    var it = std.mem.tokenizeScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".") or seg.len == 0) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(seg);
    }
    if (std.fs.path.isAbsolute(p)) {
        var out = std.ArrayList(u8).init(alloc);
        errdefer out.deinit();
        try out.append('/');
        for (parts.items, 0..) |seg, i| {
            if (i > 0) try out.append('/');
            try out.appendSlice(seg);
        }
        return try out.toOwnedSlice();
    }
    return std.mem.join(alloc, "/", parts.items);
}

test "normalize: collapses .. and ." {
    const alloc = std.testing.allocator;
    const out = try normalize(alloc, "/a/b/../c/./d");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("/a/c/d", out);
}

test "PathJail: rejects escape" {
    const alloc = std.testing.allocator;
    const tmp = "/tmp/pun_test_jail";
    defer std.fs.cwd().deleteTree(tmp) catch {};
    var jail = try PathJail.init(alloc, tmp);
    defer jail.deinit();

    const inside = try jail.resolve("foo/bar.txt");
    defer alloc.free(inside);
    try std.testing.expect(util.isPathInside(tmp, inside));

    try std.testing.expectError(error.PathJailViolation, jail.resolve("../../etc/passwd"));
}

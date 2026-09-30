// Small utility helpers shared across the codebase.
//
// Everything here is allocator-explicit and panic-free.

const std = @import("std");

/// Read a file into an owned buffer. Returns NotFound if missing.
pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try alloc.alloc(u8, stat.size);
    errdefer alloc.free(buf);
    _ = try f.readAll(buf);
    return buf;
}

/// Write a buffer to disk, creating parent dirs.
pub fn writeFile(alloc: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }
    var f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(content);
    _ = alloc; // unused; kept for API symmetry
}

/// Expand ~ and $VAR in a path string. Returns owned memory.
pub fn expandPath(alloc: std.mem.Allocator, p: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    var i: usize = 0;
    if (p.len >= 2 and p[0] == '~' and (p[1] == '/' or p.len == 1)) {
        const home = std.process.getEnvVarOwned(alloc, "HOME") catch try alloc.dupe(u8, ".");
        defer alloc.free(home);
        try buf.appendSlice(home);
        if (p.len > 1) i = 1; // keep the '/'
    }
    while (i < p.len) {
        if (p[i] == '$') {
            // env var name: [A-Za-z_][A-Za-z0-9_]*
            var j: usize = i + 1;
            if (j < p.len and (std.ascii.isAlphabetic(p[j]) or p[j] == '_')) {
                while (j < p.len and (std.ascii.isAlphanumeric(p[j]) or p[j] == '_')) j += 1;
                const name = p[i + 1 .. j];
                const val = std.process.getEnvVarOwned(alloc, name) catch "";
                defer if (val.len > 0) alloc.free(val);
                try buf.appendSlice(val);
                i = j;
                continue;
            }
        }
        try buf.append(p[i]);
        i += 1;
    }
    return try buf.toOwnedSlice();
}

/// Resolve a path against a base dir. Absolute paths are kept; relative are
/// joined to base. Both inputs must be already expanded.
pub fn resolveUnder(alloc: std.mem.Allocator, base: []const u8, p: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(p)) return alloc.dupe(u8, p);
    return std.fs.path.join(alloc, &.{ base, p });
}

/// Check if `child` is inside `parent` (both resolved, absolute).
pub fn isPathInside(parent: []const u8, child: []const u8) bool {
    if (!std.fs.path.isAbsolute(parent) or !std.fs.path.isAbsolute(child)) return false;
    if (parent.len == 1 and parent[0] == '/') return child.len > 0;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    return child[parent.len] == '/';
}

/// Format a timestamp as ISO 8601 (for the audit log). Returns owned.
pub fn isoNow(alloc: std.mem.Allocator) ![]u8 {
    const ts: i64 = std.time.timestamp();
    return isoFromUnix(alloc, ts);
}

pub fn isoFromUnix(alloc: std.mem.Allocator, ts: i64) ![]u8 {
    const epoch_seconds: u64 = @intCast(ts);
    const day_seconds = epoch_seconds % (24 * 3600);
    const days_since_epoch = epoch_seconds / (24 * 3600);

    // Convert days since 1970-01-01 to (year, month, day) — Howard Hinnant's algorithm.
    const z = days_since_epoch + 719468;
    const era = z / 146097;
    const doe = z - era * 146097;
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;

    const hour = day_seconds / 3600;
    const minute = (day_seconds % 3600) / 60;
    const second = day_seconds % 60;

    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year, m, d, hour, minute, second,
    });
}

/// Ask a y/N question on stdin. Returns true for yes.
pub fn askYesNo(prompt: []const u8) !bool {
    const stderr = std.io.getStdErr().writer();
    try stderr.print("{s} [y/N]: ", .{prompt});
    var buf: [16]u8 = undefined;
    const stdin = std.io.getStdIn().reader();
    const line = (stdin.readUntilDelimiterOrEof(&buf, '\n') catch null) orelse return false;
    return line.len > 0 and (line[0] == 'y' or line[0] == 'Y');
}

/// Stable id generator (counter + timestamp). Good enough for tool-call ids.
var id_counter: u64 = 0;
pub fn genId(alloc: std.mem.Allocator, prefix: []const u8) ![]u8 {
    id_counter += 1;
    const ts: u64 = @intCast(std.time.timestamp());
    return std.fmt.allocPrint(alloc, "{s}_{x}_{x}", .{ prefix, ts, id_counter });
}

/// Constant-time string compare. Used for secrets.
pub fn constTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

test "expandPath: tilde" {
    const alloc = std.testing.allocator;
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch "/tmp";
    defer alloc.free(home);
    const out = try expandPath(alloc, "~/foo");
    defer alloc.free(out);
    try std.testing.expectEqualStrings(home, out[0..home.len]);
    try std.testing.expectEqualStrings("/foo", out[home.len..]);
}

test "isPathInside: basic" {
    try std.testing.expect(isPathInside("/a", "/a/b"));
    try std.testing.expect(isPathInside("/a", "/a"));
    try std.testing.expect(!isPathInside("/a", "/ab"));
    try std.testing.expect(!isPathInside("/a", "/b"));
}

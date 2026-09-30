// File tools: read_file, write_file, edit_file, glob, grep.
//
// All paths are resolved through the security policy's PathJail.

const std = @import("std");
const types = @import("../types.zig");
const registry = @import("registry.zig");
const util = @import("../util.zig");

pub fn registerAll(reg: *registry.Registry, ctx: *registry.ToolContext) !void {
    _ = ctx;
    try reg.add(.{
        .name = "read_file",
        .description = "Read a UTF-8 text file from the workspace. Returns its contents.",
        .parameters_schema =
            \\{"type":"object","properties":{"path":{"type":"string","description":"Path relative to workspace root."}},"required":["path"]}
        ,
        .run = runReadFile,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "write_file",
        .description = "Write content to a file in the workspace. Creates parent dirs. Overwrites if exists.",
        .parameters_schema =
            \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        ,
        .run = runWriteFile,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "edit_file",
        .description = "Apply a single find-and-replace edit to a file. Errors if old_text is not unique or not found.",
        .parameters_schema =
            \\{"type":"object","properties":{"path":{"type":"string"},"old_text":{"type":"string"},"new_text":{"type":"string"}},"required":["path","old_text","new_text"]}
        ,
        .run = runEditFile,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "list_dir",
        .description = "List entries in a directory under the workspace.",
        .parameters_schema =
            \\{"type":"object","properties":{"path":{"type":"string","description":"Directory path; default '.'"}}}
        ,
        .run = runListDir,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "grep",
        .description = "Recursive case-insensitive substring search under a path.",
        .parameters_schema =
            \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string","description":"Directory to search; default '.'"}},"required":["pattern"]}
        ,
        .run = runGrep,
        .ctx = undefined,
    });
}

fn runReadFile(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const obj = args.value.object;
    const path_v = obj.get("path") orelse return errorResult(alloc, "missing 'path'");
    if (path_v != .string) return errorResult(alloc, "'path' must be a string");
    const path = path_v.string;

    const abs = c.policy.resolvePath(path) catch |e| return errorResult(alloc, @errorName(e));
    defer alloc.free(abs);

    const content = util.readFile(alloc, abs) catch |e| return errorResult(alloc, @errorName(e));
    try c.policy.audit_log.log(.file_write, "read_file", path);
    return .{ .content = content };
}

fn runWriteFile(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const obj = args.value.object;
    const path_v = obj.get("path") orelse return errorResult(alloc, "missing 'path'");
    const content_v = obj.get("content") orelse return errorResult(alloc, "missing 'content'");
    if (path_v != .string or content_v != .string) return errorResult(alloc, "invalid args");
    const path = path_v.string;
    const content = content_v.string;

    const abs = c.policy.resolvePath(path) catch |e| return errorResult(alloc, @errorName(e));
    defer alloc.free(abs);

    // Confirm if outside workspace (rare since resolvePath would've failed)
    const granted = c.policy.confirmWrite(path) catch |e| return errorResult(alloc, @errorName(e));
    if (!granted) return errorResult(alloc, "write denied by user");

    util.writeFile(alloc, abs, content) catch |e| return errorResult(alloc, @errorName(e));
    var summary_buf: [256]u8 = undefined;
    const summary = try std.fmt.bufPrint(&summary_buf, "wrote {d} bytes to {s}", .{ content.len, path });
    try c.policy.audit_log.log(.file_write, summary, path);

    return .{ .content = try alloc.dupe(u8, summary) };
}

fn runEditFile(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const obj = args.value.object;
    const path_v = obj.get("path") orelse return errorResult(alloc, "missing 'path'");
    const old_v = obj.get("old_text") orelse return errorResult(alloc, "missing 'old_text'");
    const new_v = obj.get("new_text") orelse return errorResult(alloc, "missing 'new_text'");
    if (path_v != .string or old_v != .string or new_v != .string) return errorResult(alloc, "invalid args");

    const abs = c.policy.resolvePath(path_v.string) catch |e| return errorResult(alloc, @errorName(e));
    defer alloc.free(abs);

    const content = util.readFile(alloc, abs) catch |e| return errorResult(alloc, @errorName(e));
    defer alloc.free(content);

    // Count matches
    var count: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        if (std.mem.indexOfPos(u8, content, i, old_v.string)) |j| {
            count += 1;
            i = j + old_v.string.len;
        } else break;
    }
    if (count == 0) return errorResult(alloc, "old_text not found");
    if (count > 1) return errorResult(alloc, "old_text is not unique (matches > 1)");

    // Replace
    const idx = std.mem.indexOf(u8, content, old_v.string).?;
    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    try out.appendSlice(content[0..idx]);
    try out.appendSlice(new_v.string);
    try out.appendSlice(content[idx + old_v.string.len ..]);
    const new_content = try out.toOwnedSlice();
    defer alloc.free(new_content);

    util.writeFile(alloc, abs, new_content) catch |e| return errorResult(alloc, @errorName(e));
    try c.policy.audit_log.log(.file_write, "edit_file", path_v.string);
    return .{ .content = try alloc.dupe(u8, "ok") };
}

fn runListDir(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const path = if (args.value.object.get("path")) |v| (if (v == .string) v.string else ".") else ".";
    const abs = c.policy.resolvePath(path) catch |e| return errorResult(alloc, @errorName(e));
    defer alloc.free(abs);

    var dir = std.fs.cwd().openDir(abs, .{ .iterate = true }) catch |e| return errorResult(alloc, @errorName(e));
    defer dir.close();
    var it = dir.iterate();
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    var first = true;
    while (try it.next()) |e| {
        if (!first) try buf.append('\n');
        first = false;
        try buf.appendSlice(e.name);
        if (e.kind == .directory) try buf.append('/');
    }
    return .{ .content = try buf.toOwnedSlice() };
}

fn runGrep(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const pat = args.value.object.get("pattern") orelse return errorResult(alloc, "missing 'pattern'");
    if (pat != .string) return errorResult(alloc, "'pattern' must be string");
    const path = if (args.value.object.get("path")) |v| (if (v == .string) v.string else ".") else ".";

    const abs = c.policy.resolvePath(path) catch |e| return errorResult(alloc, @errorName(e));
    defer alloc.free(abs);

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    try grepRecursive(alloc, abs, pat.string, &out);
    if (out.items.len == 0) {
        return .{ .content = try alloc.dupe(u8, "(no matches)") };
    }
    return .{ .content = try out.toOwnedSlice() };
}

fn grepRecursive(alloc: std.mem.Allocator, dir_path: []const u8, pattern: []const u8, out: *std.ArrayList(u8)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind == .directory and e.name.len > 0 and e.name[0] == '.') continue;
        const sub = try std.fs.path.join(alloc, &.{ dir_path, e.name });
        defer alloc.free(sub);
        if (e.kind == .directory) {
            try grepRecursive(alloc, sub, pattern, out);
        } else if (e.kind == .file) {
            const content = util.readFile(alloc, sub) catch continue;
            defer alloc.free(content);
            // Line-by-line case-insensitive
            var lines = std.mem.splitScalar(u8, content, '\n');
            var line_no: usize = 0;
            while (lines.next()) |line| {
                line_no += 1;
                if (std.ascii.indexOfIgnoreCase(line, pattern) != null) {
                    try out.appendSlice(sub);
                    try out.writer().print(":{d}: ", .{line_no});
                    try out.appendSlice(line);
                    try out.append('\n');
                }
            }
        }
    }
}

fn errorResult(alloc: std.mem.Allocator, msg: []const u8) types.ToolResult {
    return .{
        .content = alloc.dupe(u8, msg) catch "",
        .is_error = true,
    };
}

test "registerAll registers 5 file tools" {
    var cfg = try @import("../config/schema.zig").defaultConfig(std.testing.allocator);
    defer cfg.deinit();
    var p = try @import("../security/mod.zig").SecurityPolicy.init(std.testing.allocator, &cfg);
    defer p.deinit();
    var reg = registry.Registry.init(std.testing.allocator);
    defer reg.deinit();
    var ctx = registry.ToolContext{
        .alloc = std.testing.allocator,
        .cfg = &cfg,
        .policy = &p,
        .workspace = cfg.security.workspace,
    };
    try registerAll(&reg, &ctx);
    try std.testing.expectEqual(@as(usize, 5), reg.tools.items.len);
}

// Git tools: git_status, git_diff, git_commit, git_log.
//
// All git ops run inside the workspace sandbox. `git push` is intentionally
// NOT exposed.

const std = @import("std");
const types = @import("../types.zig");
const registry = @import("registry.zig");

pub fn registerAll(reg: *registry.Registry, ctx: *registry.ToolContext) !void {
    _ = ctx;
    try reg.add(.{
        .name = "git_status",
        .description = "Run `git status --short` in the workspace.",
        .parameters_schema =
            \\{"type":"object","properties":{}}
        ,
        .run = runGitStatus,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "git_diff",
        .description = "Run `git diff` in the workspace.",
        .parameters_schema =
            \\{"type":"object","properties":{"staged":{"type":"boolean","description":"Diff staged changes (git diff --cached)."}}}
        ,
        .run = runGitDiff,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "git_commit",
        .description = "Run `git commit -am <message>` in the workspace. No push.",
        .parameters_schema =
            \\{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}
        ,
        .run = runGitCommit,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "git_log",
        .description = "Run `git log --oneline -n <n>` in the workspace.",
        .parameters_schema =
            \\{"type":"object","properties":{"n":{"type":"integer","description":"Number of commits; default 10"}}}
        ,
        .run = runGitLog,
        .ctx = undefined,
    });
}

fn runGit(alloc: std.mem.Allocator, c: *registry.ToolContext, args: []const []const u8) anyerror!types.ToolResult {
    // Build a single command string for policy check
    var cmd = std.ArrayList(u8).init(alloc);
    defer cmd.deinit();
    try cmd.appendSlice("git");
    for (args) |a| {
        try cmd.append(' ');
        try cmd.appendSlice(a);
    }

    const dec = c.policy.checkShell(cmd.items) catch |e| return errorResult(alloc, @errorName(e));
    if (!dec.allowed) return errorResult(alloc, "git not in allowlist");

    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, alloc);
    child.cwd = c.workspace;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    var env_map = std.process.EnvMap.init(alloc);
    defer env_map.deinit();
    for (c.cfg.shell.env_passthrough) |name| {
        if (std.process.getEnvVarOwned(alloc, name) catch null) |val| {
            defer alloc.free(val);
            try env_map.put(name, val);
        }
    }
    child.env_map = &env_map;
    child.spawn() catch |e| return errorResult(alloc, @errorName(e));

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stderr_buf: [16 * 1024]u8 = undefined;
    const stdout_len = if (child.stdout) |s| (s.read(&stdout_buf) catch 0) else 0;
    const stderr_len = if (child.stderr) |s| (s.read(&stderr_buf) catch 0) else 0;
    const term = child.wait() catch |e| return errorResult(alloc, @errorName(e));
    const exit_code: i32 = switch (term) {
        .Exited => |c2| c2,
        else => -1,
    };
    try c.policy.audit_log.logShellExec(cmd.items, exit_code);

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    if (stdout_len > 0) try out.appendSlice(stdout_buf[0..stdout_len]);
    if (stderr_len > 0) {
        try out.appendSlice("\n--- stderr ---\n");
        try out.appendSlice(stderr_buf[0..stderr_len]);
    }
    return .{
        .content = try out.toOwnedSlice(),
        .is_error = exit_code != 0,
    };
}

fn runGitStatus(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    _ = args;
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    return runGit(alloc, c, &.{ "status", "--short" });
}

fn runGitDiff(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const staged = if (args.value.object.get("staged")) |v| (if (v == .bool) v.bool else false) else false;
    if (staged) return runGit(alloc, c, &.{ "diff", "--cached" });
    return runGit(alloc, c, &.{"diff"});
}

fn runGitCommit(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const msg_v = args.value.object.get("message") orelse return errorResult(alloc, "missing 'message'");
    if (msg_v != .string) return errorResult(alloc, "'message' must be string");
    return runGit(alloc, c, &.{ "commit", "-am", msg_v.string });
}

fn runGitLog(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    var n_buf: [16]u8 = undefined;
    const n: i64 = if (args.value.object.get("n")) |v| (if (v == .integer) v.integer else 10) else 10;
    const n_str = try std.fmt.bufPrint(&n_buf, "{d}", .{n});
    return runGit(alloc, c, &.{ "log", "--oneline", "-n", n_str });
}

fn errorResult(alloc: std.mem.Allocator, msg: []const u8) types.ToolResult {
    return .{
        .content = alloc.dupe(u8, msg) catch "",
        .is_error = true,
    };
}

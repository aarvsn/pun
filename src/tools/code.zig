// Code exec tools: run_python, run_zig.
//
// run_python: write a temp file, execute `python3 <file>` in the shell sandbox.
// run_zig:    write a temp file, execute `zig run <file>` in the shell sandbox.
//
// Both reuse the shell tool's policy / sandbox settings.

const std = @import("std");
const types = @import("../types.zig");
const registry = @import("registry.zig");
const util = @import("../util.zig");

pub fn registerAll(reg: *registry.Registry, ctx: *registry.ToolContext) !void {
    _ = ctx;
    try reg.add(.{
        .name = "run_python",
        .description = "Run a Python script in the sandbox. Returns stdout+stderr and exit code.",
        .parameters_schema =
            \\{"type":"object","properties":{"code":{"type":"string"}},"required":["code"]}
        ,
        .run = runPython,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "run_zig",
        .description = "Run a Zig script in the sandbox via `zig run`. Returns stdout+stderr and exit code.",
        .parameters_schema =
            \\{"type":"object","properties":{"code":{"type":"string"}},"required":["code"]}
        ,
        .run = runZig,
        .ctx = undefined,
    });
}

fn runPython(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    return runLang(alloc, ctx, args, "python3", ".py");
}

fn runZig(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    return runLang(alloc, ctx, args, "zig run", ".zig");
}

fn runLang(
    alloc: std.mem.Allocator,
    ctx: anytype,
    args: std.json.Parsed(std.json.Value),
    bin: []const u8,
    ext: []const u8,
) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const code_v = args.value.object.get("code") orelse return errorResult(alloc, "missing 'code'");
    if (code_v != .string) return errorResult(alloc, "'code' must be string");

    // Write temp file in workspace
    const ts: u64 = @intCast(std.time.timestamp());
    const tmp_name = try std.fmt.allocPrint(alloc, ".pun_tmp_{x}{s}", .{ ts, ext });
    defer alloc.free(tmp_name);
    const tmp_abs = try c.policy.resolvePath(tmp_name);
    defer {
        std.fs.cwd().deleteFile(tmp_abs) catch {};
        alloc.free(tmp_abs);
    }
    util.writeFile(alloc, tmp_abs, code_v.string) catch |e| return errorResult(alloc, @errorName(e));

    // Build command. `zig run` takes the file as arg, so we need it in the allowlist.
    // For python3 we run `python3 <file>`.
    const cmd = if (std.mem.eql(u8, bin, "zig run"))
        try std.fmt.allocPrint(alloc, "zig run {s}", .{tmp_name})
    else
        try std.fmt.allocPrint(alloc, "{s} {s}", .{ bin, tmp_name });
    defer alloc.free(cmd);

    // Policy check
    const dec = c.policy.checkShell(cmd) catch |e| return errorResult(alloc, @errorName(e));
    if (!dec.allowed) return errorResult(alloc, "command not allowed");

    const argv = [_][]const u8{ "/bin/sh", "-c", cmd };
    var env_map = std.process.EnvMap.init(alloc);
    defer env_map.deinit();
    for (c.cfg.shell.env_passthrough) |name| {
        if (std.process.getEnvVarOwned(alloc, name) catch null) |val| {
            defer alloc.free(val);
            try env_map.put(name, val);
        }
    }

    var child = std.process.Child.init(&argv, alloc);
    child.cwd = c.workspace;
    child.env_map = &env_map;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |e| return errorResult(alloc, @errorName(e));

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stderr_buf: [32 * 1024]u8 = undefined;
    const stdout_len = if (child.stdout) |s| (s.read(&stdout_buf) catch 0) else 0;
    const stderr_len = if (child.stderr) |s| (s.read(&stderr_buf) catch 0) else 0;
    const term = child.wait() catch |e| return errorResult(alloc, @errorName(e));
    const exit_code: i32 = switch (term) {
        .Exited => |c2| c2,
        else => -1,
    };
    try c.policy.audit_log.logShellExec(cmd, exit_code);

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    try out.writer().print("exit: {d}\n--- stdout ---\n", .{exit_code});
    if (stdout_len > 0) try out.appendSlice(stdout_buf[0..stdout_len]);
    try out.appendSlice("\n--- stderr ---\n");
    if (stderr_len > 0) try out.appendSlice(stderr_buf[0..stderr_len]);
    return .{
        .content = try out.toOwnedSlice(),
        .is_error = exit_code != 0,
    };
}

fn errorResult(alloc: std.mem.Allocator, msg: []const u8) types.ToolResult {
    return .{
        .content = alloc.dupe(u8, msg) catch "",
        .is_error = true,
    };
}

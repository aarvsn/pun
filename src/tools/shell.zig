// Shell tool: run_command (sandboxed, with timer-based SIGKILL).
//
// Pipeline:
// 1. policy.checkShell(command) → CommandDecision (or CommandBlocked)
// 2. Spawn subprocess with cwd=jail.root, env_passthrough, network off
// 3. Start a watchdog thread that sleeps for `timeout_seconds`, then SIGKILLs
// 4. Read stdout/stderr up to caps
// 5. Wait for exit; if killed by watchdog, report timeout

const std = @import("std");
const types = @import("../types.zig");
const registry = @import("registry.zig");

pub fn registerAll(reg: *registry.Registry, ctx: *registry.ToolContext) !void {
    _ = ctx;
    try reg.add(.{
        .name = "run_command",
        .description =
            "Run a shell command in the workspace sandbox. Subject to allowlist, denylist, and timeout. " ++
            "Network access and sudo are off by default. Returns stdout+stderr (up to 64KB) and exit code. " ++
            "Hard-killed via SIGKILL after timeout_seconds.",
        .parameters_schema =
            \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command to run."},"timeout_seconds":{"type":"integer","description":"Per-step timeout override; default 30."}},"required":["command"]}
        ,
        .run = runCommand,
        .ctx = undefined,
    });
}

const WatchdogCtx = struct {
    pid: std.process.Child.Id,
    deadline_ns: i128,
    fired: *bool,
};

fn watchdogThread(ctx: *WatchdogCtx) void {
    // Sleep until deadline, then check if process still alive; if so, SIGKILL.
    const now_ns: i128 = std.time.nanoTimestamp();
    if (now_ns >= ctx.deadline_ns) {
        // Already past deadline — kill immediately
        killProcess(ctx.pid);
        ctx.fired.* = true;
        return;
    }
    const sleep_ns: u64 = @intCast(ctx.deadline_ns - now_ns);
    std.time.sleep(sleep_ns);
    // Re-check: the parent may have already reaped the child.
    // We can't easily check "is pid alive" without /proc, so just try to kill.
    // kill(pid, 0) returns success if pid exists; ESRCH if not.
    const r = std.posix.kill(ctx.pid, 0);
    if (r) |_| {
        killProcess(ctx.pid);
        ctx.fired.* = true;
    } else |_| {
        // Process already exited — don't fire
    }
}

fn killProcess(pid: std.process.Child.Id) void {
    // SIGKILL the whole process group (negative pid) so children die too.
    // First try -pid (group kill); if that fails, fall back to just pid.
    _ = std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
    _ = std.posix.kill(pid, std.posix.SIG.KILL) catch {};
}

fn runCommand(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const obj = args.value.object;
    const cmd_v = obj.get("command") orelse return errorResult(alloc, "missing 'command'");
    if (cmd_v != .string) return errorResult(alloc, "'command' must be string");
    const command = cmd_v.string;
    const timeout = if (obj.get("timeout_seconds")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else c.cfg.shell.timeout_seconds) else c.cfg.shell.timeout_seconds;

    // If shell is disabled by config/CLI, refuse
    if (c.cfg.shell_disabled) return errorResult(alloc, "shell tool disabled by --no-shell");

    // Policy check
    const dec = c.policy.checkShell(command) catch |e| return errorResult(alloc, @errorName(e));
    if (!dec.allowed) return errorResult(alloc, "command not allowed");

    // Build argv. If docker_image is set, wrap with `docker run`.
    var argv_owned: ?[][]u8 = null;
    defer if (argv_owned) |a| {
        for (a) |s| alloc.free(s);
        alloc.free(a);
    };

    var env_map = std.process.EnvMap.init(alloc);
    defer env_map.deinit();
    for (c.cfg.shell.env_passthrough) |name| {
        if (std.process.getEnvVarOwned(alloc, name) catch null) |val| {
            defer alloc.free(val);
            try env_map.put(name, val);
        }
    }
    // If network is disabled, override common network env vars
    if (!c.cfg.shell.allow_network) {
        try env_map.put("http_proxy", "");
        try env_map.put("https_proxy", "");
        try env_map.put("HTTP_PROXY", "");
        try env_map.put("HTTPS_PROXY", "");
        try env_map.put("no_proxy", "*");
    }

    var child: std.process.Child = undefined;
    if (c.cfg.shell.docker_image) |img| {
        // Verify docker is on PATH
        if (std.process.getEnvVarOwned(alloc, "PATH") catch null) |path_val| {
            defer alloc.free(path_val);
            const docker_path = findInPath(alloc, path_val, "docker") catch null;
            defer if (docker_path) |p| alloc.free(p);
            if (docker_path == null) {
                return errorResult(alloc, "shell.docker_image is set but 'docker' is not on PATH");
            }
        }

        // docker run --rm -i --network=none -v <workspace>:/work -w /work <image> sh -c <command>
        var docker_args = std.ArrayList([]u8).init(alloc);
        defer docker_args.deinit();
        try docker_args.append(try alloc.dupe(u8, "docker"));
        try docker_args.append(try alloc.dupe(u8, "run"));
        try docker_args.append(try alloc.dupe(u8, "--rm"));
        try docker_args.append(try alloc.dupe(u8, "-i"));
        if (!c.cfg.shell.allow_network) {
            try docker_args.append(try alloc.dupe(u8, "--network=none"));
        }
        const mount = try std.fmt.allocPrint(alloc, "-v{s}:/work", .{c.workspace});
        try docker_args.append(mount);
        try docker_args.append(try alloc.dupe(u8, "-w"));
        try docker_args.append(try alloc.dupe(u8, "/work"));
        try docker_args.append(try alloc.dupe(u8, img));
        try docker_args.append(try alloc.dupe(u8, "sh"));
        try docker_args.append(try alloc.dupe(u8, "-c"));
        try docker_args.append(try alloc.dupe(u8, command));
        argv_owned = try docker_args.toOwnedSlice();

        child = std.process.Child.init(argv_owned.?, alloc);
    } else {
        // Direct: sh -c <command>
        const argv = [_][]const u8{ "/bin/sh", "-c", command };
        child = std.process.Child.init(&argv, alloc);
    }
    child.cwd = c.workspace;
    child.env_map = &env_map;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |e| return errorResult(alloc, @errorName(e));
    errdefer _ = child.kill() catch {};

    // Start watchdog thread
    var fired: bool = false;
    const timeout_ns: i128 = @as(i128, timeout) * std.time.ns_per_s;
    var wd_ctx = WatchdogCtx{
        .pid = child.id,
        .deadline_ns = std.time.nanoTimestamp() + timeout_ns,
        .fired = &fired,
    };
    const wd_thread = std.Thread.spawn(.{}, watchdogThread, .{&wd_ctx}) catch null;
    defer if (wd_thread) |t| t.detach();

    // Read stdout/stderr (blocking; watchdog will kill if it takes too long)
    const stdout_buf = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(stdout_buf);
    const stderr_buf = try alloc.alloc(u8, 32 * 1024);
    defer alloc.free(stderr_buf);

    var stdout_len: usize = 0;
    var stderr_len: usize = 0;

    if (child.stdout) |s| {
        stdout_len = s.read(stdout_buf) catch 0;
    }
    if (child.stderr) |s| {
        stderr_len = s.read(stderr_buf) catch 0;
    }

    const term = child.wait() catch |e| return errorResult(alloc, @errorName(e));
    const exit_code: i32 = switch (term) {
        .Exited => |c2| c2,
        .Signal => |sig| -@as(i32, @intCast(sig)),
        else => -1,
    };

    try c.policy.audit_log.logShellExec(command, exit_code);

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    if (fired) {
        try out.appendSlice("TIMEOUT: process killed after ");
        try out.writer().print("{d}s\n", .{timeout});
    }
    try out.writer().print("exit: {d}\n--- stdout ---\n", .{exit_code});
    if (stdout_len > 0) try out.appendSlice(stdout_buf[0..stdout_len]);
    try out.appendSlice("\n--- stderr ---\n");
    if (stderr_len > 0) try out.appendSlice(stderr_buf[0..stderr_len]);

    const is_err = exit_code != 0 or fired;
    return .{
        .content = try out.toOwnedSlice(),
        .is_error = is_err,
    };
}

/// Search PATH for an executable. Returns owned path or null.
fn findInPath(alloc: std.mem.Allocator, path_val: []const u8, name: []const u8) !?[]u8 {
    var it = std.mem.tokenizeScalar(u8, path_val, ':');
    while (it.next()) |dir| {
        const candidate = try std.fs.path.join(alloc, &.{ dir, name });
        defer alloc.free(candidate);
        if (std.fs.cwd().access(candidate, .{})) |_| {
            return try alloc.dupe(u8, candidate);
        } else |_| continue;
    }
    return null;
}

fn errorResult(alloc: std.mem.Allocator, msg: []const u8) types.ToolResult {
    return .{
        .content = alloc.dupe(u8, msg) catch "",
        .is_error = true,
    };
}

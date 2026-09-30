// Orchestration tools: spawn multiple sub-agents in parallel or in a chain.
//
// - spawn_agents_parallel: N tasks → N OS threads → N sub-agents → joined results
// - spawn_agent_chain:    N prompts → sequential sub-agents, each sees the prior output
//
// Both require the .subagent_spawn confirmation gate (the parent user is
// delegating autonomy to multiple sub-agents in parallel).

const std = @import("std");
const types = @import("../types.zig");
const registry = @import("registry.zig");
const providers = @import("../providers/mod.zig");
const loop = @import("../loop/mod.zig");
const base = @import("../providers/base.zig");

const MAX_AGENTS = 8;

pub fn registerAll(reg: *registry.Registry, ctx: *registry.ToolContext) !void {
    _ = ctx;
    try reg.add(.{
        .name = "spawn_agents_parallel",
        .description =
            "Spawn up to " ++ "8" ++ " sub-agents in parallel (one OS thread each), each given its own prompt. " ++
            "Returns a JSON array of {prompt, answer, error?} objects. Useful for independent tasks.",
        .parameters_schema =
            \\{"type":"object","properties":{"tasks":{"type":"array","items":{"type":"object","properties":{"prompt":{"type":"string"},"max_steps":{"type":"integer"}},"required":["prompt"]}}},"required":["tasks"]}
        ,
        .run = runParallel,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "spawn_agent_chain",
        .description =
            "Run sub-agents sequentially, feeding each one the output of the previous. " ++
            "Returns a JSON array of {prompt, answer, error?} objects.",
        .parameters_schema =
            \\{"type":"object","properties":{"prompts":{"type":"array","items":{"type":"string"}},"max_steps":{"type":"integer"}},"required":["prompts"]}
        ,
        .run = runChain,
        .ctx = undefined,
    });
}

// ---- parallel ----

const ParallelTask = struct {
    prompt: []u8,
    max_steps: u32,
};

const ParallelResult = struct {
    prompt: []u8,
    answer: []u8,
    err: ?[]u8 = null,
};

const ParallelCtx = struct {
    alloc: std.mem.Allocator,
    cfg: *@import("../config/schema.zig").Config,
    policy: *@import("../security/mod.zig").SecurityPolicy,
    provider: ?*providers.Provider,
    task: ParallelTask,
    result: ?ParallelResult = null,
};

fn parallelThread(ctx_raw: *anyopaque) void {
    const pc: *ParallelCtx = @ptrCast(@alignCast(ctx_raw));
    pc.result = runOneParallel(pc) catch |e| blk: {
        const err_msg = std.fmt.allocPrint(pc.alloc, "thread error: {}", .{e}) catch
            break :blk ParallelResult{
            .prompt = pc.alloc.dupe(u8, pc.task.prompt) catch "",
            .answer = pc.alloc.dupe(u8, "") catch "",
            .err = pc.alloc.dupe(u8, "thread error: alloc failed") catch null,
        };
        break :blk ParallelResult{
            .prompt = pc.alloc.dupe(u8, pc.task.prompt) catch "",
            .answer = pc.alloc.dupe(u8, "") catch "",
            .err = err_msg,
        };
    };
}

fn runOneParallel(pc: *ParallelCtx) !ParallelResult {
    // Clone the policy so this thread has its own (the parent policy may be mutated concurrently)
    var cloned = try pc.policy.clone();
    defer cloned.deinit();
    var sub = try loop.Agent.init(pc.alloc, pc.cfg, &cloned, pc.provider orelse return error.NoProvider);
    defer sub.deinit();
    sub.max_steps = pc.task.max_steps;
    sub.planner_enabled = false;
    var result = sub.run(pc.task.prompt) catch |e| {
        const err_msg = try std.fmt.allocPrint(pc.alloc, "error: {}", .{e});
        return .{
            .prompt = try pc.alloc.dupe(u8, pc.task.prompt),
            .answer = try pc.alloc.dupe(u8, ""),
            .err = err_msg,
        };
    };
    defer result.deinit(pc.alloc);
    return .{
        .prompt = try pc.alloc.dupe(u8, pc.task.prompt),
        .answer = try pc.alloc.dupe(u8, result.answer),
    };
}

fn runParallel(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    if (c.provider == null) return errorResult(alloc, "no provider configured for sub-agent");

    const tasks_v = args.value.object.get("tasks") orelse return errorResult(alloc, "missing 'tasks'");
    if (tasks_v != .array) return errorResult(alloc, "'tasks' must be array");
    if (tasks_v.array.items.len == 0) return errorResult(alloc, "'tasks' is empty");
    if (tasks_v.array.items.len > MAX_AGENTS)
        return errorResult(alloc, "too many tasks (max 8)");

    // Confirmation gate — the parent user is delegating to multiple agents
    const granted = c.policy.gate.confirm(.subagent_spawn, "parallel agents") catch false;
    if (!granted) return errorResult(alloc, "spawn denied by user");

    var tasks = try alloc.alloc(ParallelTask, tasks_v.array.items.len);
    defer {
        for (tasks) |t| alloc.free(t.prompt);
        alloc.free(tasks);
    }
    for (tasks_v.array.items, 0..) |t, i| {
        if (t != .object) return errorResult(alloc, "task must be object");
        const p_v = t.object.get("prompt") orelse return errorResult(alloc, "missing 'prompt'");
        if (p_v != .string) return errorResult(alloc, "'prompt' must be string");
        const ms: u32 = if (t.object.get("max_steps")) |v| (if (v == .integer) @intCast(v.integer) else 5) else 5;
        tasks[i] = .{
            .prompt = try alloc.dupe(u8, p_v.string),
            .max_steps = ms,
        };
    }

    // Spawn one thread per task
    var ctxs = try alloc.alloc(ParallelCtx, tasks.len);
    defer alloc.free(ctxs);
    var threads = try alloc.alloc(std.Thread, tasks.len);
    defer alloc.free(threads);

    for (tasks, 0..) |t, i| {
        ctxs[i] = .{
            .alloc = alloc,
            .cfg = c.cfg,
            .policy = c.policy,
            .provider = c.provider,
            .task = .{
                .prompt = try alloc.dupe(u8, t.prompt),
                .max_steps = t.max_steps,
            },
        };
        threads[i] = try std.Thread.spawn(.{}, parallelThread, .{&ctxs[i]});
    }
    // Join all
    for (threads) |*th| th.join();

    // Collect + format results as JSON
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    try buf.append('[');
    for (ctxs, 0..) |pc, i| {
        if (i > 0) try buf.append(',');
        const r = pc.result orelse {
            try buf.appendSlice("{\"prompt\":");
            try writeJsonStr(&buf, pc.task.prompt);
            try buf.appendSlice(",\"answer\":\"\",\"error\":\"no result\"}");
            continue;
        };
        try buf.appendSlice("{\"prompt\":");
        try writeJsonStr(&buf, r.prompt);
        try buf.appendSlice(",\"answer\":");
        try writeJsonStr(&buf, r.answer);
        if (r.err) |e| {
            try buf.appendSlice(",\"error\":");
            try writeJsonStr(&buf, e);
        }
        try buf.append('}');
        // Free per-thread result memory
        alloc.free(r.prompt);
        alloc.free(r.answer);
        if (r.err) |e| alloc.free(e);
        // Free per-thread duped prompt
        alloc.free(pc.task.prompt);
    }
    try buf.append(']');

    return .{ .content = try buf.toOwnedSlice() };
}

// ---- chain ----

fn runChain(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    if (c.provider == null) return errorResult(alloc, "no provider configured for sub-agent");

    const prompts_v = args.value.object.get("prompts") orelse return errorResult(alloc, "missing 'prompts'");
    if (prompts_v != .array) return errorResult(alloc, "'prompts' must be array");
    if (prompts_v.array.items.len == 0) return errorResult(alloc, "'prompts' is empty");
    if (prompts_v.array.items.len > MAX_AGENTS)
        return errorResult(alloc, "too many prompts (max 8)");

    const granted = c.policy.gate.confirm(.subagent_spawn, "agent chain") catch false;
    if (!granted) return errorResult(alloc, "spawn denied by user");

    const max_steps: u32 = if (args.value.object.get("max_steps")) |v| (if (v == .integer) @intCast(v.integer) else 5) else 5;

    // Each chain step: append prior output to the prompt, then run.
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    try buf.append('[');

    var prev_answer: ?[]u8 = null;
    defer if (prev_answer) |p| alloc.free(p);

    for (prompts_v.array.items, 0..) |p_v, i| {
        if (p_v != .string) return errorResult(alloc, "each prompt must be string");
        if (i > 0) try buf.append(',');
        try buf.appendSlice("{\"prompt\":");
        try writeJsonStr(&buf, p_v.string);

        // Build the full prompt = user_prompt + prior output (if any)
        var full_prompt_buf = std.ArrayList(u8).init(alloc);
        defer full_prompt_buf.deinit();
        try full_prompt_buf.appendSlice(p_v.string);
        if (prev_answer) |pa| {
            try full_prompt_buf.appendSlice("\n\nPrevious step output:\n");
            try full_prompt_buf.appendSlice(pa);
        }

        var cloned = try c.policy.clone();
        defer cloned.deinit();
        var sub = try loop.Agent.init(alloc, c.cfg, &cloned, c.provider.?);
        defer sub.deinit();
        sub.max_steps = max_steps;
        sub.planner_enabled = false;
        var result = sub.run(full_prompt_buf.items) catch |e| {
            const err_msg = try std.fmt.allocPrint(alloc, "error: {}", .{e});
            try buf.appendSlice(",\"answer\":\"\",\"error\":");
            try writeJsonStr(&buf, err_msg);
            try buf.append('}');
            alloc.free(err_msg);
            if (prev_answer) |p| {
                alloc.free(p);
                prev_answer = null;
            }
            continue;
        };
        defer result.deinit(alloc);
        try buf.appendSlice(",\"answer\":");
        try writeJsonStr(&buf, result.answer);
        try buf.append('}');

        if (prev_answer) |p| alloc.free(p);
        prev_answer = try alloc.dupe(u8, result.answer);
    }
    try buf.append(']');
    return .{ .content = try buf.toOwnedSlice() };
}

fn errorResult(alloc: std.mem.Allocator, msg: []const u8) types.ToolResult {
    return .{
        .content = alloc.dupe(u8, msg) catch "",
        .is_error = true,
    };
}

fn writeJsonStr(buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append('"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            else => if (c < 0x20) {
                try buf.writer().print("\\u{x:0>4}", .{c});
            } else try buf.append(c),
        }
    }
    try buf.append('"');
}

test "orchestration: registerAll" {
    const alloc = std.testing.allocator;
    var cfg = try @import("../config/schema.zig").defaultConfig(alloc);
    defer cfg.deinit();
    alloc.free(cfg.security.workspace);
    cfg.security.workspace = try alloc.dupe(u8, "/tmp");
    alloc.free(cfg.security.audit_log);
    cfg.security.audit_log = try alloc.dupe(u8, "/tmp/pun_orch_test_audit.jsonl");
    defer std.fs.cwd().deleteFile("/tmp/pun_orch_test_audit.jsonl") catch {};
    alloc.free(cfg.security.vault_path);
    cfg.security.vault_path = try alloc.dupe(u8, "/tmp/pun_orch_test_vault.bin");
    defer std.fs.cwd().deleteFile("/tmp/pun_orch_test_vault.bin") catch {};

    var p = try @import("../security/mod.zig").SecurityPolicy.init(alloc, &cfg);
    defer p.deinit();

    var reg = registry.Registry.init(alloc);
    defer reg.deinit();
    var ctx = registry.ToolContext{
        .alloc = alloc,
        .cfg = &cfg,
        .policy = &p,
        .provider = null,
        .workspace = "/tmp",
    };
    try registerAll(&reg, &ctx);
    try std.testing.expect(reg.find("spawn_agents_parallel") != null);
    try std.testing.expect(reg.find("spawn_agent_chain") != null);
}

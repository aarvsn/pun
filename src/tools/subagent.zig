// Sub-agent tool: delegate a subtask to the same provider/model.
//
// v0.1 limitation: spawns a one-shot agent run synchronously, with a
// smaller max_tokens budget. The sub-agent inherits the parent's tools,
// policy, and provider, but starts with an empty message history.

const std = @import("std");
const types = @import("../types.zig");
const registry = @import("registry.zig");
const providers = @import("../providers/mod.zig");
const loop = @import("../loop/mod.zig");

pub fn registerAll(reg: *registry.Registry, ctx: *registry.ToolContext) !void {
    _ = ctx;
    try reg.add(.{
        .name = "spawn_agent",
        .description =
            "Delegate a subtask to a fresh sub-agent. The sub-agent inherits tools, provider, and policy. " ++
            "Returns the sub-agent's final answer text.",
        .parameters_schema =
            \\{"type":"object","properties":{"prompt":{"type":"string"},"max_steps":{"type":"integer","description":"Max loop iterations; default 5."}},"required":["prompt"]}
        ,
        .run = runSpawn,
        .ctx = undefined,
    });
}

fn runSpawn(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const c: *registry.ToolContext = @ptrCast(@alignCast(ctx));
    const p_v = args.value.object.get("prompt") orelse return errorResult(alloc, "missing 'prompt'");
    if (p_v != .string) return errorResult(alloc, "'prompt' must be string");
    const max_steps: u32 = if (args.value.object.get("max_steps")) |v| (if (v == .integer) @intCast(v.integer) else 5) else 5;

    if (c.provider == null) return errorResult(alloc, "no provider configured for sub-agent");
    const granted = c.policy.gate.confirm(.subagent_spawn, p_v.string) catch false;
    if (!granted) return errorResult(alloc, "sub-agent spawn denied by user");

    // Build a sub-agent with reduced max_steps
    var sub = try loop.Agent.init(alloc, c.cfg, c.policy, c.provider.?);
    defer sub.deinit();
    sub.max_steps = max_steps;
    var result = sub.run(p_v.string) catch |e| return errorResult(alloc, @errorName(e));
    // result owns its memory; we need to keep the answer text
    const out = try alloc.dupe(u8, result.answer);
    result.deinit(alloc);
    return .{ .content = out };
}

fn errorResult(alloc: std.mem.Allocator, msg: []const u8) types.ToolResult {
    return .{
        .content = alloc.dupe(u8, msg) catch "",
        .is_error = true,
    };
}

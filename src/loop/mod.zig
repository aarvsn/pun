// Hybrid agent loop: plan → execute (tool-calling) → re-plan.
//
// Loop:
//   1. On step 1 (or every N steps), call planner with a system prompt that
//      asks for a step plan in JSON. Parse into a list of step strings.
//   2. For each iteration: call the model with the full message history +
//      tool specs. If the model returns tool_calls, execute each via the
//      tool registry, append tool results, and continue.
//   3. After N steps or when the model returns a final text response with
//      no tool_calls, return AgentResult.
//
// The loop is governed by the token budget (security.budget_tracker) and
// max_steps.

const std = @import("std");
const types = @import("../types.zig");
const config = @import("../config/schema.zig");
const security = @import("../security/mod.zig");
const providers = @import("../providers/mod.zig");
const tools = @import("../tools/mod.zig");
pub const base = @import("../providers/base.zig");
pub const history = @import("history.zig");

pub const AgentResult = struct {
    answer: []u8,
    steps_taken: u32,
    tool_calls_made: u32,
    final_finish_reason: []u8,
    usage: types.Usage,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *AgentResult, alloc: std.mem.Allocator) void {
        alloc.free(self.answer);
        alloc.free(self.final_finish_reason);
    }
};

pub const Agent = struct {
    alloc: std.mem.Allocator,
    cfg: *config.Config,
    policy: *security.SecurityPolicy,
    provider: *providers.Provider,
    reg: tools.Registry,
    messages: std.ArrayList(types.Message),
    max_steps: u32 = 20,
    replan_every: u32 = 5,
    plan: std.ArrayList([]u8),
    /// Optional streaming callback. If set, the agent uses chatStream and
    /// forwards text deltas to this callback (e.g. for TUI live display).
    stream_cb: ?base.StreamCallback = null,
    /// If true, the planner LLM call is enabled (otherwise replan() is a no-op).
    planner_enabled: bool = true,

    pub fn init(
        alloc: std.mem.Allocator,
        cfg: *config.Config,
        policy: *security.SecurityPolicy,
        provider: *providers.Provider,
    ) !Agent {
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .policy = policy,
            .provider = provider,
            .reg = tools.Registry.init(alloc),
            .messages = std.ArrayList(types.Message).init(alloc),
            .plan = std.ArrayList([]u8).init(alloc),
        };
    }

    pub fn deinit(self: *Agent) void {
        self.reg.deinit();
        for (self.messages.items) |*m| m.deinit(self.alloc);
        self.messages.deinit();
        for (self.plan.items) |s| self.alloc.free(s);
        self.plan.deinit();
    }

    /// Run the agent loop on a single user prompt. Returns the final answer.
    pub fn run(self: *Agent, user_prompt: []const u8) !AgentResult {
        // Set up tool registry
        const ctx = try self.alloc.create(tools.ToolContext);
        defer self.alloc.destroy(ctx);
        ctx.* = .{
            .alloc = self.alloc,
            .cfg = self.cfg,
            .policy = self.policy,
            .provider = self.provider,
            .workspace = self.cfg.security.workspace,
            .stream_cb = if (self.stream_cb) |*cb| @as(*const base.StreamCallback, cb) else null,
        };
        try tools.registerAll(&self.reg, ctx);

        // System prompt
        const sys = try self.buildSystemPrompt();
        defer self.alloc.free(sys);

        // Append user message
        const user_msg = types.Message{
            .role = .user,
            .content = try self.alloc.dupe(u8, user_prompt),
        };
        try self.messages.append(user_msg);
        history.saveMessage(self.alloc, user_msg) catch {};

        // Initial plan (if planner enabled)
        if (self.planner_enabled) {
            self.makePlan(user_prompt, sys) catch |e| {
                // Planning failure is non-fatal — continue without a plan
                try self.policy.audit_log.log(.model_request, "planner failed", @errorName(e));
            };
        }

        var steps: u32 = 0;
        var tool_calls: u32 = 0;
        var last_finish: []u8 = try self.alloc.dupe(u8, "stop");
        var last_usage: types.Usage = .{};

        while (steps < self.max_steps) : (steps += 1) {
            self.policy.budget_tracker.startStep();

            // Re-plan periodically
            if (self.planner_enabled and steps > 0 and steps % self.replan_every == 0) {
                self.replan(user_prompt, sys) catch {};
            }

            // Build tool specs (v0.1: pass empty list; the model emits tool calls
            // opportunistically based on system-prompt descriptions)
            _ = try self.reg.specsJson(self.alloc);
            const tool_specs: []base.ToolSpec = &.{};

            // Build chat options
            const opts = base.ChatOptions{
                .model = if (self.cfg.active_model) |m| m else (self.cfg.getActiveProfile().?.model orelse ""),
                .temperature = self.cfg.getActiveProfile().?.temperature,
                .max_tokens = self.cfg.getActiveProfile().?.max_tokens,
                .system = sys,
                .tools = tool_specs,
            };

            // Audit log
            try self.policy.audit_log.logModelRequest(
                self.cfg.active_provider orelse "default",
                opts.model,
                0,
            );

            // Call provider (streaming if callback is set, otherwise buffered)
            var resp = if (self.stream_cb) |cb|
                self.provider.chatStream(self.alloc, self.messages.items, opts, cb) catch |e| blk: {
                    if (e == error.TokenBudgetExceeded) return e;
                    const err_msg = try std.fmt.allocPrint(self.alloc, "[provider error: {}]", .{e});
                    break :blk base.ChatResponse{
                        .message = .{
                            .role = .assistant,
                            .content = err_msg,
                        },
                        .finish_reason = try self.alloc.dupe(u8, "error"),
                        .usage = .{},
                        .alloc = self.alloc,
                    };
                }
            else
                self.provider.chat(self.alloc, self.messages.items, opts) catch |e| blk: {
                    if (e == error.TokenBudgetExceeded) return e;
                    const err_msg = try std.fmt.allocPrint(self.alloc, "[provider error: {}]", .{e});
                    break :blk base.ChatResponse{
                        .message = .{
                            .role = .assistant,
                            .content = err_msg,
                        },
                        .finish_reason = try self.alloc.dupe(u8, "error"),
                        .usage = .{},
                        .alloc = self.alloc,
                    };
                };

            try self.policy.audit_log.logModelResponse(
                self.cfg.active_provider orelse "default",
                opts.model,
                resp.usage.output_tokens,
                resp.finish_reason,
            );
            _ = try self.policy.spendTokens(resp.usage.input_tokens, resp.usage.output_tokens);

            // Free old finish, keep new
            self.alloc.free(last_finish);
            last_finish = try self.alloc.dupe(u8, resp.finish_reason);
            last_usage.input_tokens += resp.usage.input_tokens;
            last_usage.output_tokens += resp.usage.output_tokens;

            // If no tool calls, append assistant message and return
            if (resp.message.tool_calls.len == 0) {
                const asst_msg = types.Message{
                    .role = .assistant,
                    .content = try self.alloc.dupe(u8, resp.message.content),
                };
                try self.messages.append(asst_msg);
                history.saveMessage(self.alloc, asst_msg) catch {};
                resp.deinit();
                break;
            }

            // Append assistant message (with tool_calls)
            const asst_with_calls = types.Message{
                .role = .assistant,
                .content = try self.alloc.dupe(u8, resp.message.content),
                .tool_calls = try self.dupeToolCalls(resp.message.tool_calls),
            };
            try self.messages.append(asst_with_calls);
            history.saveMessage(self.alloc, asst_with_calls) catch {};

            // Execute each tool call
            for (resp.message.tool_calls) |tc| {
                tool_calls += 1;
                const result = self.reg.run(self.alloc, ctx, tc.name, tc.arguments_json) catch |e| blk: {
                    const msg = try std.fmt.allocPrint(self.alloc, "[tool {s} error: {}]", .{ tc.name, e });
                    break :blk types.ToolResult{ .content = msg, .is_error = true };
                };
                try self.policy.audit_log.logToolCall(tc.name, tc.arguments_json, result.content, result.is_error);
                const tool_msg = types.Message{
                    .role = .tool,
                    .content = result.content,
                    .tool_call_id = try self.alloc.dupe(u8, tc.id),
                    .name = try self.alloc.dupe(u8, tc.name),
                };
                try self.messages.append(tool_msg);
                history.saveMessage(self.alloc, tool_msg) catch {};
            }
            resp.deinit();
        }

        // Compose answer: last assistant message text
        var answer: []u8 = try self.alloc.dupe(u8, "");
        var i: usize = self.messages.items.len;
        while (i > 0) {
            i -= 1;
            const m = self.messages.items[i];
            if (m.role == .assistant and m.tool_calls.len == 0) {
                self.alloc.free(answer);
                answer = try self.alloc.dupe(u8, m.content);
                break;
            }
        }

        return .{
            .answer = answer,
            .steps_taken = steps,
            .tool_calls_made = tool_calls,
            .final_finish_reason = last_finish,
            .usage = last_usage,
            .alloc = self.alloc,
        };
    }

    fn buildSystemPrompt(self: *Agent) ![]u8 {
        const profile = self.cfg.getActiveProfile();
        const sys = if (profile) |p| (if (p.system_prompt) |s| s else null) else null;
        if (sys) |s| return self.alloc.dupe(u8, s);
        // Default system prompt
        return self.alloc.dupe(u8,
            \\You are pun, a BYOK AI coding agent.
            \\You have access to tools for file operations, shell execution, web fetch, code execution, git, todo management, sub-agent spawning, browser navigation, and persistent memory.
            \\When using tools, prefer the smallest scope that solves the task. Confirm risky actions with the user.
            \\After completing the task, respond with a concise summary — no tool calls.
        );
    }

    /// Initial planner call: ask the model for a step-by-step plan in JSON.
    /// Stores the result in self.plan. Non-fatal on failure.
    fn makePlan(self: *Agent, user_prompt: []const u8, sys: []const u8) !void {
        const planner_sys =
            \\You are a planning assistant. Given a task, produce a concise step-by-step plan.
            \\Respond with ONLY a JSON object: {"steps": ["step 1", "step 2", ...]}
            \\Each step should be a single sentence describing one action.
            \\Keep it to 3-8 steps. Do not include any other text.
        ;

        const planner_msgs = [_]types.Message{
            .{ .role = .user, .content = user_prompt },
        };

        const opts = base.ChatOptions{
            .model = if (self.cfg.active_model) |m| m else (self.cfg.getActiveProfile().?.model orelse ""),
            .temperature = 0.2,
            .max_tokens = 1024,
            .system = planner_sys,
        };

        try self.policy.audit_log.logModelRequest("planner", opts.model, 0);
        var resp = self.provider.chat(self.alloc, &planner_msgs, opts) catch return;
        defer resp.deinit();
        try self.policy.audit_log.logModelResponse("planner", opts.model, resp.usage.output_tokens, resp.finish_reason);
        _ = try self.policy.spendTokens(resp.usage.input_tokens, resp.usage.output_tokens);

        // Parse JSON: {"steps": ["...", "..."]}
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, resp.message.content, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const steps_v = parsed.value.object.get("steps") orelse return;
        if (steps_v != .array) return;

        for (steps_v.array.items) |step_v| {
            if (step_v != .string) continue;
            try self.plan.append(try self.alloc.dupe(u8, step_v.string));
        }

        // Log the plan
        if (self.plan.items.len > 0) {
            var summary = std.ArrayList(u8).init(self.alloc);
            defer summary.deinit();
            try summary.appendSlice("plan: ");
            for (self.plan.items, 0..) |s, i| {
                if (i > 0) try summary.appendSlice(" | ");
                try summary.appendSlice(s);
            }
            try self.policy.audit_log.log(.model_response, summary.items, null);
        }
        _ = sys;
    }

    /// Re-plan: ask the model to revise the plan given progress so far.
    fn replan(self: *Agent, user_prompt: []const u8, sys: []const u8) !void {
        // Clear the old plan
        for (self.plan.items) |s| self.alloc.free(s);
        self.plan.clearRetainingCapacity();

        // Build a summary of progress: last few messages
        var progress = std.ArrayList(u8).init(self.alloc);
        defer progress.deinit();
        try progress.appendSlice("Task: ");
        try progress.appendSlice(user_prompt);
        try progress.appendSlice("\n\nProgress so far:\n");
        const start: usize = if (self.messages.items.len > 6) self.messages.items.len - 6 else 0;
        for (self.messages.items[start..]) |m| {
            const role_s = switch (m.role) {
                .user => "user",
                .assistant => "assistant",
                .tool => "tool",
                .system => "system",
            };
            try progress.writer().print("[{s}] {s:.200}\n", .{ role_s, m.content });
        }

        const planner_sys =
            \\You are a planning assistant. Given a task and progress so far, produce a revised step-by-step plan.
            \\Respond with ONLY a JSON object: {"steps": ["step 1", "step 2", ...]}
            \\Each step should be a single sentence describing one action.
            \\Keep it to 3-8 steps. Do not include any other text.
        ;

        const planner_msgs = [_]types.Message{
            .{ .role = .user, .content = progress.items },
        };

        const opts = base.ChatOptions{
            .model = if (self.cfg.active_model) |m| m else (self.cfg.getActiveProfile().?.model orelse ""),
            .temperature = 0.2,
            .max_tokens = 1024,
            .system = planner_sys,
        };

        try self.policy.audit_log.logModelRequest("replanner", opts.model, 0);
        var resp = self.provider.chat(self.alloc, &planner_msgs, opts) catch return;
        defer resp.deinit();
        try self.policy.audit_log.logModelResponse("replanner", opts.model, resp.usage.output_tokens, resp.finish_reason);
        _ = try self.policy.spendTokens(resp.usage.input_tokens, resp.usage.output_tokens);

        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, resp.message.content, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const steps_v = parsed.value.object.get("steps") orelse return;
        if (steps_v != .array) return;

        for (steps_v.array.items) |step_v| {
            if (step_v != .string) continue;
            try self.plan.append(try self.alloc.dupe(u8, step_v.string));
        }

        if (self.plan.items.len > 0) {
            var summary = std.ArrayList(u8).init(self.alloc);
            defer summary.deinit();
            try summary.appendSlice("replan: ");
            for (self.plan.items, 0..) |s, i| {
                if (i > 0) try summary.appendSlice(" | ");
                try summary.appendSlice(s);
            }
            try self.policy.audit_log.log(.model_response, summary.items, null);
        }
        _ = sys;
    }

    fn dupeToolCalls(self: *Agent, src: []const types.ToolCall) ![]types.ToolCall {
        var out = try self.alloc.alloc(types.ToolCall, src.len);
        for (src, 0..) |tc, i| {
            out[i] = .{
                .id = try self.alloc.dupe(u8, tc.id),
                .name = try self.alloc.dupe(u8, tc.name),
                .arguments_json = try self.alloc.dupe(u8, tc.arguments_json),
            };
        }
        return out;
    }
};

test "Agent: init/deinit" {
    var cfg = try config.defaultConfig(std.testing.allocator);
    defer cfg.deinit();
    // Override paths to tmp (cfg.deinit will free them)
    std.testing.allocator.free(cfg.security.workspace);
    cfg.security.workspace = try std.testing.allocator.dupe(u8, "/tmp");
    std.testing.allocator.free(cfg.shell.workspace);
    cfg.shell.workspace = try std.testing.allocator.dupe(u8, "/tmp");
    std.testing.allocator.free(cfg.security.audit_log);
    cfg.security.audit_log = try std.testing.allocator.dupe(u8, "/tmp/pun_agent_test_audit.jsonl");
    defer std.fs.cwd().deleteFile("/tmp/pun_agent_test_audit.jsonl") catch {};
    std.testing.allocator.free(cfg.security.vault_path);
    cfg.security.vault_path = try std.testing.allocator.dupe(u8, "/tmp/pun_agent_test_vault.bin");
    defer std.fs.cwd().deleteFile("/tmp/pun_agent_test_vault.bin") catch {};

    var p = try security.SecurityPolicy.init(std.testing.allocator, &cfg);
    defer p.deinit();
}

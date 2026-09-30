// TUI app — raw ANSI, line-based.
//
// Layout (top to bottom):
//   ┌─────────────────────────── pun ───────────────────────────┐
//   │ chat history (scrollable)                                 │
//   │ ...                                                       │
//   ├──────────────────────────────────────────────────────────┤
//   │ tool output (last 5 lines, scrollable)                    │
//   ├──────────────────────────────────────────────────────────┤
//   │ todos                                                     │
//   ├──────────────────────────────────────────────────────────┤
//   │ status: profile=x provider=y tokens=z/N                  │
//   ├──────────────────────────────────────────────────────────┤
//   │ > user input                                              │
//   └──────────────────────────────────────────────────────────┘
//
// Commands:  /quit  /clear  /model  /provider  /profile  /help
//
// v0.1: synchronous loop — agent runs to completion before next prompt.
// v0.2: background agent + incremental redraw.

const std = @import("std");
const config = @import("../config/schema.zig");
const security = @import("../security/mod.zig");
const providers = @import("../providers/mod.zig");
const tools = @import("../tools/mod.zig");
const loop = @import("../loop/mod.zig");

/// Module-level state for the streaming callback (TUI is single-threaded).
var tui_stream_first_chunk: bool = true;

extern "c" fn getpid() c_int;

fn streamCallbackRun(_: *anyopaque, delta: loop.base.StreamDelta) anyerror!void {
    const w = std.io.getStdErr().writer();
    switch (delta) {
        .text => |t| {
            if (tui_stream_first_chunk) {
                tui_stream_first_chunk = false;
                try w.print("\n", .{});
            }
            try w.writeAll(t);
        },
        .tool_call => |tc| {
            if (tui_stream_first_chunk) {
                tui_stream_first_chunk = false;
                try w.print("\n", .{});
            }
            if (tc.name) |name| {
                try w.print("[tool: {s}]\n", .{name});
            }
        },
        .done => {},
    }
}

pub fn run(alloc: std.mem.Allocator, cfg: *config.Config) !void {
    var policy = try security.SecurityPolicy.init(alloc, cfg);
    defer policy.deinit();

    // Resolve active provider from profile
    const profile = cfg.getActiveProfile() orelse {
        try stderrPrint("error: no active profile configured. Run `pun config init`.\n", .{});
        std.process.exit(1);
    };
    if (cfg.active_provider == null) {
        if (cfg.providers.get(profile.provider)) |p| {
            try cfg.setActiveProvider(p.name);
        }
    }
    if (cfg.active_model == null) {
        if (profile.model) |m| cfg.setActiveModel(m);
    }

    const provider = providers.getProvider(alloc, cfg, &policy, cfg.active_provider.?) catch |e| {
        try stderrPrint("error: failed to init provider {s}: {}\n", .{ profile.provider, e });
        try stderrPrint("hint: set your API key via env var or `pun vault set {s} <key>`\n", .{profile.provider});
        std.process.exit(1);
    };
    defer providers.freeProvider(alloc, provider);

    var agent = try loop.Agent.init(alloc, cfg, &policy, provider);
    defer agent.deinit();

    // Set up streaming callback that prints text deltas live to stderr.
    // The TUI is single-threaded so a module-level var is safe.
    tui_stream_first_chunk = true;

    agent.stream_cb = .{
        .ctx = undefined,
        .run = streamCallbackRun,
    };

    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();
    var buf: [8192]u8 = undefined;

    try printBanner(cfg, profile);

    while (true) {
        try stderr.print("\n> ", .{});
        const line = (stdin.readUntilDelimiterOrEof(&buf, '\n') catch null) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/exit")) break;
        if (std.mem.eql(u8, trimmed, "/clear")) {
            for (agent.messages.items) |*m| m.deinit(alloc);
            agent.messages.clearRetainingCapacity();
            try stderr.print("(history cleared)\n", .{});
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/reload")) {
            const c_pid = getpid();
            _ = std.posix.kill(@intCast(c_pid), std.posix.SIG.HUP) catch |e| {
                try stderr.print("reload failed: {}\n", .{e});
            };
            try stderr.print("(reload requested)\n", .{});
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/help")) {
            try printHelp();
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/profile ")) {
            const name = trimmed[9..];
            if (cfg.profiles.contains(name)) {
                alloc.free(cfg.active_profile);
                cfg.active_profile = try alloc.dupe(u8, name);
                try stderr.print("switched to profile {s}\n", .{name});
            } else try stderr.print("no such profile: {s}\n", .{name});
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/model ")) {
            const m = trimmed[7..];
            cfg.setActiveModel(m);
            try stderr.print("model set to {s}\n", .{m});
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/plan")) {
            if (agent.plan.items.len == 0) {
                try stderr.print("(no plan yet)\n", .{});
            } else {
                try stderr.print("current plan:\n", .{});
                for (agent.plan.items, 0..) |s, i| {
                    try stderr.print("  {d}. {s}\n", .{ i + 1, s });
                }
            }
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/noplan")) {
            agent.planner_enabled = !agent.planner_enabled;
            try stderr.print("planner: {}\n", .{agent.planner_enabled});
            continue;
        }

        // Reset stream state for this turn
        tui_stream_first_chunk = true;

        // Run agent
        var result = agent.run(trimmed) catch |e| {
            try stderr.print("agent error: {}\n", .{e});
            continue;
        };
        defer result.deinit(alloc);
        try stderr.print("\n\n[steps={d} tools={d} in={d} out={d} finish={s}]\n", .{
            result.steps_taken, result.tool_calls_made,
            result.usage.input_tokens, result.usage.output_tokens,
            result.final_finish_reason,
        });
    }
}

fn printBanner(cfg: *config.Config, profile: *const config.Profile) !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print(
        \\pun v{s} — BYOK AI coding agent
        \\profile: {s}  provider: {s}  model: {?s}
        \\workspace: {s}
        \\
        \\Type /help for commands, /quit to exit.
        \\
    , .{
        @import("../pun.zig").version,
        profile.name,
        profile.provider,
        profile.model,
        cfg.security.workspace,
    });
}

fn printHelp() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print(
        \\Commands:
        \\  /quit, /exit       Exit the TUI
        \\  /clear             Clear conversation history
        \\  /reload            Send SIGHUP to self (triggers config hot reload)
        \\  /profile <name>    Switch active profile
        \\  /model <id>        Override active model
        \\  /plan              Show the current step plan
        \\  /noplan            Toggle the planner LLM on/off
        \\  /help              Show this help
        \\
        \\Streaming is on by default — text deltas print live as the model writes.
        \\
    , .{});
}

fn stderrPrint(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, fmt, args);
    try std.io.getStdErr().writer().writeAll(out);
}

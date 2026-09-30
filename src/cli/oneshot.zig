// One-shot mode: pun -p "prompt" [--json]

const std = @import("std");
const config = @import("../config/schema.zig");
const security = @import("../security/mod.zig");
const providers = @import("../providers/mod.zig");
const loop = @import("../loop/mod.zig");

pub fn run(alloc: std.mem.Allocator, cfg: *config.Config, prompt: []const u8, json_out: bool) !void {
    var policy = try security.SecurityPolicy.init(alloc, cfg);
    defer policy.deinit();

    const profile = cfg.getActiveProfile() orelse return error.InvalidConfig;
    if (cfg.active_provider == null) {
        if (cfg.providers.get(profile.provider)) |p| try cfg.setActiveProvider(p.name);
    }
    if (cfg.active_model == null) if (profile.model) |m| cfg.setActiveModel(m);

    const provider = try providers.getProvider(alloc, cfg, &policy, cfg.active_provider.?);
    defer providers.freeProvider(alloc, provider);

    var agent = try loop.Agent.init(alloc, cfg, &policy, provider);
    defer agent.deinit();

    var result = try agent.run(prompt);
    defer result.deinit(alloc);

    if (json_out) {
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        const w = buf.writer();
        try w.print("{{\"answer\":\"", .{});
        try writeJsonStr(w, result.answer);
        try w.print("\",\"steps\":{d},\"tool_calls\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"finish\":\"{s}\"}}\n", .{
            result.steps_taken, result.tool_calls_made,
            result.usage.input_tokens, result.usage.output_tokens,
            result.final_finish_reason,
        });
        try std.io.getStdOut().writer().writeAll(buf.items);
    } else {
        try std.io.getStdOut().writer().print("{s}\n", .{result.answer});
        try std.io.getStdErr().writer().print(
            "[steps={d} tools={d} in={d} out={d}]\n",
            .{ result.steps_taken, result.tool_calls_made, result.usage.input_tokens, result.usage.output_tokens },
        );
    }
}

fn writeJsonStr(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.print("\\\"", .{}),
            '\\' => try w.print("\\\\", .{}),
            '\n' => try w.print("\\n", .{}),
            '\r' => try w.print("\\r", .{}),
            '\t' => try w.print("\\t", .{}),
            else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        }
    }
}

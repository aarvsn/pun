// Batch mode: pun -f task.json
//
// JSON schema:
//   { "prompt": "...", "max_steps": 20, "json_out": true }

const std = @import("std");
const config = @import("../config/schema.zig");
const security = @import("../security/mod.zig");
const providers = @import("../providers/mod.zig");
const loop = @import("../loop/mod.zig");
const util = @import("../util.zig");

pub fn run(alloc: std.mem.Allocator, cfg: *config.Config, file_path: []const u8) !void {
    const buf = try util.readFile(alloc, file_path);
    defer alloc.free(buf);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, buf, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConfig;
    const obj = parsed.value.object;
    const prompt_v = obj.get("prompt") orelse return error.InvalidConfig;
    if (prompt_v != .string) return error.InvalidConfig;
    const max_steps: u32 = if (obj.get("max_steps")) |v| (if (v == .integer) @intCast(v.integer) else 20) else 20;
    const json_out: bool = if (obj.get("json_out")) |v| (if (v == .bool) v.bool else false) else true;

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
    agent.max_steps = max_steps;

    var result = try agent.run(prompt_v.string);
    defer result.deinit(alloc);

    if (json_out) {
        var out_buf = std.ArrayList(u8).init(alloc);
        defer out_buf.deinit();
        const w = out_buf.writer();
        try w.print("{{\"answer\":\"", .{});
        try writeJsonStr(w, result.answer);
        try w.print("\",\"steps\":{d},\"tool_calls\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"finish\":\"{s}\"}}\n", .{
            result.steps_taken, result.tool_calls_made,
            result.usage.input_tokens, result.usage.output_tokens,
            result.final_finish_reason,
        });
        try std.io.getStdOut().writer().writeAll(out_buf.items);
    } else {
        try std.io.getStdOut().writer().print("{s}\n", .{result.answer});
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

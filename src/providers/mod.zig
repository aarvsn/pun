// Provider adapters — BYOK core.
//
// Each adapter wraps one LLM provider's HTTP API and exposes:
//   - chat(messages, opts) -> Response (with usage)
//   - chatStream(messages, opts, callback) -> void
//
// All adapters return the unified types from `pun.types`.
// See providers/base.zig for the Provider interface.

const std = @import("std");

pub const base = @import("base.zig");
pub const http = @import("http.zig");
pub const sse = @import("sse.zig");
pub const registry = @import("registry.zig");

pub const anthropic = @import("anthropic.zig");
pub const openai = @import("openai.zig");
pub const openai_compat = @import("openai_compat.zig");
pub const google = @import("google.zig");
pub const glm = @import("glm.zig");
pub const deepseek = @import("deepseek.zig");
pub const mistral = @import("mistral.zig");
pub const xai = @import("xai.zig");

pub const Provider = base.Provider;
pub const ChatOptions = base.ChatOptions;
pub const ChatResponse = base.ChatResponse;

pub fn getProvider(alloc: std.mem.Allocator, cfg: anytype, policy: anytype, name: []const u8) !*Provider {
    return registry.getProvider(alloc, cfg, policy, name);
}

pub fn freeProvider(alloc: std.mem.Allocator, p: *Provider) void {
    registry.freeProvider(alloc, p);
}

test {
    @import("std").testing.refAllDecls(@This());
}

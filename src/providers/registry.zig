// Provider registry — instantiate a provider by name from config.
//
// Looks up the provider config in cfg.providers, resolves the API key from
// the vault or env, then constructs the appropriate adapter.

const std = @import("std");
const base = @import("base.zig");
const config = @import("../config/schema.zig");
const security = @import("../security/mod.zig");
const anthropic = @import("anthropic.zig");
const openai = @import("openai.zig");
const openai_compat = @import("openai_compat.zig");
const google = @import("google.zig");
const glm = @import("glm.zig");
const deepseek = @import("deepseek.zig");
const mistral = @import("mistral.zig");
const xai = @import("xai.zig");

pub fn getProvider(
    alloc: std.mem.Allocator,
    cfg: *config.Config,
    policy: *security.SecurityPolicy,
    name: []const u8,
) !*base.Provider {
    const pc = cfg.providers.get(name) orelse return error.InvalidConfig;

    // Resolve API key
    const key = (try policy.getApiKey(name)) orelse return error.ProviderAuthError;
    // Copy the key so the provider owns it (policy returns borrowed memory)
    const key_dup = try alloc.dupe(u8, key);
    errdefer alloc.free(key_dup);

    const p: *base.Provider = switch (pc.kind) {
        .anthropic => blk: {
            const impl = try anthropic.AnthropicProvider.init(alloc, key_dup, pc.base_url, pc.default_model);
            const p = try alloc.create(base.Provider);
            p.* = impl.provider();
            break :blk p;
        },
        .openai => blk: {
            const impl = try openai.OpenAiProvider.init(alloc, key_dup, pc.base_url, pc.default_model);
            const p = try alloc.create(base.Provider);
            p.* = impl.provider();
            break :blk p;
        },
        .openai_compat => blk: {
            const base_url = pc.base_url orelse return error.InvalidConfig;
            const impl = try openai_compat.OpenAiCompatProvider.init(alloc, key_dup, base_url, pc.default_model);
            const p = try alloc.create(base.Provider);
            p.* = impl.provider();
            break :blk p;
        },
        .google => blk: {
            const impl = try google.GoogleProvider.init(alloc, key_dup, pc.base_url, pc.default_model);
            const p = try alloc.create(base.Provider);
            p.* = impl.provider();
            break :blk p;
        },
        .glm => blk: {
            const impl = try glm.GlmProvider.init(alloc, key_dup, pc.base_url, pc.default_model);
            const p = try alloc.create(base.Provider);
            p.* = impl.provider();
            break :blk p;
        },
        .deepseek => blk: {
            const impl = try deepseek.DeepSeekProvider.init(alloc, key_dup, pc.base_url, pc.default_model);
            const p = try alloc.create(base.Provider);
            p.* = impl.provider();
            break :blk p;
        },
        .mistral => blk: {
            const impl = try mistral.MistralProvider.init(alloc, key_dup, pc.base_url, pc.default_model);
            const p = try alloc.create(base.Provider);
            p.* = impl.provider();
            break :blk p;
        },
        .xai => blk: {
            const impl = try xai.XAiProvider.init(alloc, key_dup, pc.base_url, pc.default_model);
            const p = try alloc.create(base.Provider);
            p.* = impl.provider();
            break :blk p;
        },
    };
    // key_dup is now owned by the provider (the impl took a dupe inside .init)
    alloc.free(key_dup);
    return p;
}

pub fn freeProvider(alloc: std.mem.Allocator, p: *base.Provider) void {
    p.deinit();
    alloc.destroy(p);
}

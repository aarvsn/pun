// Config schema for pun.
//
// All fields are owned by the Config struct and freed via deinit().
// `loadConfig()` populates this from TOML + env + CLI overrides.

const std = @import("std");
const toml = @import("parser.zig");

pub const ProviderKind = enum {
    anthropic,
    openai,
    openai_compat,
    google,
    glm,
    deepseek,
    mistral,
    xai,

    pub fn fromString(s: []const u8) ?ProviderKind {
        const map = std.StaticStringMap(ProviderKind).initComptime(.{
            .{ "anthropic", .anthropic },
            .{ "openai", .openai },
            .{ "openai_compat", .openai_compat },
            .{ "google", .google },
            .{ "glm", .glm },
            .{ "deepseek", .deepseek },
            .{ "mistral", .mistral },
            .{ "xai", .xai },
        });
        return map.get(s);
    }
    pub fn toString(self: ProviderKind) []const u8 {
        return switch (self) {
            .anthropic => "anthropic",
            .openai => "openai",
            .openai_compat => "openai_compat",
            .google => "google",
            .glm => "glm",
            .deepseek => "deepseek",
            .mistral => "mistral",
            .xai => "xai",
        };
    }
};

pub const ProviderConfig = struct {
    name: []u8,
    kind: ProviderKind,
    api_key_env: ?[]u8 = null,
    api_key: ?[]u8 = null, // resolved at runtime from env or vault
    base_url: ?[]u8 = null,
    default_model: []u8,
    extra_headers: std.StringHashMap([]u8),

    pub fn deinit(self: *ProviderConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.default_model);
        if (self.api_key_env) |s| alloc.free(s);
        if (self.api_key) |s| alloc.free(s);
        if (self.base_url) |s| alloc.free(s);
        var it = self.extra_headers.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        self.extra_headers.deinit();
    }
};

pub const ShellConfig = struct {
    workspace: []u8,
    allowlist: [][]u8,
    denylist_regex: [][]u8,
    timeout_seconds: u32 = 30,
    allow_network: bool = false,
    allow_sudo: bool = false,
    env_passthrough: [][]u8,
    /// If non-null, run shell commands inside this Docker image instead of
    /// the host. The image must already be pulled. Workspace is bind-mounted
    /// read-write. Network is disabled (use --network=none).
    /// Example: "ubuntu:22.04"
    docker_image: ?[]u8 = null,

    pub fn deinit(self: *ShellConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.workspace);
        for (self.allowlist) |s| alloc.free(s);
        if (self.allowlist.len > 0) alloc.free(self.allowlist);
        for (self.denylist_regex) |s| alloc.free(s);
        if (self.denylist_regex.len > 0) alloc.free(self.denylist_regex);
        for (self.env_passthrough) |s| alloc.free(s);
        if (self.env_passthrough.len > 0) alloc.free(self.env_passthrough);
        if (self.docker_image) |s| alloc.free(s);
    }
};

pub const NetworkPolicy = struct {
    allowlist: [][]u8,
    denylist_regex: [][]u8,
    default_allow: bool = false,

    pub fn deinit(self: *NetworkPolicy, alloc: std.mem.Allocator) void {
        for (self.allowlist) |s| alloc.free(s);
        if (self.allowlist.len > 0) alloc.free(self.allowlist);
        for (self.denylist_regex) |s| alloc.free(s);
        if (self.denylist_regex.len > 0) alloc.free(self.denylist_regex);
    }
};

pub const TokenBudget = struct {
    per_session: u64 = 500_000,
    per_step: u64 = 50_000,
    warn_at_percent: u32 = 80,
};

pub const SecurityConfig = struct {
    workspace: []u8,
    audit_log: []u8,
    vault_path: []u8,
    vault_passphrase_env: []u8,
    prompt_injection_guard: bool = true,
    token_budget: TokenBudget = .{},
    network: NetworkPolicy,
    require_confirmation_for_writes_outside_workspace: bool = true,
    require_confirmation_for_shell_not_in_allowlist: bool = true,

    pub fn deinit(self: *SecurityConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.workspace);
        alloc.free(self.audit_log);
        alloc.free(self.vault_path);
        alloc.free(self.vault_passphrase_env);
        self.network.deinit(alloc);
    }
};

pub const Profile = struct {
    name: []u8,
    provider: []u8,
    model: ?[]u8 = null,
    temperature: f32 = 0.3,
    max_tokens: u32 = 8192,
    system_prompt: ?[]u8 = null,

    pub fn deinit(self: *Profile, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.provider);
        if (self.model) |m| alloc.free(m);
        if (self.system_prompt) |s| alloc.free(s);
    }
};

pub const Config = struct {
    alloc: std.mem.Allocator,
    providers: std.StringHashMap(ProviderConfig),
    shell: ShellConfig,
    security: SecurityConfig,
    profiles: std.StringHashMap(Profile),
    default_profile: []u8,
    active_profile: []u8,
    active_provider: ?[]u8 = null,
    active_model: ?[]u8 = null,
    shell_disabled: bool = false,
    auto_yes: bool = false,

    pub fn deinit(self: *Config) void {
        var pit = self.providers.iterator();
        while (pit.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            var p = e.value_ptr.*;
            p.deinit(self.alloc);
        }
        self.providers.deinit();
        self.shell.deinit(self.alloc);
        self.security.deinit(self.alloc);
        var prit = self.profiles.iterator();
        while (prit.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            var p = e.value_ptr.*;
            p.deinit(self.alloc);
        }
        self.profiles.deinit();
        self.alloc.free(self.default_profile);
        self.alloc.free(self.active_profile);
        if (self.active_provider) |s| self.alloc.free(s);
        if (self.active_model) |s| self.alloc.free(s);
    }

    pub fn setActiveProvider(self: *Config, name: []const u8) !void {
        if (!self.providers.contains(name)) return error.InvalidConfig;
        if (self.active_provider) |s| self.alloc.free(s);
        self.active_provider = try self.alloc.dupe(u8, name);
    }

    pub fn setActiveModel(self: *Config, model: []const u8) void {
        if (self.active_model) |s| self.alloc.free(s);
        self.active_model = self.alloc.dupe(u8, model) catch return;
    }

    pub fn getActiveProfile(self: *const Config) ?*const Profile {
        const name = if (self.active_profile.len > 0) self.active_profile else self.default_profile;
        if (self.profiles.get(name)) |*p| return p;
        return null;
    }
};

// ---- Default constructor (used by initConfig) ----

pub fn defaultConfig(alloc: std.mem.Allocator) !Config {
    var providers = std.StringHashMap(ProviderConfig).init(alloc);
    var profiles = std.StringHashMap(Profile).init(alloc);

    // anthropic
    const a_name = try alloc.dupe(u8, "anthropic");
    const a_headers = std.StringHashMap([]u8).init(alloc);
    try providers.put(a_name, .{
        .name = try alloc.dupe(u8, "anthropic"),
        .kind = .anthropic,
        .api_key_env = try alloc.dupe(u8, "ANTHROPIC_API_KEY"),
        .default_model = try alloc.dupe(u8, "claude-sonnet-4-5"),
        .extra_headers = a_headers,
    });

    // openai
    const o_name = try alloc.dupe(u8, "openai");
    const o_headers = std.StringHashMap([]u8).init(alloc);
    try providers.put(o_name, .{
        .name = try alloc.dupe(u8, "openai"),
        .kind = .openai,
        .api_key_env = try alloc.dupe(u8, "OPENAI_API_KEY"),
        .default_model = try alloc.dupe(u8, "gpt-4.1"),
        .extra_headers = o_headers,
    });

    // default profile
    const p_name = try alloc.dupe(u8, "default");
    try profiles.put(p_name, .{
        .name = try alloc.dupe(u8, "default"),
        .provider = try alloc.dupe(u8, "anthropic"),
        .model = try alloc.dupe(u8, "claude-sonnet-4-5"),
        .temperature = 0.3,
        .max_tokens = 8192,
    });

    const home = std.process.getEnvVarOwned(alloc, "HOME") catch try alloc.dupe(u8, "/tmp");
    defer alloc.free(home);
    const ws = try std.fmt.allocPrint(alloc, "{s}/projects", .{home});
    const audit = try std.fmt.allocPrint(alloc, "{s}/.pun/audit.jsonl", .{home});
    const vault = try std.fmt.allocPrint(alloc, "{s}/.pun/vault.age", .{home});

    return Config{
        .alloc = alloc,
        .providers = providers,
        .shell = .{
            .workspace = ws,
            .allowlist = try dupStringSlice(alloc, &.{ "ls", "cat", "grep", "rg", "git", "python", "pytest", "ruff", "make", "zig", "cargo" }),
            .denylist_regex = try dupStringSlice(alloc, &.{
                "rm\\s+-rf\\s+/",
                ":\\(\\)\\s*\\{\\s*:\\|:&\\s*\\}",
                "\\bmkfs\\b",
                "\\bdd\\s+if=",
                "\\bchmod\\s+-R\\s+777\\s+/",
                ">\\s*/dev/sd",
                "\\bsudo\\s+rm\\b",
            }),
            .timeout_seconds = 30,
            .allow_network = false,
            .allow_sudo = false,
            .env_passthrough = try dupStringSlice(alloc, &.{ "PATH", "HOME", "LANG", "LC_ALL", "TERM" }),
        },
        .security = .{
            .workspace = try alloc.dupe(u8, ws),
            .audit_log = audit,
            .vault_path = vault,
            .vault_passphrase_env = try alloc.dupe(u8, "PUN_VAULT_PASSPHRASE"),
            .prompt_injection_guard = true,
            .token_budget = .{ .per_session = 500_000, .per_step = 50_000 },
            .network = .{
                .allowlist = try dupStringSlice(alloc, &.{
                    "api.anthropic.com",
                    "api.openai.com",
                    "generativelanguage.googleapis.com",
                    "api.deepseek.com",
                    "api.mistral.ai",
                    "api.x.ai",
                    "open.bigmodel.cn",
                }),
                .denylist_regex = &.{},
                .default_allow = false,
            },
        },
        .profiles = profiles,
        .default_profile = try alloc.dupe(u8, "default"),
        .active_profile = try alloc.dupe(u8, "default"),
    };
}

fn dupStringSlice(alloc: std.mem.Allocator, src: []const []const u8) ![][]u8 {
    var out = try alloc.alloc([]u8, src.len);
    errdefer alloc.free(out);
    for (src, 0..) |s, i| out[i] = try alloc.dupe(u8, s);
    return out;
}

// ---- Build a Config from a parsed TOML tree ----

pub fn fromToml(alloc: std.mem.Allocator, root: *std.StringHashMap(toml.Value)) !Config {
    var cfg = try defaultConfig(alloc);
    errdefer cfg.deinit();

    // providers.*  (replace defaults if any are present)
    if (toml.getTable(root, "providers")) |top| {
        var it = top.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            const sub_v = e.value_ptr.*;
            if (sub_v != .table) continue;
            const sub = sub_v.table;
            const kind_s = toml.getString(sub, "kind") orelse continue;
            const kind = ProviderKind.fromString(kind_s) orelse continue;
            // Remove old entry if exists
            if (cfg.providers.fetchRemove(name)) |old| {
                alloc.free(old.key);
                var old_v = old.value;
                old_v.deinit(alloc);
            }
            const key_dup = try alloc.dupe(u8, name);
            const headers = std.StringHashMap([]u8).init(alloc);
            try cfg.providers.put(key_dup, .{
                .name = try alloc.dupe(u8, name),
                .kind = kind,
                .api_key_env = if (toml.getString(sub, "api_key_env")) |s| try alloc.dupe(u8, s) else null,
                .base_url = if (toml.getString(sub, "base_url")) |s| try alloc.dupe(u8, s) else null,
                .default_model = try alloc.dupe(u8, toml.getString(sub, "default_model") orelse ""),
                .extra_headers = headers,
            });
        }
    }

    // shell.*
    if (toml.getTable(root, "shell")) |sh| {
        if (toml.getString(sh, "workspace")) |s| {
            alloc.free(cfg.shell.workspace);
            cfg.shell.workspace = try alloc.dupe(u8, s);
        }
        if (toml.getArray(sh, "allowlist")) |arr| {
            cfg.shell.allowlist = try tomlArrayToStrings(alloc, arr);
        }
        if (toml.getArray(sh, "denylist_regex")) |arr| {
            cfg.shell.denylist_regex = try tomlArrayToStrings(alloc, arr);
        }
        if (toml.getInt(sh, "timeout_seconds")) |i| cfg.shell.timeout_seconds = @intCast(i);
        if (toml.getBool(sh, "allow_network")) |b| cfg.shell.allow_network = b;
        if (toml.getBool(sh, "allow_sudo")) |b| cfg.shell.allow_sudo = b;
        if (toml.getArray(sh, "env_passthrough")) |arr| {
            cfg.shell.env_passthrough = try tomlArrayToStrings(alloc, arr);
        }
        if (toml.getString(sh, "docker_image")) |s| {
            if (cfg.shell.docker_image) |old| alloc.free(old);
            cfg.shell.docker_image = try alloc.dupe(u8, s);
        }
    }

    // security.*
    if (toml.getTable(root, "security")) |sec| {
        if (toml.getString(sec, "workspace")) |s| {
            alloc.free(cfg.security.workspace);
            cfg.security.workspace = try alloc.dupe(u8, s);
        }
        if (toml.getString(sec, "audit_log")) |s| {
            alloc.free(cfg.security.audit_log);
            cfg.security.audit_log = try alloc.dupe(u8, s);
        }
        if (toml.getString(sec, "vault_path")) |s| {
            alloc.free(cfg.security.vault_path);
            cfg.security.vault_path = try alloc.dupe(u8, s);
        }
        if (toml.getString(sec, "vault_passphrase_env")) |s| {
            alloc.free(cfg.security.vault_passphrase_env);
            cfg.security.vault_passphrase_env = try alloc.dupe(u8, s);
        }
        if (toml.getBool(sec, "prompt_injection_guard")) |b| cfg.security.prompt_injection_guard = b;
        if (toml.getBool(sec, "require_confirmation_for_writes_outside_workspace")) |b|
            cfg.security.require_confirmation_for_writes_outside_workspace = b;
        if (toml.getBool(sec, "require_confirmation_for_shell_not_in_allowlist")) |b|
            cfg.security.require_confirmation_for_shell_not_in_allowlist = b;
        if (toml.getTable(sec, "token_budget")) |tb| {
            if (toml.getInt(tb, "per_session")) |i| cfg.security.token_budget.per_session = @intCast(i);
            if (toml.getInt(tb, "per_step")) |i| cfg.security.token_budget.per_step = @intCast(i);
            if (toml.getInt(tb, "warn_at_percent")) |i| cfg.security.token_budget.warn_at_percent = @intCast(i);
        }
        if (toml.getTable(sec, "network")) |np| {
            if (toml.getArray(np, "allowlist")) |arr| {
                cfg.security.network.allowlist = try tomlArrayToStrings(alloc, arr);
            }
            if (toml.getArray(np, "denylist_regex")) |arr| {
                cfg.security.network.denylist_regex = try tomlArrayToStrings(alloc, arr);
            }
            if (toml.getBool(np, "default_allow")) |b| cfg.security.network.default_allow = b;
        }
    }

    // profiles.*
    if (toml.getTable(root, "profiles")) |top| {
        var it = top.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            const sub_v = e.value_ptr.*;
            if (sub_v != .table) continue;
            const sub = sub_v.table;
            const prov = toml.getString(sub, "provider") orelse continue;
            if (cfg.profiles.fetchRemove(name)) |old| {
                alloc.free(old.key);
                var old_v = old.value;
                old_v.deinit(alloc);
            }
            const key_dup = try alloc.dupe(u8, name);
            try cfg.profiles.put(key_dup, .{
                .name = try alloc.dupe(u8, name),
                .provider = try alloc.dupe(u8, prov),
                .model = if (toml.getString(sub, "model")) |s| try alloc.dupe(u8, s) else null,
                .temperature = if (toml.getFloat(sub, "temperature")) |f| @floatCast(f) else 0.3,
                .max_tokens = if (toml.getInt(sub, "max_tokens")) |i| @intCast(i) else 8192,
                .system_prompt = if (toml.getString(sub, "system_prompt")) |s| try alloc.dupe(u8, s) else null,
            });
        }
    }

    if (toml.getString(root, "default_profile")) |s| {
        alloc.free(cfg.default_profile);
        alloc.free(cfg.active_profile);
        cfg.default_profile = try alloc.dupe(u8, s);
        cfg.active_profile = try alloc.dupe(u8, s);
    }

    return cfg;
}

fn tomlArrayToStrings(alloc: std.mem.Allocator, arr: []toml.Value) ![][]u8 {
    var out = std.ArrayList([]u8).init(alloc);
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit();
    }
    for (arr) |v| {
        switch (v) {
            .string => |s| try out.append(try alloc.dupe(u8, s)),
            else => {},
        }
    }
    return try out.toOwnedSlice();
}

test "defaultConfig builds" {
    var cfg = try defaultConfig(std.testing.allocator);
    defer cfg.deinit();
    try std.testing.expect(cfg.providers.contains("anthropic"));
    try std.testing.expect(cfg.profiles.contains("default"));
}

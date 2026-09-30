// SecurityPolicy — composes all security components and exposes a single API.
//
// The agent loop and tools call into SecurityPolicy rather than reaching for
// individual guards directly. This keeps policy logic in one place.

const std = @import("std");
const config = @import("../config/schema.zig");
const path_jail = @import("path_jail.zig");
const command_guard = @import("command_guard.zig");
const network = @import("network.zig");
const vault_mod = @import("vault.zig");
const injection = @import("injection.zig");
const audit = @import("audit.zig");
const budget = @import("budget.zig");
const confirm = @import("confirm.zig");
const util = @import("../util.zig");

pub const SecurityPolicy = struct {
    alloc: std.mem.Allocator,
    cfg: *config.Config,
    jail: path_jail.PathJail,
    cmd: command_guard.CommandGuard,
    net: network.NetworkGuard,
    vault: vault_mod.SecretsVault,
    inj: injection.InjectionGuard,
    audit_log: audit.AuditLog,
    budget_tracker: budget.TokenBudget,
    gate: confirm.ConfirmationGate,

    pub fn init(alloc: std.mem.Allocator, cfg: *config.Config) !SecurityPolicy {
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .jail = try path_jail.PathJail.init(alloc, cfg.security.workspace),
            .cmd = try command_guard.CommandGuard.init(
                alloc,
                cfg.shell.allowlist,
                cfg.shell.denylist_regex,
                .{
                    .allow_network = cfg.shell.allow_network,
                    .allow_sudo = cfg.shell.allow_sudo,
                    .confirm_for_unlisted = cfg.security.require_confirmation_for_shell_not_in_allowlist,
                },
            ),
            .net = try network.NetworkGuard.init(
                alloc,
                cfg.security.network.allowlist,
                cfg.security.network.denylist_regex,
                cfg.security.network.default_allow,
            ),
            .vault = try vault_mod.SecretsVault.init(alloc, cfg.security.vault_path, cfg.security.vault_passphrase_env),
            .inj = try injection.InjectionGuard.init(alloc, 2),
            .audit_log = try audit.AuditLog.init(alloc, cfg.security.audit_log),
            .budget_tracker = budget.TokenBudget.init(
                cfg.security.token_budget.per_session,
                cfg.security.token_budget.per_step,
                cfg.security.token_budget.warn_at_percent,
            ),
            .gate = confirm.ConfirmationGate.init(cfg.auto_yes, std.io.getStdIn().isTty()),
        };
    }

    pub fn deinit(self: *SecurityPolicy) void {
        self.jail.deinit();
        self.cmd.deinit();
        self.net.deinit();
        self.vault.deinit();
        self.inj.deinit();
        self.audit_log.deinit();
    }

    /// Clone the policy. Useful for spawning sub-agents on their own threads
    /// where the parent policy may be mutated concurrently.
    pub fn clone(self: *SecurityPolicy) !SecurityPolicy {
        return SecurityPolicy.init(self.alloc, self.cfg);
    }

    /// Resolve a path under the jail. Returns owned absolute path or PathJailViolation.
    pub fn resolvePath(self: *SecurityPolicy, p: []const u8) ![]u8 {
        return self.jail.resolve(p);
    }

    /// Confirm a write to a path. If the path is inside the workspace, no
    /// confirmation needed. If outside and `require_confirmation_for_writes_outside_workspace`
    /// is set, ask the user.
    pub fn confirmWrite(self: *SecurityPolicy, p: []const u8) !bool {
        // Try to resolve inside jail
        const inside = self.jail.resolve(p) catch null;
        if (inside) |abs| {
            self.alloc.free(abs);
            return true;
        }
        // Outside jail — ask
        const granted = try self.gate.confirm(.write_outside_workspace, p);
        try self.audit_log.logConfirmation(granted, p);
        return granted;
    }

    /// Check a shell command. Returns a CommandDecision; raises CommandBlocked if hard-blocked.
    pub fn checkShell(self: *SecurityPolicy, command: []const u8) !command_guard.CommandDecision {
        const dec = self.cmd.check(command) catch |e| {
            try self.audit_log.log(.shell_exec, "blocked", null);
            return e;
        };
        if (dec.needs_confirmation) {
            const granted = try self.gate.confirm(.shell_not_in_allowlist, command);
            try self.audit_log.logConfirmation(granted, command);
            if (!granted) return error.ConfirmationDenied;
        }
        return dec;
    }

    pub fn checkNetwork(self: *SecurityPolicy, url: []const u8) !void {
        return self.net.check(url);
    }

    pub fn scanInjection(self: *SecurityPolicy, text: []const u8) ![]injection.InjectionHit {
        return self.inj.scan(text);
    }

    pub fn annotateInjection(self: *SecurityPolicy, text: []const u8) ![]u8 {
        return self.inj.annotate(text);
    }

    pub fn getApiKey(self: *SecurityPolicy, provider_name: []const u8) !?[]const u8 {
        // 1. Vault (key = provider name)
        if (try self.vault.get(provider_name)) |k| return k;
        // 2. Env var named in provider config
        if (self.cfg.providers.get(provider_name)) |p| {
            if (p.api_key_env) |env| {
                if (std.process.getEnvVarOwned(self.alloc, env) catch null) |k| {
                    return k;
                }
            }
        }
        return null;
    }

    pub fn spendTokens(self: *SecurityPolicy, input: u64, output: u64) !budget.Status {
        const status = self.budget_tracker.spend(input, output);
        switch (status) {
            .warn => try self.audit_log.log(.budget_warning, "session budget warning", null),
            .exceeded => {
                try self.audit_log.log(.budget_exceeded, "session budget exceeded", null);
                return error.TokenBudgetExceeded;
            },
            .ok => {},
        }
        return status;
    }
};

test "SecurityPolicy: build" {
    const alloc = std.testing.allocator;
    var cfg = try config.defaultConfig(alloc);
    defer cfg.deinit();
    // Override paths to tmp
    alloc.free(cfg.security.workspace);
    cfg.security.workspace = try alloc.dupe(u8, "/tmp/pun_test_ws");
    alloc.free(cfg.security.audit_log);
    cfg.security.audit_log = try alloc.dupe(u8, "/tmp/pun_test_audit.jsonl");
    alloc.free(cfg.security.vault_path);
    cfg.security.vault_path = try alloc.dupe(u8, "/tmp/pun_test_vault.bin");
    defer std.fs.cwd().deleteTree("/tmp/pun_test_ws") catch {};
    defer std.fs.cwd().deleteFile("/tmp/pun_test_audit.jsonl") catch {};
    defer std.fs.cwd().deleteFile("/tmp/pun_test_vault.bin") catch {};

    var p = try SecurityPolicy.init(alloc, &cfg);
    defer p.deinit();
    const r = try p.resolvePath("foo.txt");
    defer alloc.free(r);
    try std.testing.expect(util.isPathInside("/tmp/pun_test_ws", r));
}

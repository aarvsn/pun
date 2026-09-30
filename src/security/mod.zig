// Security subsystem for pun.
//
// All security components are allocator-explicit and free of global state
// (except the `id_counter` in util.zig).

pub const path_jail = @import("path_jail.zig");
pub const command_guard = @import("command_guard.zig");
pub const network = @import("network.zig");
pub const vault = @import("vault.zig");
pub const injection = @import("injection.zig");
pub const audit = @import("audit.zig");
pub const budget = @import("budget.zig");
pub const confirm = @import("confirm.zig");
pub const policy = @import("policy.zig");

pub const PathJail = path_jail.PathJail;
pub const CommandGuard = command_guard.CommandGuard;
pub const CommandDecision = command_guard.CommandDecision;
pub const NetworkGuard = network.NetworkGuard;
pub const SecretsVault = vault.SecretsVault;
pub const InjectionGuard = injection.InjectionGuard;
pub const AuditLog = audit.AuditLog;
pub const TokenBudget = budget.TokenBudget;
pub const ConfirmationGate = confirm.ConfirmationGate;
pub const SecurityPolicy = policy.SecurityPolicy;

test {
    @import("std").testing.refAllDecls(@This());
}

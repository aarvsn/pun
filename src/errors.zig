// Error hierarchy for pun.
//
// We use Zig's error sets rather than exception objects. Each subsystem
// declares its own error subset; this file aggregates them.

const std = @import("std");

pub const PunError = error{
    OutOfMemory,
    InvalidConfig,
    ConfigNotFound,
    ProviderError,
    ProviderHttpError,
    ProviderAuthError,
    ProviderRateLimit,
    ProviderBadRequest,
    PathJailViolation,
    CommandBlocked,
    NetworkBlocked,
    TokenBudgetExceeded,
    ConfirmationDenied,
    ToolError,
    VaultLocked,
    VaultCorrupt,
    VaultPassphraseWrong,
    InjectionDetected,
    TomlParseError,
    JsonParseError,
    MissingArg,
    IoError,
    Timeout,
    NotImplemented,
    Cancelled,
};

/// Map a PunError to a stable string for the audit log & CLI.
pub fn errorName(e: anyerror) []const u8 {
    return @errorName(e);
}

/// True if the error is "the user declined a confirmation gate" — the loop
/// should treat this as a soft stop, not a hard failure.
pub fn isSoftStop(e: anyerror) bool {
    return e == error.ConfirmationDenied or e == error.Cancelled;
}

/// True if the error means "we ran out of budget" — the loop should bail
/// rather than retry.
pub fn isBudgetError(e: anyerror) bool {
    return e == error.TokenBudgetExceeded;
}

test "isSoftStop" {
    try std.testing.expect(isSoftStop(error.ConfirmationDenied));
    try std.testing.expect(!isSoftStop(error.OutOfMemory));
}

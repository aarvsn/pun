// TokenBudget — track session token spend against a hard cap.

const std = @import("std");
const types = @import("../types.zig");

pub const TokenBudget = struct {
    per_session: u64,
    per_step: u64,
    warn_at_percent: u32,
    spent_session: u64 = 0,
    spent_step: u64 = 0,
    step_num: u32 = 0,

    pub fn init(per_session: u64, per_step: u64, warn_at_percent: u32) TokenBudget {
        return .{
            .per_session = per_session,
            .per_step = per_step,
            .warn_at_percent = warn_at_percent,
        };
    }

    pub fn startStep(self: *TokenBudget) void {
        self.step_num += 1;
        self.spent_step = 0;
    }

    /// Returns:
    ///   - .ok        if within budget
    ///   - .warn      if at/above warn_at_percent of per_session
    ///   - .exceeded  if over per_session or per_step
    pub fn spend(self: *TokenBudget, input: u64, output: u64) Status {
        const total = input + output;
        self.spent_session += total;
        self.spent_step += total;
        if (self.spent_session > self.per_session) return .exceeded;
        if (self.spent_step > self.per_step) return .exceeded;
        const pct = @divFloor(self.spent_session * 100, self.per_session);
        if (pct >= self.warn_at_percent) return .warn;
        return .ok;
    }

    pub fn remaining(self: *const TokenBudget) u64 {
        if (self.spent_session >= self.per_session) return 0;
        return self.per_session - self.spent_session;
    }

    pub fn percentUsed(self: *const TokenBudget) u32 {
        return @intCast(@divFloor(self.spent_session * 100, self.per_session));
    }
};

pub const Status = enum { ok, warn, exceeded };

test "TokenBudget: basic spend" {
    var b = TokenBudget.init(1000, 1000, 80);
    try std.testing.expectEqual(Status.ok, b.spend(50, 50));
    try std.testing.expectEqual(@as(u64, 100), b.spent_session);
    try std.testing.expectEqual(Status.warn, b.spend(700, 0));
    // Now we're at 800/1000 = 80% (warn). Next spend pushes us over 1000.
    try std.testing.expectEqual(Status.exceeded, b.spend(300, 0));
    try std.testing.expectEqual(@as(u64, 0), b.remaining());
}

// ConfirmationGate — interactive y/N for risky actions.

const std = @import("std");
const util = @import("../util.zig");

pub const Risk = enum {
    write_outside_workspace,
    shell_not_in_allowlist,
    shell_network,
    shell_sudo,
    delete_file,
    subagent_spawn,
};

pub const ConfirmationGate = struct {
    auto_yes: bool = false,
    interactive: bool = true,

    pub fn init(auto_yes: bool, interactive: bool) ConfirmationGate {
        return .{ .auto_yes = auto_yes, .interactive = interactive };
    }

    /// Returns true if the action is approved (auto-yes or user says y).
    /// Returns false (and logs denial) if user says N, or if non-interactive and not auto_yes.
    pub fn confirm(self: *ConfirmationGate, risk: Risk, detail: []const u8) !bool {
        if (self.auto_yes) return true;
        if (!self.interactive) return false;
        const label = switch (risk) {
            .write_outside_workspace => "WRITE OUTSIDE WORKSPACE",
            .shell_not_in_allowlist => "SHELL (not in allowlist)",
            .shell_network => "SHELL (network access)",
            .shell_sudo => "SHELL (sudo)",
            .delete_file => "DELETE FILE",
            .subagent_spawn => "SPAWN SUB-AGENT",
        };
        const prompt_buf = try std.fmt.allocPrint(std.heap.page_allocator, "⚠ {s}: {s}. Proceed?", .{ label, detail });
        defer std.heap.page_allocator.free(prompt_buf);
        return util.askYesNo(prompt_buf);
    }
};

test "ConfirmationGate: auto_yes" {
    var g = ConfirmationGate.init(true, false);
    try std.testing.expect(try g.confirm(.delete_file, "/tmp/foo"));
}

test "ConfirmationGate: non-interactive without auto_yes denies" {
    var g = ConfirmationGate.init(false, false);
    try std.testing.expect(!try g.confirm(.delete_file, "/tmp/foo"));
}

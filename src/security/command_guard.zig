// CommandGuard — block destructive shell commands and enforce allowlist.

const std = @import("std");
const regex = @import("../regex.zig");

pub const CommandDecision = struct {
    allowed: bool,
    needs_confirmation: bool = false,
    reason: []const u8 = "",
};

pub const CommandGuard = struct {
    allowlist: [][]u8,
    denylist: [][]u8, // regex strings
    denylist_compiled: []regex.Regex,
    allow_network: bool,
    allow_sudo: bool,
    confirm_for_unlisted: bool,
    alloc: std.mem.Allocator,

    pub fn init(
        alloc: std.mem.Allocator,
        allowlist: [][]u8,
        denylist: [][]u8,
        opts: struct {
            allow_network: bool = false,
            allow_sudo: bool = false,
            confirm_for_unlisted: bool = true,
        },
    ) !CommandGuard {
        var compiled = try alloc.alloc(regex.Regex, denylist.len);
        errdefer alloc.free(compiled);
        for (denylist, 0..) |pat, i| {
            compiled[i] = try regex.Regex.compile(alloc, pat);
        }
        return .{
            .allowlist = allowlist,
            .denylist = denylist,
            .denylist_compiled = compiled,
            .allow_network = opts.allow_network,
            .allow_sudo = opts.allow_sudo,
            .confirm_for_unlisted = opts.confirm_for_unlisted,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *CommandGuard) void {
        for (self.denylist_compiled) |*rx| rx.deinit();
        self.alloc.free(self.denylist_compiled);
    }

    /// Inspect `command`. Returns CommandDecision.
    /// Returns error.CommandBlocked if the command is hard-blocked.
    pub fn check(self: *CommandGuard, command: []const u8) !CommandDecision {
        if (command.len == 0) return .{ .allowed = false, .reason = "empty" };

        // 1. Denylist (hard block)
        for (self.denylist_compiled) |*rx| {
            if (rx.match(command) != null) {
                return error.CommandBlocked;
            }
        }

        // 2. Tokenize
        var tokens = std.ArrayList([]const u8).init(self.alloc);
        defer tokens.deinit();
        var it = std.mem.tokenizeAny(u8, command, " \t");
        while (it.next()) |t| try tokens.append(t);
        if (tokens.items.len == 0) return .{ .allowed = false, .reason = "empty" };

        // 3. Sudo check
        var binary = tokens.items[0];
        if (std.mem.eql(u8, binary, "sudo")) {
            if (!self.allow_sudo) return error.CommandBlocked;
            if (tokens.items.len > 1) binary = tokens.items[1];
        }

        // 4. Network check (heuristic — substring match for known network tools)
        const networkish = blk: {
            const needles = [_][]const u8{ "curl", "wget", "nc ", "netcat", "ssh ", "scp ", "rsync", "ftp", "telnet", "/dev/tcp/" };
            for (needles) |n| {
                if (std.mem.indexOf(u8, command, n) != null) break :blk true;
            }
            break :blk false;
        };
        if (networkish and !self.allow_network) return error.CommandBlocked;

        // 5. Allowlist
        if (self.allowlist.len > 0) {
            for (self.allowlist) |a| {
                if (std.mem.eql(u8, a, binary)) return .{ .allowed = true };
            }
            if (self.confirm_for_unlisted) {
                return .{ .allowed = true, .needs_confirmation = true, .reason = "not in allowlist" };
            }
            return error.CommandBlocked;
        }

        return .{ .allowed = true };
    }
};

test "CommandGuard: blocks rm -rf /" {
    const alloc = std.testing.allocator;
    var deny: [][]u8 = try alloc.alloc([]u8, 1);
    defer alloc.free(deny);
    deny[0] = try alloc.dupe(u8, "rm\\s+-rf\\s+/");
    defer alloc.free(deny[0]);
    const allow: [][]u8 = try alloc.alloc([]u8, 0);
    defer alloc.free(allow);
    var g = try CommandGuard.init(alloc, allow, deny, .{});
    defer g.deinit();
    try std.testing.expectError(error.CommandBlocked, g.check("rm -rf /"));
}

test "CommandGuard: allowlist pass and confirm" {
    const alloc = std.testing.allocator;
    var allow: [][]u8 = try alloc.alloc([]u8, 2);
    defer {
        for (allow) |s| alloc.free(s);
        alloc.free(allow);
    }
    allow[0] = try alloc.dupe(u8, "ls");
    allow[1] = try alloc.dupe(u8, "cat");
    const deny: [][]u8 = try alloc.alloc([]u8, 0);
    defer alloc.free(deny);
    var g = try CommandGuard.init(alloc, allow, deny, .{ .confirm_for_unlisted = true });
    defer g.deinit();

    const ok = try g.check("ls -la");
    try std.testing.expect(ok.allowed);
    try std.testing.expect(!ok.needs_confirmation);

    const confirm = try g.check("zig build");
    try std.testing.expect(confirm.allowed);
    try std.testing.expect(confirm.needs_confirmation);
}

test "CommandGuard: network blocked when disabled" {
    const alloc = std.testing.allocator;
    const allow: [][]u8 = try alloc.alloc([]u8, 0);
    defer alloc.free(allow);
    const deny: [][]u8 = try alloc.alloc([]u8, 0);
    defer alloc.free(deny);
    var g = try CommandGuard.init(alloc, allow, deny, .{ .allow_network = false });
    defer g.deinit();
    try std.testing.expectError(error.CommandBlocked, g.check("curl http://example.com"));
}

// SecretsVault — encrypted local keystore for API keys.
//
// Format: a 12-byte nonce + AES-256-GCM ciphertext + 16-byte tag, written to disk.
// Key is derived from a passphrase via SHA-256.
//
// JSON payload (after decryption):
//   { "anthropic": "sk-ant-...", "openai": "sk-...", ... }

const std = @import("std");
const crypto = std.crypto;
const util = @import("../util.zig");
const PunError = @import("../errors.zig").PunError;

const Gcm = crypto.aead.aes_gcm.Aes256Gcm;

pub const SecretsVault = struct {
    path: []const u8,
    passphrase_env: []const u8,
    alloc: std.mem.Allocator,
    key: ?[32]u8 = null,
    data: std.StringHashMap([]u8),
    loaded: bool = false,

    pub fn init(alloc: std.mem.Allocator, path: []const u8, passphrase_env: []const u8) !SecretsVault {
        return .{
            .path = try alloc.dupe(u8, path),
            .passphrase_env = try alloc.dupe(u8, passphrase_env),
            .alloc = alloc,
            .data = std.StringHashMap([]u8).init(alloc),
        };
    }

    pub fn deinit(self: *SecretsVault) void {
        self.alloc.free(self.path);
        self.alloc.free(self.passphrase_env);
        var it = self.data.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.data.deinit();
    }

    pub fn unlock(self: *SecretsVault) !void {
        if (self.key != null) return;
        const pw = std.process.getEnvVarOwned(self.alloc, self.passphrase_env) catch null;
        defer if (pw) |p| self.alloc.free(p);

        const pw_final: []const u8 = pw orelse blk: {
            if (std.io.getStdIn().isTty()) {
                try std.io.getStdErr().writer().print("Enter vault passphrase ({s}): ", .{self.passphrase_env});
                var buf: [256]u8 = undefined;
                const line = try std.io.getStdIn().reader().readUntilDelimiterOrEof(&buf, '\n') orelse "";
                break :blk try self.alloc.dupe(u8, line);
            }
            return error.VaultLocked;
        };
        defer if (pw == null) self.alloc.free(pw_final);

        var hash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(pw_final, &hash, .{});
        self.key = hash;

        const f = std.fs.cwd().openFile(self.path, .{}) catch {
            // New vault — start empty
            self.loaded = true;
            try self.save();
            return;
        };
        defer f.close();
        const stat = try f.stat();
        if (stat.size == 0) {
            self.loaded = true;
            try self.save();
            return;
        }
        const buf = try self.alloc.alloc(u8, stat.size);
        defer self.alloc.free(buf);
        _ = try f.readAll(buf);

        if (buf.len < 12 + 16) return error.VaultCorrupt;
        const nonce = buf[0..12].*;
        const ciphertext = buf[12 .. buf.len - 16];
        const tag = buf[buf.len - 16 ..][0..16].*;

        const plain = try self.alloc.alloc(u8, ciphertext.len);
        errdefer self.alloc.free(plain);
        const k = self.key.?;
        Gcm.decrypt(plain, ciphertext, tag, &.{}, nonce, k) catch return error.VaultPassphraseWrong;

        // Parse JSON
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, plain, .{}) catch return error.VaultCorrupt;
        defer parsed.deinit();
        if (parsed.value != .object) return error.VaultCorrupt;
        var it = parsed.value.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .string) continue;
            const k_dup = try self.alloc.dupe(u8, e.key_ptr.*);
            const v_dup = try self.alloc.dupe(u8, e.value_ptr.string);
            try self.data.put(k_dup, v_dup);
        }
        self.alloc.free(plain);
        self.loaded = true;
    }

    pub fn save(self: *SecretsVault) !void {
        if (self.key == null) return error.VaultLocked;
        // Serialize JSON
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        try buf.append('{');
        var first = true;
        var it = self.data.iterator();
        while (it.next()) |e| {
            if (!first) try buf.append(',');
            first = false;
            try buf.append('"');
            try writeJsonString(&buf, e.key_ptr.*);
            try buf.appendSlice("\":\"");
            try writeJsonString(&buf, e.value_ptr.*);
            try buf.append('"');
        }
        try buf.append('}');
        const plain = buf.items;

        // Encrypt
        var nonce: [12]u8 = undefined;
        crypto.random.bytes(&nonce);
        const cipher = try self.alloc.alloc(u8, plain.len);
        defer self.alloc.free(cipher);
        var tag: [16]u8 = undefined;
        Gcm.encrypt(cipher, &tag, plain, &.{}, nonce, self.key.?);

        // Write to disk atomically
        if (std.fs.path.dirname(self.path)) |d| try std.fs.cwd().makePath(d);
        const tmp_path = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{self.path});
        defer self.alloc.free(tmp_path);
        var f = try std.fs.cwd().createFile(tmp_path, .{ .mode = 0o600 });
        defer f.close();
        try f.writeAll(&nonce);
        try f.writeAll(cipher);
        try f.writeAll(&tag);
        try std.fs.cwd().rename(tmp_path, self.path);
    }

    pub fn get(self: *SecretsVault, key: []const u8) !?[]const u8 {
        if (!self.loaded) try self.unlock();
        return self.data.get(key);
    }

    pub fn set(self: *SecretsVault, key: []const u8, value: []const u8) !void {
        if (!self.loaded) try self.unlock();
        if (self.data.fetchRemove(key)) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value);
        }
        try self.data.put(try self.alloc.dupe(u8, key), try self.alloc.dupe(u8, value));
        try self.save();
    }

    pub fn delete(self: *SecretsVault, key: []const u8) !bool {
        if (!self.loaded) try self.unlock();
        if (self.data.fetchRemove(key)) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value);
            try self.save();
            return true;
        }
        return false;
    }

    pub fn keys(self: *SecretsVault, alloc: std.mem.Allocator) ![][]const u8 {
        if (!self.loaded) try self.unlock();
        var out = std.ArrayList([]const u8).init(alloc);
        errdefer out.deinit();
        var it = self.data.iterator();
        while (it.next()) |e| try out.append(e.key_ptr.*);
        return try out.toOwnedSlice();
    }
};

fn writeJsonString(buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            else => if (c < 0x20) {
                try buf.writer().print("\\u{x:0>4}", .{c});
            } else try buf.append(c),
        }
    }
}

// ---- CLI helpers ----

pub fn cliSet(alloc: std.mem.Allocator, cfg: anytype, key: []const u8, value: []const u8) !void {
    var v = try SecretsVault.init(alloc, cfg.security.vault_path, cfg.security.vault_passphrase_env);
    defer v.deinit();
    try v.unlock();
    try v.set(key, value);
    try std.io.getStdOut().writer().print("stored {s} in vault\n", .{key});
}

pub fn cliGet(alloc: std.mem.Allocator, cfg: anytype, key: []const u8) !void {
    var v = try SecretsVault.init(alloc, cfg.security.vault_path, cfg.security.vault_passphrase_env);
    defer v.deinit();
    try v.unlock();
    if (try v.get(key)) |val| {
        try std.io.getStdOut().writer().print("{s}\n", .{val});
    } else {
        try std.io.getStdErr().writer().print("key {s} not found in vault\n", .{key});
        std.process.exit(1);
    }
}

pub fn cliList(alloc: std.mem.Allocator, cfg: anytype) !void {
    var v = try SecretsVault.init(alloc, cfg.security.vault_path, cfg.security.vault_passphrase_env);
    defer v.deinit();
    try v.unlock();
    const ks = try v.keys(alloc);
    defer alloc.free(ks);
    const w = std.io.getStdOut().writer();
    if (ks.len == 0) {
        try w.print("(vault is empty)\n", .{});
        return;
    }
    for (ks) |k| try w.print("{s}\n", .{k});
}

test "SecretsVault: round-trip" {
    const alloc = std.testing.allocator;
    const tmp = "/tmp/pun_vault_test.bin";
    defer std.fs.cwd().deleteFile(tmp) catch {};

    // Passphrase via extern libc setenv
    const c_setenv = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    _ = c_setenv.setenv("PUN_VAULT_TEST_PASS", "test-passphrase-123", 1);
    defer _ = c_setenv.unsetenv("PUN_VAULT_TEST_PASS");

    var v = try SecretsVault.init(alloc, tmp, "PUN_VAULT_TEST_PASS");
    defer v.deinit();
    try v.unlock();
    try v.set("anthropic", "sk-ant-test-123");

    var v2 = try SecretsVault.init(alloc, tmp, "PUN_VAULT_TEST_PASS");
    defer v2.deinit();
    try v2.unlock();
    const got = try v2.get("anthropic");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("sk-ant-test-123", got.?);
}

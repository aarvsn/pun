// Minimal TOML parser for pun's config.
//
// Output: a std.StringHashMap(Value) representing the top-level table,
// with sub-tables stored as Value.table (recursively).
//
// Limitations: see mod.zig.

const std = @import("std");
const util = @import("../util.zig");

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    array: []Value,
    table: *std.StringHashMap(Value),

    pub fn deinit(self: *Value, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| alloc.free(s),
            .array => |arr| {
                for (arr) |*v| v.deinit(alloc);
                alloc.free(arr);
            },
            .table => |t| {
                var it = t.iterator();
                while (it.next()) |e| {
                    alloc.free(e.key_ptr.*);
                    var v = e.value_ptr.*;
                    v.deinit(alloc);
                }
                t.deinit();
                alloc.destroy(t);
            },
            else => {},
        }
    }
};

pub const ParseError = error{
    TomlParseError,
    OutOfMemory,
    InvalidUtf8,
    UnterminatedString,
    InvalidEscape,
    InvalidNumber,
    InvalidValue,
    DuplicateKey,
    InvalidKey,
};

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    alloc: std.mem.Allocator,

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }
    fn next(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }
    fn err(self: *Parser, msg: []const u8) ParseError {
        _ = self;
        std.debug.print("toml: {s}\n", .{msg});
        return error.TomlParseError;
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t') {
                self.pos += 1;
            } else break;
        }
    }
    fn skipWsAndComments(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else break;
        }
    }
    fn skipInlineWsAndComments(self: *Parser) ParseError!void {
        self.skipWs();
        if (self.peek()) |c| {
            if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            }
        }
        if (self.peek()) |c| {
            if (c == '\r') self.pos += 1;
            if (self.peek()) |c2| {
                if (c2 == '\n') self.pos += 1;
            }
        }
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        const quote = self.next().?; // ' or "
        const is_basic = quote == '"';
        var buf = std.ArrayList(u8).init(self.alloc);
        errdefer buf.deinit();
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == quote) {
                self.pos += 1;
                return try buf.toOwnedSlice();
            }
            if (is_basic and c == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) return error.UnterminatedString;
                const e = self.src[self.pos];
                self.pos += 1;
                switch (e) {
                    'n' => try buf.append('\n'),
                    't' => try buf.append('\t'),
                    'r' => try buf.append('\r'),
                    '"' => try buf.append('"'),
                    '\\' => try buf.append('\\'),
                    '0' => try buf.append(0),
                    'u' => {
                        if (self.pos + 4 > self.src.len) return error.InvalidEscape;
                        const hex = self.src[self.pos .. self.pos + 4];
                        self.pos += 4;
                        const cp = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidEscape;
                        var ubuf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &ubuf) catch return error.InvalidEscape;
                        try buf.appendSlice(ubuf[0..n]);
                    },
                    else => return error.InvalidEscape,
                }
            } else {
                try buf.append(c);
                self.pos += 1;
            }
        }
        return error.UnterminatedString;
    }

    fn parseBareKey(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
                self.pos += 1;
            } else break;
        }
        if (self.pos == start) return error.InvalidKey;
        return try self.alloc.dupe(u8, self.src[start..self.pos]);
    }

    fn parseKey(self: *Parser) ParseError![]const u8 {
        self.skipWs();
        const c = self.peek() orelse return error.InvalidKey;
        if (c == '"' or c == '\'') return self.parseString();
        return self.parseBareKey();
    }

    fn parseDottedKey(self: *Parser) ParseError![][]const u8 {
        var parts = std.ArrayList([]const u8).init(self.alloc);
        errdefer {
            for (parts.items) |p| self.alloc.free(p);
            parts.deinit();
        }
        const first = try self.parseKey();
        try parts.append(first);
        while (true) {
            self.skipWs();
            if (self.peek()) |c| {
                if (c == '.') {
                    self.pos += 1;
                    self.skipWs();
                    const next_part = try self.parseKey();
                    try parts.append(next_part);
                    continue;
                }
            }
            break;
        }
        return try parts.toOwnedSlice();
    }

    fn parseValue(self: *Parser) ParseError!Value {
        self.skipWs();
        const c = self.peek() orelse return error.InvalidValue;
        switch (c) {
            '"', '\'' => return Value{ .string = try self.parseString() },
            '[' => return self.parseArray(),
            '{' => return self.parseInlineTable(),
            't', 'f' => return self.parseBool(),
            else => {
                if (std.ascii.isDigit(c) or c == '-' or c == '+') return self.parseNumber();
                return error.InvalidValue;
            },
        }
    }

    fn parseBool(self: *Parser) ParseError!Value {
        if (std.mem.startsWith(u8, self.src[self.pos..], "true")) {
            self.pos += 4;
            return Value{ .boolean = true };
        }
        if (std.mem.startsWith(u8, self.src[self.pos..], "false")) {
            self.pos += 5;
            return Value{ .boolean = false };
        }
        return error.InvalidValue;
    }

    fn parseNumber(self: *Parser) ParseError!Value {
        const start = self.pos;
        if (self.peek()) |c| {
            if (c == '-' or c == '+') self.pos += 1;
        }
        var has_dot = false;
        var has_exp = false;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isDigit(c)) {
                self.pos += 1;
            } else if (c == '.' and !has_dot and !has_exp) {
                has_dot = true;
                self.pos += 1;
            } else if ((c == 'e' or c == 'E') and !has_exp) {
                has_exp = true;
                self.pos += 1;
                if (self.peek()) |c2| {
                    if (c2 == '-' or c2 == '+') self.pos += 1;
                }
            } else if (c == '_') {
                self.pos += 1; // skip digit separators
            } else break;
        }
        const raw = self.src[start..self.pos];
        // strip underscores for parsing
        var clean = std.ArrayList(u8).init(self.alloc);
        defer clean.deinit();
        for (raw) |c| if (c != '_') try clean.append(c);
        if (has_dot or has_exp) {
            const f = std.fmt.parseFloat(f64, clean.items) catch return error.InvalidNumber;
            return Value{ .float = f };
        }
        const i = std.fmt.parseInt(i64, clean.items, 10) catch return error.InvalidNumber;
        return Value{ .int = i };
    }

    fn parseArray(self: *Parser) ParseError!Value {
        self.pos += 1; // [
        var items = std.ArrayList(Value).init(self.alloc);
        errdefer {
            for (items.items) |*v| v.deinit(self.alloc);
            items.deinit();
        }
        while (true) {
            self.skipWsAndComments();
            if (self.peek()) |c| {
                if (c == ']') {
                    self.pos += 1;
                    return Value{ .array = try items.toOwnedSlice() };
                }
            } else return error.TomlParseError;
            const v = try self.parseValue();
            try items.append(v);
            self.skipWsAndComments();
            if (self.peek()) |c| {
                if (c == ',') {
                    self.pos += 1;
                    continue;
                }
                if (c == ']') {
                    self.pos += 1;
                    return Value{ .array = try items.toOwnedSlice() };
                }
            }
            return error.TomlParseError;
        }
    }

    fn parseInlineTable(self: *Parser) ParseError!Value {
        self.pos += 1; // {
        const t = try self.alloc.create(std.StringHashMap(Value));
        t.* = std.StringHashMap(Value).init(self.alloc);
        errdefer {
            t.deinit();
            self.alloc.destroy(t);
        }
        self.skipWs();
        if (self.peek()) |c| {
            if (c == '}') {
                self.pos += 1;
                return Value{ .table = t };
            }
        }
        while (true) {
            self.skipWs();
            const key_parts = try self.parseDottedKey();
            defer {
                for (key_parts) |p| self.alloc.free(p);
                self.alloc.free(key_parts);
            }
            self.skipWs();
            if (self.peek()) |c| {
                if (c != '=') return error.TomlParseError;
                self.pos += 1;
            } else return error.TomlParseError;
            const v = try self.parseValue();
            // For dotted keys inside inline tables, we walk the chain
            try putDotted(t, key_parts, v, self.alloc);
            self.skipWs();
            if (self.peek()) |c| {
                if (c == ',') {
                    self.pos += 1;
                    continue;
                }
                if (c == '}') {
                    self.pos += 1;
                    return Value{ .table = t };
                }
            }
            return error.TomlParseError;
        }
    }

    fn parseDocument(self: *Parser, root: *std.StringHashMap(Value)) ParseError!void {
        var current_section: *std.StringHashMap(Value) = root;
        while (true) {
            self.skipWsAndComments();
            if (self.pos >= self.src.len) return;
            const c = self.src[self.pos];
            if (c == '[') {
                // Section header
                self.pos += 1;
                self.skipWs();
                const key_parts = try self.parseDottedKey();
                defer {
                    for (key_parts) |p| self.alloc.free(p);
                    self.alloc.free(key_parts);
                }
                self.skipWs();
                if (self.peek()) |c2| {
                    if (c2 != ']') return error.TomlParseError;
                    self.pos += 1;
                } else return error.TomlParseError;
                try skipInlineWsAndComments(self);
                // Ensure all sub-tables exist; set current_section to the deepest
                try ensureTablePath(root, key_parts, self.alloc);
                current_section = navigateTo(root, key_parts);
            } else {
                // key = value (within current_section)
                const key_parts = try self.parseDottedKey();
                defer {
                    for (key_parts) |p| self.alloc.free(p);
                    self.alloc.free(key_parts);
                }
                self.skipWs();
                if (self.peek()) |c2| {
                    if (c2 != '=') return error.TomlParseError;
                    self.pos += 1;
                } else return error.TomlParseError;
                const v = try self.parseValue();
                try putDotted(current_section, key_parts, v, self.alloc);
                try skipInlineWsAndComments(self);
            }
        }
    }

    fn navigateTo(root: *std.StringHashMap(Value), parts: [][]const u8) *std.StringHashMap(Value) {
        var cur = root;
        for (parts) |part| {
            if (cur.get(part)) |existing| {
                switch (existing) {
                    .table => |t| cur = t,
                    else => return root, // shouldn't happen if ensureTablePath succeeded
                }
            } else return root;
        }
        return cur;
    }
};

fn ensureTablePath(root: *std.StringHashMap(Value), parts: [][]const u8, alloc: std.mem.Allocator) ParseError!void {
    var cur = root;
    for (parts) |part| {
        if (cur.get(part)) |existing| {
            switch (existing) {
                .table => |t| cur = t,
                else => return error.DuplicateKey,
            }
        } else {
            const t = try alloc.create(std.StringHashMap(Value));
            t.* = std.StringHashMap(Value).init(alloc);
            const key = try alloc.dupe(u8, part);
            try cur.put(key, Value{ .table = t });
            cur = t;
        }
    }
}

fn putDotted(root: *std.StringHashMap(Value), parts: [][]const u8, value: Value, alloc: std.mem.Allocator) ParseError!void {
    if (parts.len == 1) {
        const key = try alloc.dupe(u8, parts[0]);
        if (root.contains(key)) {
            alloc.free(key);
            return error.DuplicateKey;
        }
        try root.put(key, value);
        return;
    }
    // Walk or create sub-tables
    var cur = root;
    for (parts[0 .. parts.len - 1]) |part| {
        if (cur.get(part)) |existing| {
            switch (existing) {
                .table => |t| cur = t,
                else => return error.DuplicateKey,
            }
        } else {
            const t = try alloc.create(std.StringHashMap(Value));
            t.* = std.StringHashMap(Value).init(alloc);
            const key = try alloc.dupe(u8, part);
            try cur.put(key, Value{ .table = t });
            cur = t;
        }
    }
    const last = parts[parts.len - 1];
    const key = try alloc.dupe(u8, last);
    if (cur.contains(key)) {
        alloc.free(key);
        return error.DuplicateKey;
    }
    try cur.put(key, value);
}

pub fn parse(alloc: std.mem.Allocator, src: []const u8) ParseError!*std.StringHashMap(Value) {
    const root = try alloc.create(std.StringHashMap(Value));
    root.* = std.StringHashMap(Value).init(alloc);
    errdefer {
        root.deinit();
        alloc.destroy(root);
    }
    var p = Parser{ .src = src, .alloc = alloc };
    p.parseDocument(root) catch |e| {
        // Cleanup on parse failure: free whatever we built
        var it = root.iterator();
        while (it.next()) |e2| {
            alloc.free(e2.key_ptr.*);
            var v = e2.value_ptr.*;
            v.deinit(alloc);
        }
        root.deinit();
        alloc.destroy(root);
        return e;
    };
    return root;
}

pub fn freeTable(alloc: std.mem.Allocator, root: *std.StringHashMap(Value)) void {
    var it = root.iterator();
    while (it.next()) |e| {
        alloc.free(e.key_ptr.*);
        var v = e.value_ptr.*;
        v.deinit(alloc);
    }
    root.deinit();
    alloc.destroy(root);
}

// ---- Accessor helpers ----

pub fn getString(t: *std.StringHashMap(Value), key: []const u8) ?[]const u8 {
    const v = t.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
pub fn getInt(t: *std.StringHashMap(Value), key: []const u8) ?i64 {
    const v = t.get(key) orelse return null;
    return switch (v) {
        .int => |i| i,
        else => null,
    };
}
pub fn getBool(t: *std.StringHashMap(Value), key: []const u8) ?bool {
    const v = t.get(key) orelse return null;
    return switch (v) {
        .boolean => |b| b,
        else => null,
    };
}
pub fn getFloat(t: *std.StringHashMap(Value), key: []const u8) ?f64 {
    const v = t.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .int => |i| @floatFromInt(i),
        else => null,
    };
}
pub fn getTable(t: *std.StringHashMap(Value), key: []const u8) ?*std.StringHashMap(Value) {
    const v = t.get(key) orelse return null;
    return switch (v) {
        .table => |sub| sub,
        else => null,
    };
}
pub fn getArray(t: *std.StringHashMap(Value), key: []const u8) ?[]Value {
    const v = t.get(key) orelse return null;
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}
pub fn arrayAsStringSlice(arr: []Value) [][]const u8 {
    // Caller must NOT free; this allocates a fresh slice
    var alloc_buf: [256][]const u8 = undefined;
    var n: usize = 0;
    for (arr) |v| {
        if (n >= alloc_buf.len) break;
        switch (v) {
            .string => |s| {
                alloc_buf[n] = s;
                n += 1;
            },
            else => {},
        }
    }
    return alloc_buf[0..n];
}

test "parse: simple key=value" {
    const alloc = std.testing.allocator;
    const src = "name = \"pun\"\nversion = 1\n";
    const root = try parse(alloc, src);
    defer freeTable(alloc, root);
    try std.testing.expectEqualStrings("pun", getString(root, "name").?);
    try std.testing.expectEqual(@as(i64, 1), getInt(root, "version").?);
}

test "parse: section" {
    const alloc = std.testing.allocator;
    const src =
        \\[providers.anthropic]
        \\kind = "anthropic"
        \\default_model = "claude-sonnet-4-5"
        \\
    ;
    const root = try parse(alloc, src);
    defer freeTable(alloc, root);
    const top = getTable(root, "providers").?;
    const sub = getTable(top, "anthropic").?;
    try std.testing.expectEqualStrings("anthropic", getString(sub, "kind").?);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", getString(sub, "default_model").?);
}

test "parse: array of strings" {
    const alloc = std.testing.allocator;
    const src = "allowlist = [\"ls\", \"cat\", \"git\"]\n";
    const root = try parse(alloc, src);
    defer freeTable(alloc, root);
    const arr = getArray(root, "allowlist").?;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqualStrings("ls", arr[0].string);
    try std.testing.expectEqualStrings("git", arr[2].string);
}

test "parse: bool and float" {
    const alloc = std.testing.allocator;
    const src = "enabled = true\nrate = 0.5\n";
    const root = try parse(alloc, src);
    defer freeTable(alloc, root);
    try std.testing.expect(getBool(root, "enabled").?);
    try std.testing.expectEqual(@as(f64, 0.5), getFloat(root, "rate").?);
}

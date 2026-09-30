// Tiny regex engine v2 — supports groups, alternation, and quantifiers.
//
// Supported syntax:
//   .          any char
//   * + ?      quantifiers (greedy, with backtracking)
//   \s \S \d \w \b   escapes
//   \\ \. \+ \* \? \\  escaped metachars
//   [...]      char class with ranges and negation
//   (...)      non-capturing group (also (?:...))
//   |          alternation (within a group or at top level)
//   ^ $        anchors (start/end of input)
//
// NOT supported: captures, backreferences, lookahead, named groups.
// Backtracking matcher — O(2^n) worst case but n is small for our patterns.
//
// Tree structure: root is always a group. A group has a list of alternatives.
// Each alternative is a sequence of nodes. A node is (kind, quant).

const std = @import("std");

pub const Regex = struct {
    root: Node,
    pattern: []const u8,
    alloc: std.mem.Allocator,

    pub const Quant = enum { one, star, plus, quest };

    pub const NodeKind = union(enum) {
        literal: u8,
        any,
        class: struct {
            ranges: []const [2]u8,
            negated: bool,
        },
        word_boundary,
        start,
        end,
        group: struct {
            alternatives: []const []const Node,
        },
    };

    pub const Node = struct {
        kind: NodeKind,
        quant: Quant = .one,
    };

    pub fn compile(alloc: std.mem.Allocator, pattern: []const u8) Parser.Error!Regex {
        var p = Parser{ .src = pattern, .alloc = alloc, .pos = 0 };
        const alternatives = try p.parseAlternation();
        if (p.pos != pattern.len) return error.InvalidRegex;
        return .{
            .root = .{ .kind = .{ .group = .{ .alternatives = alternatives } } },
            .pattern = try alloc.dupe(u8, pattern),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Regex) void {
        self.freeNode(&self.root);
        self.alloc.free(self.pattern);
    }

    fn freeNode(self: *Regex, node: *const Node) void {
        switch (node.kind) {
            .class => |c| self.alloc.free(c.ranges),
            .group => |g| {
                for (g.alternatives) |alt| {
                    for (alt) |*n| self.freeNode(n);
                    self.alloc.free(alt);
                }
                self.alloc.free(g.alternatives);
            },
            else => {},
        }
    }

    /// Find the first match (returns the matched substring, or null).
    /// Caller does NOT own the returned slice (it points into the input).
    pub fn match(self: *const Regex, text: []const u8) ?[]const u8 {
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (self.matchGroup(&self.root, text, start)) |end| {
                return text[start..end];
            }
        }
        return null;
    }

    pub fn matchIterator(self: *const Regex, text: []const u8) Matcher {
        return .{ .regex = self, .text = text, .pos = 0 };
    }

    /// Match a group node: try each alternative.
    fn matchGroup(self: *const Regex, node: *const Node, text: []const u8, pos: usize) ?usize {
        const g = switch (node.kind) {
            .group => |g| g,
            else => unreachable,
        };
        for (g.alternatives) |alt| {
            if (self.matchSeq(alt, text, pos)) |end| return end;
        }
        return null;
    }

    /// Match a sequence of nodes starting at pos. Returns end position or null.
    fn matchSeq(self: *const Regex, nodes: []const Node, text: []const u8, pos: usize) ?usize {
        if (nodes.len == 0) return pos;
        const head = nodes[0];
        const tail = nodes[1..];

        switch (head.quant) {
            .one => {
                const end = self.matchOnce(&head, text, pos) orelse return null;
                return self.matchSeq(tail, text, end);
            },
            .quest => {
                // Try with one match, then without
                if (self.matchOnce(&head, text, pos)) |end| {
                    if (self.matchSeq(tail, text, end)) |final| return final;
                }
                return self.matchSeq(tail, text, pos);
            },
            .star, .plus => {
                // Greedy: collect all match positions, then backtrack
                const min_count: usize = if (head.quant == .plus) 1 else 0;
                var positions = std.ArrayList(usize).init(self.alloc);
                defer positions.deinit();
                positions.append(pos) catch return null;
                var p = pos;
                while (true) {
                    if (self.matchOnce(&head, text, p)) |end| {
                        if (end == p) break; // zero-width match, avoid infinite loop
                        p = end;
                        positions.append(p) catch break;
                    } else break;
                }
                // Try matching the rest at each position, longest first
                var i: usize = positions.items.len;
                while (i > min_count) {
                    i -= 1;
                    if (self.matchSeq(tail, text, positions.items[i])) |final| return final;
                }
                return null;
            },
        }
    }

    /// Match a single instance of the node (ignoring quant). Returns new pos or null.
    fn matchOnce(self: *const Regex, node: *const Node, text: []const u8, pos: usize) ?usize {
        switch (node.kind) {
            .start => return if (pos == 0) pos else null,
            .end => return if (pos == text.len) pos else null,
            .word_boundary => {
                const before = pos > 0 and isWord(text[pos - 1]);
                const after = pos < text.len and isWord(text[pos]);
                return if (before != after) pos else null;
            },
            .literal => |c| {
                if (pos >= text.len or text[pos] != c) return null;
                return pos + 1;
            },
            .any => {
                if (pos >= text.len) return null;
                return pos + 1;
            },
            .class => |cls| {
                if (pos >= text.len) return null;
                const ch = text[pos];
                var found = false;
                for (cls.ranges) |r| {
                    if (ch >= r[0] and ch <= r[1]) {
                        found = true;
                        break;
                    }
                }
                if (found == cls.negated) return null;
                return pos + 1;
            },
            .group => {
                // Already handled by matchGroup; but for a quantified group like (...)*
                // we need to match one instance here.
                return self.matchGroup(node, text, pos);
            },
        }
    }
};

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const Parser = struct {
    src: []const u8,
    pos: usize,
    alloc: std.mem.Allocator,

    const Error = error{ InvalidRegex, OutOfMemory };

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn parseAlternation(self: *Parser) Error![][]const Regex.Node {
        var alts = std.ArrayList([]const Regex.Node).init(self.alloc);
        errdefer {
            for (alts.items) |alt| {
                for (alt) |*n| self.freeNode(n);
                self.alloc.free(alt);
            }
            alts.deinit();
        }
        const first = try self.parseSequence();
        try alts.append(first);
        while (self.peek()) |c| {
            if (c != '|') break;
            self.pos += 1;
            const next = try self.parseSequence();
            try alts.append(next);
        }
        return try alts.toOwnedSlice();
    }

    fn parseSequence(self: *Parser) Error![]const Regex.Node {
        var nodes = std.ArrayList(Regex.Node).init(self.alloc);
        errdefer {
            for (nodes.items) |*n| self.freeNode(n);
            nodes.deinit();
        }
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            const node = try self.parseAtom();
            try nodes.append(node);
        }
        return try nodes.toOwnedSlice();
    }

    fn parseAtom(self: *Parser) Error!Regex.Node {
        const c = self.src[self.pos];
        var kind: Regex.NodeKind = undefined;
        switch (c) {
            '(' => {
                self.pos += 1;
                // Check for (?:...) non-capturing
                if (self.pos + 1 < self.src.len and self.src[self.pos] == '?' and self.src[self.pos + 1] == ':') {
                    self.pos += 2;
                }
                const alts = try self.parseAlternation();
                if (self.pos >= self.src.len or self.src[self.pos] != ')') return error.InvalidRegex;
                self.pos += 1;
                kind = .{ .group = .{ .alternatives = alts } };
            },
            '\\' => {
                if (self.pos + 1 >= self.src.len) return error.InvalidRegex;
                const next = self.src[self.pos + 1];
                self.pos += 2;
                kind = switch (next) {
                    's' => blk: {
                        const ws_ranges = [_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\n', '\n' }, .{ '\r', '\r' } };
                        const ws_copy = try self.alloc.dupe([2]u8, &ws_ranges);
                        break :blk .{ .class = .{ .ranges = ws_copy, .negated = false } };
                    },
                    'S' => blk: {
                        const ws_ranges = [_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\n', '\n' }, .{ '\r', '\r' } };
                        const ws_copy = try self.alloc.dupe([2]u8, &ws_ranges);
                        break :blk .{ .class = .{ .ranges = ws_copy, .negated = true } };
                    },
                    'd' => blk: {
                        const d_ranges = [_][2]u8{.{ '0', '9' }};
                        const d_copy = try self.alloc.dupe([2]u8, &d_ranges);
                        break :blk .{ .class = .{ .ranges = d_copy, .negated = false } };
                    },
                    'w' => blk: {
                        const w_ranges = [_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } };
                        const w_copy = try self.alloc.dupe([2]u8, &w_ranges);
                        break :blk .{ .class = .{ .ranges = w_copy, .negated = false } };
                    },
                    'b' => .word_boundary,
                    else => .{ .literal = next },
                };
            },
            '.' => {
                kind = .any;
                self.pos += 1;
            },
            '^' => {
                kind = .start;
                self.pos += 1;
            },
            '$' => {
                kind = .end;
                self.pos += 1;
            },
            '[' => {
                self.pos += 1;
                var negated = false;
                if (self.peek()) |c2| {
                    if (c2 == '^') {
                        negated = true;
                        self.pos += 1;
                    }
                }
                var ranges = std.ArrayList([2]u8).init(self.alloc);
                errdefer ranges.deinit();
                while (self.peek()) |c2| {
                    if (c2 == ']') break;
                    const lo = c2;
                    self.pos += 1;
                    if (self.peek()) |c3| {
                        if (c3 == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                            const hi = self.src[self.pos + 1];
                            self.pos += 2;
                            try ranges.append(.{ lo, hi });
                            continue;
                        }
                    }
                    try ranges.append(.{ lo, lo });
                }
                if (self.pos >= self.src.len or self.src[self.pos] != ']') return error.InvalidRegex;
                self.pos += 1;
                kind = .{ .class = .{ .ranges = try ranges.toOwnedSlice(), .negated = negated } };
            },
            else => {
                kind = .{ .literal = c };
                self.pos += 1;
            },
        }

        // Check for quantifier
        var quant: Regex.Quant = .one;
        if (self.peek()) |q| {
            switch (q) {
                '*' => {
                    quant = .star;
                    self.pos += 1;
                },
                '+' => {
                    quant = .plus;
                    self.pos += 1;
                },
                '?' => {
                    quant = .quest;
                    self.pos += 1;
                },
                else => {},
            }
        }
        return .{ .kind = kind, .quant = quant };
    }

    fn freeNode(self: *Parser, node: *const Regex.Node) void {
        switch (node.kind) {
            .class => |c| self.alloc.free(c.ranges),
            .group => |g| {
                for (g.alternatives) |alt| {
                    for (alt) |*n| self.freeNode(n);
                    self.alloc.free(alt);
                }
                self.alloc.free(g.alternatives);
            },
            else => {},
        }
    }
};

pub const Matcher = struct {
    regex: *const Regex,
    text: []const u8,
    pos: usize,

    pub fn next(self: *Matcher) ?[]const u8 {
        while (self.pos <= self.text.len) {
            if (self.regex.matchGroup(&self.regex.root, self.text, self.pos)) |end| {
                const matched = self.text[self.pos..end];
                if (end == self.pos) {
                    self.pos += 1;
                } else {
                    self.pos = end;
                }
                return matched;
            }
            self.pos += 1;
        }
        return null;
    }
};

test "Regex: literal match" {
    const alloc = std.testing.allocator;
    var r = try Regex.compile(alloc, "hello");
    defer r.deinit();
    try std.testing.expectEqualStrings("hello", r.match("say hello world").?);
    try std.testing.expect(r.match("goodbye") == null);
}

test "Regex: quantifiers" {
    const alloc = std.testing.allocator;
    var r = try Regex.compile(alloc, "rm\\s+-rf\\s+/");
    defer r.deinit();
    try std.testing.expect(r.match("rm -rf /") != null);
    try std.testing.expect(r.match("rm  -rf   /") != null);
    try std.testing.expect(r.match("rm -rf /home") != null);
    try std.testing.expect(r.match("ls -la") == null);
}

test "Regex: word boundary" {
    const alloc = std.testing.allocator;
    var r = try Regex.compile(alloc, "\\bmkfs\\b");
    defer r.deinit();
    try std.testing.expect(r.match("run mkfs now") != null);
    try std.testing.expect(r.match("notmkfs") == null);
}

test "Regex: alternation" {
    const alloc = std.testing.allocator;
    var r = try Regex.compile(alloc, "(previous|prior|above)");
    defer r.deinit();
    try std.testing.expect(r.match("ignore previous instructions") != null);
    try std.testing.expect(r.match("ignore prior instructions") != null);
    try std.testing.expect(r.match("ignore above instructions") != null);
    try std.testing.expect(r.match("ignore below instructions") == null);
}

test "Regex: optional group with alternation" {
    const alloc = std.testing.allocator;
    var r = try Regex.compile(alloc, "ignore\\s+(all\\s+)?(previous|prior|above)\\s+instructions");
    defer r.deinit();
    try std.testing.expect(r.match("ignore previous instructions") != null);
    try std.testing.expect(r.match("ignore all previous instructions") != null);
    try std.testing.expect(r.match("ignore prior instructions") != null);
    try std.testing.expect(r.match("ignore above instructions") != null);
    try std.testing.expect(r.match("ignore below instructions") == null);
}

test "Regex: nested groups" {
    const alloc = std.testing.allocator;
    var r = try Regex.compile(alloc, "(you\\s+are\\s+now\\s+in\\s+)?(developer|jailbreak)\\s+mode");
    defer r.deinit();
    try std.testing.expect(r.match("developer mode") != null);
    try std.testing.expect(r.match("you are now in developer mode") != null);
    try std.testing.expect(r.match("jailbreak mode") != null);
    try std.testing.expect(r.match("safe mode") == null);
}

test "Regex: star with backtracking" {
    const alloc = std.testing.allocator;
    var r = try Regex.compile(alloc, "a.*b");
    defer r.deinit();
    try std.testing.expect(r.match("aaab") != null);
    try std.testing.expect(r.match("axxxbxxx") != null);
    try std.testing.expect(r.match("aaa") == null);
}

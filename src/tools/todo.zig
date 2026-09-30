// Todo tool: persistent todo list per session.

const std = @import("std");
const types = @import("../types.zig");
const registry = @import("registry.zig");

pub fn registerAll(reg: *registry.Registry, ctx: *registry.ToolContext) !void {
    // Allocate persistent state and stash it in ctx via a static single-instance
    // (v0.1: one todo list per process; v0.2: per-session via ctx extension).
    if (ctx_global != null) return; // already registered
    const state = try ctx.alloc.create(TodoState);
    state.* = .{
        .items = std.ArrayList(TodoItem).init(ctx.alloc),
        .alloc = ctx.alloc,
    };
    ctx_global = state;

    try reg.add(.{
        .name = "todo_add",
        .description = "Add a todo item. Returns its id.",
        .parameters_schema =
            \\{"type":"object","properties":{"content":{"type":"string"}},"required":["content"]}
        ,
        .run = runAdd,
        .ctx = state,
    });
    try reg.add(.{
        .name = "todo_update",
        .description = "Update a todo item's status. status ∈ {pending, in_progress, completed}.",
        .parameters_schema =
            \\{"type":"object","properties":{"id":{"type":"integer"},"status":{"type":"string"}},"required":["id","status"]}
        ,
        .run = runUpdate,
        .ctx = state,
    });
    try reg.add(.{
        .name = "todo_list",
        .description = "List all todos with their ids, statuses, and content.",
        .parameters_schema =
            \\{"type":"object","properties":{}}
        ,
        .run = runList,
        .ctx = state,
    });
}

var ctx_global: ?*TodoState = null;

const TodoItem = struct {
    id: usize,
    content: []u8,
    status: Status = .pending,
};

const Status = enum { pending, in_progress, completed };

const TodoState = struct {
    items: std.ArrayList(TodoItem),
    alloc: std.mem.Allocator,
    next_id: usize = 1,

    pub fn deinit(self: *TodoState) void {
        for (self.items.items) |it| self.alloc.free(it.content);
        self.items.deinit();
    }
};

fn runAdd(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const state: *TodoState = @ptrCast(@alignCast(ctx));
    const c_v = args.value.object.get("content") orelse return errorResult(alloc, "missing 'content'");
    if (c_v != .string) return errorResult(alloc, "'content' must be string");
    const id = state.next_id;
    state.next_id += 1;
    try state.items.append(.{
        .id = id,
        .content = try state.alloc.dupe(u8, c_v.string),
    });
    var buf: [64]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "added todo #{d}", .{id});
    return .{ .content = try alloc.dupe(u8, msg) };
}

fn runUpdate(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    const state: *TodoState = @ptrCast(@alignCast(ctx));
    const id_v = args.value.object.get("id") orelse return errorResult(alloc, "missing 'id'");
    const st_v = args.value.object.get("status") orelse return errorResult(alloc, "missing 'status'");
    if (id_v != .integer or st_v != .string) return errorResult(alloc, "invalid args");
    const status: Status = blk: {
        if (std.mem.eql(u8, st_v.string, "pending")) break :blk .pending;
        if (std.mem.eql(u8, st_v.string, "in_progress")) break :blk .in_progress;
        if (std.mem.eql(u8, st_v.string, "completed")) break :blk .completed;
        return errorResult(alloc, "status must be pending|in_progress|completed");
    };
    for (state.items.items) |*it| {
        if (it.id == @as(usize, @intCast(id_v.integer))) {
            it.status = status;
            return .{ .content = try alloc.dupe(u8, "ok") };
        }
    }
    return errorResult(alloc, "todo id not found");
}

fn runList(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    _ = args;
    const state: *TodoState = @ptrCast(@alignCast(ctx));
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    if (state.items.items.len == 0) {
        try buf.appendSlice("(no todos)");
        return .{ .content = try buf.toOwnedSlice() };
    }
    for (state.items.items) |it| {
        const st_s = switch (it.status) {
            .pending => "[ ]",
            .in_progress => "[~]",
            .completed => "[x]",
        };
        try buf.writer().print("#{d} {s} {s}\n", .{ it.id, st_s, it.content });
    }
    return .{ .content = try buf.toOwnedSlice() };
}

fn errorResult(alloc: std.mem.Allocator, msg: []const u8) types.ToolResult {
    return .{
        .content = alloc.dupe(u8, msg) catch "",
        .is_error = true,
    };
}

pub fn deinitGlobal(alloc: std.mem.Allocator) void {
    if (ctx_global) |s| {
        s.deinit();
        alloc.destroy(s);
        ctx_global = null;
    }
}

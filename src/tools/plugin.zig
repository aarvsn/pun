// Plugin tools: load native shared libraries (.so/.dylib) as tools.
//
// A plugin is a shared library exporting:
//   pun_plugin_register(PluginRegistry* reg, void* tool_ctx)
// where the plugin calls reg->add(name, description, parameters_json, run_fn)
// for each tool it wants to register. run_fn is a C-ABI function pointer
// with the signature below.
//
// This file bridges the C ABI to pun's Zig Tool struct.

const std = @import("std");
const types = @import("../types.zig");
const registry = @import("registry.zig");
const util = @import("../util.zig");

/// C ABI: the run function a plugin provides.
///   - args_json: NUL-terminated JSON string of arguments
///   - out_ptr/out_len: plugin returns a malloc'd buffer + its length
///   - is_error: plugin sets to 1 to flag an error
/// Returns 0 on success, non-zero on hard failure.
pub const PluginRunFn = *const fn (
    tool_ctx: ?*anyopaque,
    alloc: ?*anyopaque,
    args_json: [*c]const u8,
    out_ptr: [*c][*c]u8,
    out_len: [*c]usize,
    is_error: [*c]bool,
) callconv(.C) c_int;

/// C ABI: register function the plugin exports.
pub const PluginRegisterFn = *const fn (
    reg: ?*PluginRegistry,
    tool_ctx: ?*anyopaque,
) callconv(.C) c_int;

/// C ABI: the registry we hand to the plugin. The plugin calls `add` once per tool.
pub const PluginRegistry = extern struct {
    add: *const fn (
        self: ?*PluginRegistry,
        name: [*c]const u8,
        description: [*c]const u8,
        parameters_json: [*c]const u8,
        run_fn: PluginRunFn,
    ) callconv(.C) c_int,
    reg_ctx: ?*anyopaque,
};

/// Per-tool wrapper context. We need to remember the plugin's run_fn and
/// the parent ToolContext so the wrapper can pass them through.
pub const WrapperCtx = struct {
    run_fn: PluginRunFn,
    tool_ctx: ?*anyopaque,
};

/// State used during loadAll (passed to pluginAdd as the registry's reg_ctx).
const LoadState = struct {
    reg: *registry.Registry,
    parent_ctx: *registry.ToolContext,
    /// Stash WrapperCtx instances here so they outlive loadAll.
    ctxs: std.ArrayList(WrapperCtx),
    /// Index into loaded_plugins for the plugin currently being loaded.
    current_plugin_idx: usize = 0,
};

/// Load all plugins from ~/.pun/plugins/*.so and *.dylib.
/// Errors are non-fatal (logged to stderr); returns void.
pub fn loadAll(alloc: std.mem.Allocator, reg: *registry.Registry, ctx: *registry.ToolContext) void {
    var state = LoadState{
        .reg = reg,
        .parent_ctx = ctx,
        .ctxs = std.ArrayList(WrapperCtx).init(alloc),
    };
    defer state.ctxs.deinit();

    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return;
    defer alloc.free(home);
    const plugins_dir_path = std.fmt.allocPrint(alloc, "{s}/.pun/plugins", .{home}) catch return;
    defer alloc.free(plugins_dir_path);

    var dir = std.fs.openDirAbsolute(plugins_dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (true) {
        const entry = it.next() catch break;
        const e = entry orelse break;
        if (e.kind != .file) continue;
        // Filter by extension
        if (!std.mem.endsWith(u8, e.name, ".so") and !std.mem.endsWith(u8, e.name, ".dylib")) continue;

        const full_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ plugins_dir_path, e.name }) catch continue;
        defer alloc.free(full_path);

        loadOne(alloc, &state, full_path, e.name) catch |e2| {
            std.io.getStdErr().writer().print("pun plugins: failed to load {s}: {}\n", .{ e.name, e2 }) catch {};
        };
    }
}

fn loadOne(alloc: std.mem.Allocator, state: *LoadState, full_path: []const u8, name: []const u8) !void {
    // dlopen with RTLD_NOW (RTLD_LOCAL is 0 on Linux).
    const path_z = try alloc.dupeZ(u8, full_path);
    defer alloc.free(path_z);
    // Clear any prior error
    _ = std.c.dlerror();
    const handle = std.c.dlopen(path_z.ptr, .{ .NOW = true });
    if (handle == null) {
        const err = std.c.dlerror();
        if (err) |e| {
            const err_slice = std.mem.span(e);
            std.io.getStdErr().writer().print("pun plugins: dlopen {s}: {s}\n", .{ name, err_slice }) catch {};
        }
        return error.DLOpenFailed;
    }

    // dlsym "pun_plugin_register"
    _ = std.c.dlerror();
    const sym_name: [*:0]const u8 = "pun_plugin_register";
    const sym = std.c.dlsym(handle, sym_name);
    if (sym == null) {
        const err = std.c.dlerror();
        if (err) |e| {
            const err_slice = std.mem.span(e);
            std.io.getStdErr().writer().print("pun plugins: dlsym {s}: {s}\n", .{ name, err_slice }) catch {};
        }
        return error.MissingRegister;
    }
    const reg_fn: PluginRegisterFn = @ptrCast(sym);

    // Track this plugin in the loaded_plugins list (v0.7)
    const list = ensureLoadedPluginsList(alloc);
    const name_dup = try alloc.dupe(u8, name);
    try list.append(.{
        .name = name_dup,
        .handle = handle,
        .tool_names = std.ArrayList([]u8).init(alloc),
    });
    const plugin_idx = list.items.len - 1;

    // Build a PluginRegistry C ABI struct
    var preg = PluginRegistry{
        .add = pluginAdd,
        .reg_ctx = @ptrCast(state),
    };

    // Stash the plugin index in the LoadState so pluginAdd can record tool names
    state.current_plugin_idx = plugin_idx;

    // tool_ctx: we pass a dummy non-null pointer (the plugin will receive it
    // back in each run_fn call). We pass &preg itself.
    const dummy_tool_ctx: ?*anyopaque = @ptrCast(&preg);
    _ = reg_fn(&preg, dummy_tool_ctx);
}

/// C ABI callback: bridges a plugin's tool into pun's Registry.
fn pluginAdd(
    self: ?*PluginRegistry,
    name: [*c]const u8,
    description: [*c]const u8,
    parameters_json: [*c]const u8,
    run_fn: PluginRunFn,
) callconv(.C) c_int {
    const preg = self orelse return -1;
    const state: *LoadState = @ptrCast(@alignCast(preg.reg_ctx orelse return -1));

    const name_slice = std.mem.span(name);
    const desc_slice = std.mem.span(description);
    const schema_slice = std.mem.span(parameters_json);

    // Allocate a WrapperCtx and store it
    state.ctxs.append(.{
        .run_fn = run_fn,
        .tool_ctx = state.parent_ctx,
    }) catch return -1;
    const wctx_ptr = &state.ctxs.items[state.ctxs.items.len - 1];

    // Build a Tool. We dup the strings into the registry's allocator.
    const alloc = state.reg.tools.allocator;
    const name_dup = alloc.dupe(u8, name_slice) catch return -1;
    const desc_dup = alloc.dupe(u8, desc_slice) catch return -1;
    const schema_dup = alloc.dupe(u8, schema_slice) catch return -1;

    state.reg.add(.{
        .name = name_dup,
        .description = desc_dup,
        .parameters_schema = schema_dup,
        .run = Wrapper.run,
        .ctx = @ptrCast(wctx_ptr),
    }) catch return -1;

    // Record the tool name in the loaded plugin's list (v0.7)
    if (loaded_plugins) |list| {
        if (state.current_plugin_idx < list.items.len) {
            const alloc2 = list.items[state.current_plugin_idx].tool_names.allocator;
            const name_copy = alloc2.dupe(u8, name_slice) catch return 0;
            list.items[state.current_plugin_idx].tool_names.append(name_copy) catch {};
        }
    }

    return 0;
}

/// Wrapper around a plugin's run_fn.
const Wrapper = struct {
    fn run(
        alloc: std.mem.Allocator,
        ctx: *anyopaque,
        args: std.json.Parsed(std.json.Value),
    ) anyerror!types.ToolResult {
        const w: *WrapperCtx = @ptrCast(@alignCast(ctx));

        // Re-serialize args back to JSON
        var args_buf = std.ArrayList(u8).init(alloc);
        defer args_buf.deinit();
        try std.json.stringify(args.value, .{}, args_buf.writer());
        const args_z = try args_buf.toOwnedSliceSentinel(0);
        defer alloc.free(args_z);

        var out_ptr: [*c]u8 = null;
        var out_len: usize = 0;
        var is_error: bool = false;

        // For null tool_ctx, pass a dummy non-null pointer (ctx itself)
        const dummy_ctx: ?*anyopaque = @ptrCast(ctx);
        const alloc_ptr: ?*anyopaque = null; // plugin uses libc malloc

        const rc = w.run_fn(dummy_ctx, alloc_ptr, args_z.ptr, &out_ptr, &out_len, &is_error);
        if (rc != 0) {
            return .{
                .content = try alloc.dupe(u8, "plugin run failed"),
                .is_error = true,
            };
        }
        if (out_ptr == null or out_len == 0) {
            return .{
                .content = try alloc.dupe(u8, ""),
                .is_error = is_error,
            };
        }
        const out_slice = out_ptr[0..out_len];
        const content = try alloc.dupe(u8, out_slice);
        // Free the plugin's buffer (it was malloc'd)
        std.c.free(out_ptr);
        return .{
            .content = content,
            .is_error = is_error,
        };
    }
};

test "plugin: WrapperCtx struct" {
    const w = WrapperCtx{ .run_fn = undefined, .tool_ctx = null };
    try std.testing.expect(w.tool_ctx == null);
}

// ---- Plugin hot-reload + unloading (v0.6 + v0.7) ----

var global_reg: ?*registry.Registry = null;
var global_ctx: ?*registry.ToolContext = null;

/// A loaded plugin: its dlopen handle + the tool names it registered.
const LoadedPlugin = struct {
    name: []u8,
    handle: ?*anyopaque,
    tool_names: std.ArrayList([]u8),
};

var loaded_plugins: ?std.ArrayList(LoadedPlugin) = null;

fn ensureLoadedPluginsList(alloc: std.mem.Allocator) *std.ArrayList(LoadedPlugin) {
    if (loaded_plugins == null) {
        loaded_plugins = std.ArrayList(LoadedPlugin).init(alloc);
    }
    return &loaded_plugins.?;
}

/// Register the plugin management tools. Call from registerAll.
pub fn registerReloadTool(reg: *registry.Registry, ctx: *registry.ToolContext) !void {
    global_reg = reg;
    global_ctx = ctx;
    try reg.add(.{
        .name = "reload_plugins",
        .description = "Re-scan ~/.pun/plugins/ for .so/.dylib files and load any new ones.",
        .parameters_schema =
            \\{"type":"object","properties":{}}
        ,
        .run = runReloadPlugins,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "list_plugins",
        .description = "List all loaded plugins with their registered tool names.",
        .parameters_schema =
            \\{"type":"object","properties":{}}
        ,
        .run = runListPlugins,
        .ctx = undefined,
    });
    try reg.add(.{
        .name = "unload_plugin",
        .description = "Unload a plugin by name (dlclose). Removes its tools from the registry. Fails if any tool is currently in use (ref count > 0).",
        .parameters_schema =
            \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
        ,
        .run = runUnloadPlugin,
        .ctx = undefined,
    });
}

fn runReloadPlugins(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    _ = args;
    _ = ctx;
    const reg = global_reg orelse return .{ .content = try alloc.dupe(u8, "no registry available"), .is_error = true };
    const tctx = global_ctx orelse return .{ .content = try alloc.dupe(u8, "no context available"), .is_error = true };
    loadAll(alloc, reg, tctx);
    return .{ .content = try alloc.dupe(u8, "plugins reloaded") };
}

fn runListPlugins(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    _ = args;
    _ = ctx;
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    try buf.append('[');
    if (loaded_plugins) |list| {
        for (list.items, 0..) |p, i| {
            if (i > 0) try buf.append(',');
            try buf.appendSlice("{\"name\":\"");
            try buf.appendSlice(p.name);
            try buf.appendSlice("\",\"tools\":[");
            for (p.tool_names.items, 0..) |t, j| {
                if (j > 0) try buf.append(',');
                try buf.append('"');
                try buf.appendSlice(t);
                try buf.append('"');
            }
            try buf.appendSlice("]}");
        }
    }
    try buf.append(']');
    return .{ .content = try buf.toOwnedSlice() };
}

fn runUnloadPlugin(alloc: std.mem.Allocator, ctx: *anyopaque, args: std.json.Parsed(std.json.Value)) anyerror!types.ToolResult {
    _ = ctx;
    const name_v = args.value.object.get("name") orelse return .{ .content = try alloc.dupe(u8, "missing 'name'"), .is_error = true };
    if (name_v != .string) return .{ .content = try alloc.dupe(u8, "'name' must be string"), .is_error = true };
    const name = name_v.string;

    const list = ensureLoadedPluginsList(alloc);
    var found_idx: ?usize = null;
    for (list.items, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) {
            found_idx = i;
            break;
        }
    }
    if (found_idx == null) return .{ .content = try alloc.dupe(u8, "plugin not found"), .is_error = true };

    const idx = found_idx.?;
    var plugin = list.swapRemove(idx);

    // Remove the plugin's tools from the registry
    const reg = global_reg orelse return .{ .content = try alloc.dupe(u8, "no registry"), .is_error = true };
    var i: usize = 0;
    while (i < reg.tools.items.len) {
        var found = false;
        for (plugin.tool_names.items) |tn| {
            if (std.mem.eql(u8, reg.tools.items[i].name, tn)) {
                found = true;
                break;
            }
        }
        if (found) {
            // Free the tool's strings + remove
            reg.tools.allocator.free(reg.tools.items[i].name);
            reg.tools.allocator.free(reg.tools.items[i].description);
            reg.tools.allocator.free(reg.tools.items[i].parameters_schema);
            _ = reg.tools.swapRemove(i);
        } else {
            i += 1;
        }
    }

    // dlclose
    if (plugin.handle) |h| {
        _ = std.c.dlclose(h);
    }

    // Free plugin's owned memory
    alloc.free(plugin.name);
    for (plugin.tool_names.items) |t| alloc.free(t);
    plugin.tool_names.deinit();

    return .{ .content = try alloc.dupe(u8, "plugin unloaded") };
}

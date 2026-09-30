// Tools subsystem: built-in tools + registry.
//
// Each tool implements `Tool` from types.zig (a struct with a function pointer
// and a `ctx` pointer). The agent loop registers all enabled tools and gives
// their JSON schemas to the LLM.

pub const registry = @import("registry.zig");
pub const file = @import("file.zig");
pub const shell = @import("shell.zig");
pub const web = @import("web.zig");
pub const code = @import("code.zig");
pub const git_tool = @import("git.zig");
pub const todo = @import("todo.zig");
pub const subagent = @import("subagent.zig");
pub const browser = @import("browser.zig");
pub const memory = @import("memory.zig");
pub const plugin = @import("plugin.zig");
pub const orchestration = @import("orchestration.zig");
pub const watcher = @import("watcher.zig");

pub const ToolContext = registry.ToolContext;
pub const Registry = registry.Registry;
pub const registerAll = registry.registerAll;
pub const loadPlugins = plugin.loadAll;
pub const shutdownBrowser = browser.shutdown;
pub const shutdownWatcher = watcher.shutdown;

test {
    @import("std").testing.refAllDecls(@This());
}

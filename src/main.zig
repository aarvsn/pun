// pun — a BYOK, security-first AI coding agent, written in Zig.
//
// main.zig is the CLI entrypoint. It dispatches to:
//   - `pun`               → interactive TUI
//   - `pun -p "prompt"`   → one-shot
//   - `pun -f task.json`  → batch from JSON
//   - `pun config init`   → write starter ~/.pun/config.toml
//   - `pun config show`   → print resolved config
//   - `pun vault set/get` → manage the encrypted secrets vault
//   - `pun version`

const std = @import("std");
const pun = @import("pun.zig");

const Cmd = enum {
    repl,
    oneshot,
    batch,
    config_init,
    config_show,
    vault_set,
    vault_get,
    vault_list,
    mcp,
    web,
    version,
    help,
};

const Args = struct {
    cmd: Cmd = .repl,
    prompt: ?[]const u8 = null,
    file: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    allow_shell: bool = false,
    no_shell: bool = false,
    yes: bool = false, // auto-yes for confirmation gates
    json_out: bool = false,
    vault_key: ?[]const u8 = null,
    vault_value: ?[]const u8 = null,
    verbose: bool = false,
    port: u16 = 7878,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);

    const args = try parseArgs(alloc, argv);
    defer freeArgs(alloc, args);

    var cfg = try pun.config.loadConfig(alloc, args.config_path, args.workspace, args.profile);
    defer cfg.deinit();

    // Apply CLI overrides to active profile/provider
    if (args.provider) |p| cfg.setActiveProvider(p) catch |e| {
        try stderrPrint("error: unknown provider {s}: {}\n", .{ p, e });
        std.process.exit(2);
    };
    if (args.model) |m| cfg.setActiveModel(m);
    if (args.allow_shell) cfg.shell_disabled = false;
    if (args.no_shell) cfg.shell_disabled = true;
    if (args.yes) cfg.auto_yes = true;

    // Install SIGHUP-based hot reload (best-effort; non-fatal).
    pun.config.hot_reload.install(alloc, args.config_path) catch {};

    // Initialize persistent conversation history (best-effort; non-fatal).
    pun.loop.history.initSession(alloc) catch {};
    defer pun.loop.history.deinitSession();

    switch (args.cmd) {
        .version => try stdoutPrint("pun {s}\nzig {s}\n", .{ pun.version, @import("builtin").zig_version_string }),
        .help => try printHelp(),
        .config_init => pun.config.initConfig(alloc) catch |e| {
            try stderrPrint("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        },
        .config_show => try pun.config.printConfig(alloc, &cfg),
        .vault_set => {
            if (args.vault_key == null or args.vault_value == null) {
                try stderrPrint("usage: pun vault set <key> <value>\n", .{});
                std.process.exit(2);
            }
            try pun.security.vault.cliSet(alloc, &cfg, args.vault_key.?, args.vault_value.?);
        },
        .vault_get => {
            if (args.vault_key == null) {
                try stderrPrint("usage: pun vault get <key>\n", .{});
                std.process.exit(2);
            }
            try pun.security.vault.cliGet(alloc, &cfg, args.vault_key.?);
        },
        .vault_list => try pun.security.vault.cliList(alloc, &cfg),
        .oneshot => try pun.cli.oneshot.run(alloc, &cfg, args.prompt.?, args.json_out),
        .batch => try pun.cli.batch.run(alloc, &cfg, args.file.?),
        .repl => try pun.tui.app.run(alloc, &cfg),
        .mcp => try pun.mcp.run(alloc, &cfg),
        .web => try pun.web.run(alloc, &cfg, args.port),
    }
}

fn parseArgs(alloc: std.mem.Allocator, argv: [][:0]u8) !Args {
    var a = Args{};
    if (argv.len < 2) return a;

    var i: usize = 1;
    // First positional might be a subcommand
    if (argv[1].len > 0 and argv[1][0] != '-') {
        if (std.mem.eql(u8, argv[1], "config")) {
            if (argv.len > 2 and std.mem.eql(u8, argv[2], "init")) {
                a.cmd = .config_init;
                i = 3;
            } else if (argv.len > 2 and std.mem.eql(u8, argv[2], "show")) {
                a.cmd = .config_show;
                i = 3;
            } else {
                a.cmd = .help;
                i = 2;
            }
        } else if (std.mem.eql(u8, argv[1], "vault")) {
            if (argv.len > 2 and std.mem.eql(u8, argv[2], "set")) {
                a.cmd = .vault_set;
                if (argv.len > 3) a.vault_key = try alloc.dupe(u8, argv[3]);
                if (argv.len > 4) a.vault_value = try alloc.dupe(u8, argv[4]);
                i = 5;
            } else if (argv.len > 2 and std.mem.eql(u8, argv[2], "get")) {
                a.cmd = .vault_get;
                if (argv.len > 3) a.vault_key = try alloc.dupe(u8, argv[3]);
                i = 4;
            } else if (argv.len > 2 and std.mem.eql(u8, argv[2], "list")) {
                a.cmd = .vault_list;
                i = 3;
            } else {
                a.cmd = .help;
                i = 2;
            }
        } else if (std.mem.eql(u8, argv[1], "mcp")) {
            a.cmd = .mcp;
            i = 2;
        } else if (std.mem.eql(u8, argv[1], "web")) {
            a.cmd = .web;
            i = 2;
        } else if (std.mem.eql(u8, argv[1], "version") or std.mem.eql(u8, argv[1], "-v") or std.mem.eql(u8, argv[1], "--version")) {
            a.cmd = .version;
            i = 2;
        } else if (std.mem.eql(u8, argv[1], "help") or std.mem.eql(u8, argv[1], "-h") or std.mem.eql(u8, argv[1], "--help")) {
            a.cmd = .help;
            i = 2;
        }
    }

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--prompt")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            a.cmd = .oneshot;
            a.prompt = try alloc.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            a.cmd = .batch;
            a.file = try alloc.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            a.profile = try alloc.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--provider")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            a.provider = try alloc.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            a.model = try alloc.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--workspace") or std.mem.eql(u8, arg, "-w")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            a.workspace = try alloc.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            a.config_path = try alloc.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--allow-shell")) {
            a.allow_shell = true;
        } else if (std.mem.eql(u8, arg, "--no-shell")) {
            a.no_shell = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            a.yes = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            a.json_out = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-V")) {
            a.verbose = true;
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            a.port = std.fmt.parseInt(u16, argv[i], 10) catch return error.InvalidPort;
        } else {
            try stderrPrint("warning: unknown arg {s}\n", .{arg});
        }
    }
    return a;
}

fn freeArgs(alloc: std.mem.Allocator, a: Args) void {
    if (a.prompt) |s| alloc.free(s);
    if (a.file) |s| alloc.free(s);
    if (a.profile) |s| alloc.free(s);
    if (a.provider) |s| alloc.free(s);
    if (a.model) |s| alloc.free(s);
    if (a.workspace) |s| alloc.free(s);
    if (a.config_path) |s| alloc.free(s);
    if (a.vault_key) |s| alloc.free(s);
    if (a.vault_value) |s| alloc.free(s);
}

fn printHelp() !void {
    const help =
        \\pun — a BYOK, security-first AI coding agent.
        \\
        \\USAGE
        \\  pun                          # interactive TUI (default)
        \\  pun -p "prompt"              # one-shot
        \\  pun -f task.json             # batch from JSON file
        \\  pun config init              # write starter ~/.pun/config.toml
        \\  pun config show              # print resolved config
        \\  pun vault set <key> <value>  # store secret in encrypted vault
        \\  pun vault get <key>          # retrieve secret
        \\  pun vault list               # list vault keys (no values)
        \\  pun mcp                      # run as an MCP server (JSON-RPC over stdio)
        \\  pun web [--port 7878]        # run a local web UI
        \\  pun version                  # print version
        \\  pun help                     # this message
        \\
        \\FLAGS
        \\  --profile <name>             # use named profile from config
        \\  --provider <name>            # override active provider
        \\  --model <id>                 # override active model
        \\  --workspace <path>           # override security/shell workspace
        \\  --config <path>              # path to config.toml
        \\  --allow-shell                # enable shell tool (overrides config)
        \\  --no-shell                   # disable shell tool
        \\  --yes, -y                    # auto-yes all confirmation gates
        \\  --json                       # one-shot: emit JSON result
        \\  --port <N>                   # port for `pun web` (default 7878)
        \\  --verbose, -V                # debug logging
        \\
        \\ENV VARS
        \\  PUN_CONFIG                   # path to config.toml
        \\  PUN_DEFAULT_PROFILE          # override default profile
        \\  PUN_WORKSPACE                # override workspace
        \\  PUN_AUDIT_LOG                # override audit log path
        \\  PUN_VAULT_PASSPHRASE         # vault unlock passphrase
        \\  <PROVIDER>_API_KEY           # per-provider API key (e.g. ANTHROPIC_API_KEY)
        \\
        \\CONFIG
        \\  ~/.pun/config.toml          # main config (see pun config init)
        \\  ~/.pun/vault.age            # encrypted secrets vault
        \\  ~/.pun/audit.jsonl          # append-only audit log
        \\
        \\EXAMPLES
        \\  pun config init
        \\  pun vault set anthropic sk-ant-...
        \\  pun -p "refactor src/main.zig to use std.ArrayList" --profile deep
        \\  pun -f tasks/refactor.json --json > out.json
        \\
    ;
    try stdoutPrint("{s}\n", .{help});
}

// --- stdout/stderr helpers (kept tiny to avoid pulling in std.io wrappers everywhere) ---

pub fn stdoutPrint(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, fmt, args);
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(out);
}

pub fn stderrPrint(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, fmt, args);
    const stderr = std.io.getStdErr().writer();
    try stderr.writeAll(out);
}

test "parseArgs: default is repl" {
    const argv = [_][]u8{ "pun" };
    const a = try parseArgs(std.testing.allocator, @constCast(&argv));
    defer freeArgs(std.testing.allocator, a);
    try std.testing.expectEqual(Cmd.repl, a.cmd);
}

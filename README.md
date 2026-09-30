# pun

`pun` is a BYOK AI coding agent written in Zig.

It provides a CLI/TUI, multiple LLM providers, sandboxed tools, MCP, plugins, memory, session history, and a web UI.

## Status

**v0.7** — 60/60 tests passing.

Current features include:

- 8+ LLM providers
- Encrypted API key vault
- Workspace and command restrictions
- Network controls
- Audit logging and token limits
- MCP server and resources
- Plugin loading/unloading
- Multi-session history and search
- Web UI with WebSocket streaming
- Headless browser tools
- Persistent memory

## Build

Requirements: **Zig 0.14.0**

```sh
zig build
zig build test
zig build run -- --help
```

Binary:

```text
zig-out/bin/pun
```

## Quick start

Initialize the config:

```sh
./zig-out/bin/pun config init
```

Store an API key:

```sh
export PUN_VAULT_PASSPHRASE="your-passphrase"
./zig-out/bin/pun vault set anthropic sk-ant-...
```

Start `pun`:

```sh
./zig-out/bin/pun
```

One-shot mode:

```sh
./zig-out/bin/pun -p "refactor src/main.zig"
```

Batch mode:

```sh
./zig-out/bin/pun -f tasks.json --json
```

## Providers

Supported providers include:

- Anthropic
- OpenAI
- OpenAI-compatible APIs
- Google Gemini
- Z.ai GLM
- DeepSeek
- Mistral
- xAI Grok

Provider configuration is stored in:

```text
~/.pun/config.toml
```

Example:

```toml
[providers.anthropic]
kind = "anthropic"
api_key_env = "ANTHROPIC_API_KEY"
default_model = "claude-sonnet-4-5"
```

Keys are checked in this order:

1. Encrypted vault
2. Environment variable
3. Config file `api_key`

## Security

`pun` restricts what its tools can do.

- Workspace path jail
- Command allow/deny rules
- Network allowlist
- Encrypted secrets vault
- Prompt-injection checks
- Append-only audit log
- Token limits
- Confirmation prompts
- Shell timeouts
- Optional Docker isolation

Network access for shell commands is disabled by default.

## Tools

Built-in tools include:

```text
read_file       write_file       edit_file
list_dir        grep             run_command
fetch_url       web_search       run_python
run_zig         git_status       git_diff
git_log         git_commit       todo_add
todo_update     todo_list        spawn_agent
browser_*       memory_*
```

## CLI

```text
pun                          Interactive TUI
pun -p "prompt"             One-shot prompt
pun -f task.json             Batch mode
pun config init              Create config
pun config show              Show config
pun vault set <key> <value>  Store a secret
pun vault get <key>          Get a secret
pun vault list               List vault keys
pun version                  Show version
pun help                     Show help
```

## License

MIT. See [LICENSE](LICENSE).

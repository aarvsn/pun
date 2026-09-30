# pun plugins

Native shared libraries that pun loads at startup to register additional tools.

## Layout

```
plugins/
├── pun_plugin.h    # C SDK header — required by every plugin
├── echo.c          # C example: echoes arguments back as JSON
├── uuid.zig        # Zig example: generates RFC 4122 v4 UUIDs
├── base64.rs       # Rust example: base64-encodes a string
└── README.md       # this file
```

## How plugins work

A plugin is a `.so` (Linux) or `.dylib` (macOS) file placed in `~/.pun/plugins/`. At startup, pun scans that directory and `dlopen`s each library. Each library must export one function:

```c
int pun_plugin_register(PluginRegistry* reg, void* tool_ctx);
```

Inside that function, the plugin calls `reg->add(...)` once per tool it wants to register. The `add` function takes:

| argument           | purpose                                                    |
| ------------------ | ---------------------------------------------------------- |
| `name`             | tool name (the model uses this to call the tool)           |
| `description`      | human-readable description shown to the model              |
| `parameters_json`  | JSON-schema-as-string describing the tool's arguments      |
| `run_fn`           | C-ABI function pointer invoked when the model calls the tool |

The `run_fn` signature:

```c
int run(void* tool_ctx, void* alloc, const char* args_json,
        char** out_ptr, size_t* out_len, int* is_error);
```

- `args_json` is NUL-terminated JSON the model produced for this call.
- The plugin `malloc`s a buffer, copies its text result in, and sets `*out_ptr` / `*out_len`.
- Set `*is_error = 1` to flag the result as an error.
- Return `0` on success, non-zero on hard failure.
- pun frees `*out_ptr` with `free()` after copying — do not free it yourself.

## Build + install

### C (echo)

```sh
cd plugins
cc -shared -fPIC -I. echo.c -o echo.so
mkdir -p ~/.pun/plugins
cp echo.so ~/.pun/plugins/
```

### Zig (uuid)

```sh
cd plugins
zig build-lib -dynamic -fPIC uuid.zig
mkdir -p ~/.pun/plugins
cp uuid.so ~/.pun/plugins/
```

### Rust (base64)

```sh
cd plugins
rustc --edition 2021 --crate-type cdylib base64.rs -o libbase64.so
mkdir -p ~/.pun/plugins
cp libbase64.so ~/.pun/plugins/
```

## Verify

After installing one or more plugins, run pun and check the audit log (or ask the model `what tools do you have?`). You should see the plugin's tools listed alongside the built-ins.

## Caveats

- Plugins share the pun process — they have full access to the agent's memory and files. Only install plugins you trust.
- Plugin load failures are logged to stderr but do not abort startup.
- A plugin's `tool_ctx` argument is currently a dummy non-null pointer reserved for future use.

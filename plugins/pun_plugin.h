// pun_plugin.h — C SDK for writing pun plugins.
//
// A pun plugin is a shared library (.so on Linux, .dylib on macOS) that
// exports a single function:
//
//   int pun_plugin_register(PluginRegistry* reg, void* tool_ctx);
//
// Inside that function, the plugin calls reg->add(...) once per tool it
// wants to register. The run_fn is called by pun when the model invokes
// that tool.
//
// The run_fn receives:
//   - tool_ctx: opaque pointer (the same one passed to pun_plugin_register)
//   - alloc:    opaque pointer (currently NULL; plugins should use malloc)
//   - args_json: NUL-terminated JSON string of the arguments object
//   - out_ptr:  plugin sets *out_ptr to a malloc'd buffer containing the
//               text result
//   - out_len:  plugin sets *out_len to the length of *out_ptr
//   - is_error: plugin sets *is_error to 1 to flag the result as an error
//
// The plugin MUST NOT free *out_ptr — pun frees it with free() after copying.
//
// Return 0 on success, non-zero on hard failure (in which case pun ignores
// *out_ptr/*out_len and reports a generic error to the model).

#ifndef PUN_PLUGIN_H
#define PUN_PLUGIN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*pun_plugin_run_fn)(
    void* tool_ctx,
    void* alloc,
    const char* args_json,
    char** out_ptr,
    size_t* out_len,
    int* is_error);

typedef int (*pun_plugin_add_fn)(
    void* reg_handle,
    const char* name,
    const char* description,
    const char* parameters_json,
    pun_plugin_run_fn run_fn);

typedef struct {
    pun_plugin_add_fn add;
    void* reg_ctx;
} PluginRegistry;

typedef int (*pun_plugin_register_fn)(PluginRegistry* reg, void* tool_ctx);

// Plugins must export:
//   int pun_plugin_register(PluginRegistry* reg, void* tool_ctx);

#ifdef __cplusplus
}
#endif

#endif // PUN_PLUGIN_H

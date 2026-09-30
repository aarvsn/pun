// echo.c — minimal example pun plugin.
//
// Provides one tool, "echo", that returns its input verbatim. Useful for
// testing the plugin loader end-to-end.
//
// Build:
//   cc -shared -fPIC -I. echo.c -o echo.so
// Install:
//   mkdir -p ~/.pun/plugins && cp echo.so ~/.pun/plugins/

#include "pun_plugin.h"
#include <stdlib.h>
#include <string.h>

static int echo_run(
    void* tool_ctx,
    void* alloc,
    const char* args_json,
    char** out_ptr,
    size_t* out_len,
    int* is_error)
{
    (void)tool_ctx;
    (void)alloc;
    (void)is_error;

    // Echo back the raw args JSON so the model can see what it sent.
    size_t n = strlen(args_json);
    char* buf = (char*)malloc(n);
    if (buf == NULL) return 1;
    memcpy(buf, args_json, n);
    *out_ptr = buf;
    *out_len = n;
    return 0;
}

int pun_plugin_register(PluginRegistry* reg, void* tool_ctx) {
    (void)tool_ctx;
    return reg->add(
        reg->reg_ctx,
        "echo",
        "Echo the arguments back as JSON. Useful for testing.",
        "{\"type\":\"object\",\"properties\":{\"msg\":{\"type\":\"string\"}},\"required\":[\"msg\"]}",
        echo_run);
}

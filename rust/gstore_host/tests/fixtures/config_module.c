/*
 * ABI v5 config-consumer fixture (Todo 11 / Todo 13 real-surface harness).
 *
 * Exports a real `libgstore_mod_<name>.so` module whose register callback keeps
 * the host-injected `GStoreConfigApiV1`, optionally subscribes to its own module
 * (whole-module) and to the foreign `theme` module, and records every delivered
 * change. `call("dump")` returns the recorded changes as newline-delimited JSON.
 *
 * Build-time parameters:
 *   - `FIXTURE_NAME`          module name (default `download`)
 *   - `FIXTURE_ABI`           advertised ABI probe value (default 5)
 *   - `FIXTURE_MIN_HOST_ABI`  required host ABI (default 5)
 *   - `FIXTURE_AUTO_SUBSCRIBE` 1 = subscribe on register (default), 0 = only via
 *                            the explicit `subscribe` call.
 *
 * Generic calls (payloads are `|`-separated; an empty module/key means NULL):
 *   - `get`       `<module>|<key>`          -> `<code>|<json>`
 *   - `set`       `<key>|<value_json>`      -> `<code>`
 *   - `list`      `<module>`                -> `<code>|<json array>`
 *   - `subscribe` `<module>|<key>`          -> `<code>|<token>`
 *   - `unsubscribe` `<token>`               -> `<code>`
 *   - `clear_records`                       -> `ok`
 *   - `entry_probe`                         -> `<abi>|<entry_size>|<has_config>`
 *
 * `set_invalid` exercises the malformed-JSON boundary. `on_event` is
 * intentionally NULL to prove a module without it does not break config writes.
 *
 * Compiled at test time with `cc -shared -fPIC -std=c99 -Wall -Wextra -Werror`.
 */

#define _DEFAULT_SOURCE

#ifndef FIXTURE_NAME
#define FIXTURE_NAME download
#endif

#ifndef FIXTURE_ABI
#define FIXTURE_ABI 5
#endif

#ifndef FIXTURE_MIN_HOST_ABI
#define FIXTURE_MIN_HOST_ABI 5
#endif

#ifndef FIXTURE_AUTO_SUBSCRIBE
#define FIXTURE_AUTO_SUBSCRIBE 1
#endif

#ifndef FIXTURE_ON_EVENT
#define FIXTURE_ON_EVENT 0
#endif

#define GS_STR2(x) #x
#define GS_STR(x) GS_STR2(x)
#define GS_CAT2(a, b) a##b
#define GS_CAT(a, b) GS_CAT2(a, b)

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    uint8_t *ptr;
    size_t len;
} ByteBuf;

typedef struct ConfigApi {
    uint32_t abi_version;
    uint32_t struct_size;
    uint64_t capabilities;
    void *context;
    int (*get)(void *ctx, const char *module_or_null, const char *key, ByteBuf *out_json);
    int (*set)(void *ctx, const char *key, const char *value_json);
    int (*list)(void *ctx, const char *module_or_null, ByteBuf *out_json);
    int (*subscribe)(void *ctx, const char *module_or_null, const char *key_or_null,
                     void *user_ctx, int (*callback)(void *, const char *), uint64_t *out_token);
    int (*unsubscribe)(void *ctx, uint64_t token);
    void (*free_buf)(ByteBuf buf);
} ConfigApi;

typedef struct {
    uint32_t abi_version;
    uint32_t entry_size;
    void (*log)(int level, const char *msg);
    void *(*alloc)(size_t size);
    void (*free)(void *ptr);
    void (*emit_event)(uint64_t module_id, uint64_t instance_id, const uint8_t *data, size_t len);
    void *context;
    int (*protect_fd)(int fd);
    const void *platform;
    const ConfigApi *config;
} ModuleEntry;

typedef struct {
    const char *name;
    uint32_t version;
    uint32_t min_host_abi;
    int (*init)(void);
    int (*create)(const uint8_t *config, size_t config_len, uint64_t *out_instance);
    int (*call)(uint64_t instance, const char *method, const uint8_t *payload,
                size_t payload_len, uint8_t **out_data, size_t *out_len);
    int (*cancel)(uint64_t instance, const char *request_id);
    int (*destroy)(uint64_t instance);
    int (*shutdown)(void);
    void *(*alloc)(size_t size);
    void (*free)(void *ptr);
    int (*on_event)(uint64_t module_id, const char *kind, const uint8_t *data, size_t data_len);
} ModuleApi;

#define MAX_CHANGES 64
#define CHANGE_CAP 1024
#define ARGS_CAP 4096

static const ConfigApi *g_config;
static uint64_t g_own_token;
static uint64_t g_foreign_token;
static int g_change_count;
static int g_slow;
static char g_changes[MAX_CHANGES][CHANGE_CAP];
static uint32_t g_entry_abi;
static uint32_t g_entry_size;
static int g_entry_has_config;

static void module_free(void *ptr) {
    free(ptr);
}

static int env_int(const char *name, int fallback) {
    const char *raw = getenv(name);
    if (raw == NULL || *raw == '\0') {
        return fallback;
    }
    return atoi(raw);
}

static void record_to_file(const char *change) {
    const char *path = getenv("GS_CONFIG_RECORD_FILE");
    FILE *file;
    if (path == NULL) {
        return;
    }
    file = fopen(path, "a");
    if (file == NULL) {
        return;
    }
    fprintf(file, "%s\n", change);
    fclose(file);
}

static void record_marker(const char *marker, const char *detail) {
    const char *path = getenv("GS_CONFIG_RECORD_FILE");
    FILE *file;
    if (path == NULL) {
        return;
    }
    file = fopen(path, "a");
    if (file == NULL) {
        return;
    }
    if (detail == NULL) {
        fprintf(file, "%s\n", marker);
    } else {
        fprintf(file, "%s %s\n", marker, detail);
    }
    fclose(file);
}

static int record_change(void *user_ctx, const char *change) {
    (void)user_ctx;
    if (change == NULL) {
        return -11;
    }
    record_marker("enter", change);
    {
        int slow_ms = g_slow ? 300 : env_int("GS_CONFIG_SLOW_MS", 0);
        if (slow_ms > 0) {
            usleep((useconds_t)slow_ms * 1000);
        }
    }
    record_to_file(change);
    record_marker("deliver", change);
    if (g_change_count < MAX_CHANGES) {
        snprintf(g_changes[g_change_count], CHANGE_CAP, "%s", change);
        g_change_count += 1;
    }
    return 0;
}

static int module_create(const uint8_t *config, size_t config_len, uint64_t *out_instance) {
    (void)config;
    (void)config_len;
    if (out_instance == NULL) {
        return -11;
    }
    *out_instance = 1;
    return 0;
}

static int reply_text(const char *text, uint8_t **out_data, size_t *out_len) {
    size_t len = strlen(text);
    char *copy = (char *)malloc(len + 1);
    if (copy == NULL) {
        return -7;
    }
    memcpy(copy, text, len + 1);
    *out_data = (uint8_t *)copy;
    *out_len = len;
    return 0;
}

static int reply_code_json(int code, const char *json, uint8_t **out_data, size_t *out_len) {
    size_t json_len = json == NULL ? 0 : strlen(json);
    size_t cap = json_len + 32;
    char *text = (char *)malloc(cap);
    if (text == NULL) {
        return -7;
    }
    snprintf(text, cap, "%d|%s", code, json == NULL ? "" : json);
    *out_data = (uint8_t *)text;
    *out_len = strlen(text);
    return 0;
}

static int copy_payload(const uint8_t *payload, size_t payload_len, char *buf, size_t cap) {
    if (payload == NULL || payload_len >= cap) {
        return -1;
    }
    memcpy(buf, payload, payload_len);
    buf[payload_len] = '\0';
    return 0;
}

/* Copies a host-owned ByteBuf into a malloc'd C string, then frees the host buf. */
static char *take_json(const ConfigApi *config, ByteBuf *buf) {
    char *copy = NULL;
    if (buf->ptr != NULL && buf->len > 0) {
        copy = (char *)malloc(buf->len + 1);
        if (copy != NULL) {
            memcpy(copy, buf->ptr, buf->len);
            copy[buf->len] = '\0';
        }
    }
    if (config != NULL && config->free_buf != NULL) {
        config->free_buf(*buf);
    }
    buf->ptr = NULL;
    buf->len = 0;
    return copy;
}

static int cmd_get(const uint8_t *payload, size_t payload_len, uint8_t **out_data,
                   size_t *out_len) {
    char args[ARGS_CAP];
    char *sep;
    ByteBuf out = {NULL, 0};
    int code = -11;
    char *json;
    if (copy_payload(payload, payload_len, args, sizeof(args)) != 0) {
        return reply_code_json(-11, "", out_data, out_len);
    }
    sep = strchr(args, '|');
    if (sep == NULL) {
        return reply_code_json(-11, "", out_data, out_len);
    }
    *sep = '\0';
    if (g_config != NULL && g_config->get != NULL) {
        code = g_config->get(g_config->context, args[0] == '\0' ? NULL : args, sep + 1, &out);
    }
    json = take_json(g_config, &out);
    code = reply_code_json(code, json, out_data, out_len);
    free(json);
    return code;
}

static int cmd_list(const uint8_t *payload, size_t payload_len, uint8_t **out_data,
                    size_t *out_len) {
    char args[ARGS_CAP];
    ByteBuf out = {NULL, 0};
    int code = -11;
    char *json;
    if (copy_payload(payload, payload_len, args, sizeof(args)) != 0) {
        return reply_code_json(-11, "", out_data, out_len);
    }
    if (g_config != NULL && g_config->list != NULL) {
        code = g_config->list(g_config->context, args[0] == '\0' ? NULL : args, &out);
    }
    json = take_json(g_config, &out);
    code = reply_code_json(code, json, out_data, out_len);
    free(json);
    return code;
}

static int cmd_set(const uint8_t *payload, size_t payload_len, uint8_t **out_data,
                   size_t *out_len) {
    char args[ARGS_CAP];
    char *sep;
    char text[32];
    int code = -11;
    if (copy_payload(payload, payload_len, args, sizeof(args)) != 0) {
        snprintf(text, sizeof(text), "%d", code);
        return reply_text(text, out_data, out_len);
    }
    sep = strchr(args, '|');
    if (sep == NULL) {
        snprintf(text, sizeof(text), "%d", code);
        return reply_text(text, out_data, out_len);
    }
    *sep = '\0';
    if (g_config != NULL && g_config->set != NULL) {
        code = g_config->set(g_config->context, args, sep + 1);
    }
    snprintf(text, sizeof(text), "%d", code);
    return reply_text(text, out_data, out_len);
}

static int cmd_subscribe(const uint8_t *payload, size_t payload_len, uint8_t **out_data,
                         size_t *out_len) {
    char args[ARGS_CAP];
    char *sep;
    char text[64];
    uint64_t token = 0;
    int code = -11;
    if (copy_payload(payload, payload_len, args, sizeof(args)) != 0) {
        snprintf(text, sizeof(text), "%d|0", code);
        return reply_text(text, out_data, out_len);
    }
    sep = strchr(args, '|');
    if (sep == NULL) {
        snprintf(text, sizeof(text), "%d|0", code);
        return reply_text(text, out_data, out_len);
    }
    *sep = '\0';
    if (g_config != NULL && g_config->subscribe != NULL) {
        code = g_config->subscribe(g_config->context, args[0] == '\0' ? NULL : args,
                                   sep[1] == '\0' ? NULL : sep + 1, NULL, record_change,
                                   &token);
    }
    snprintf(text, sizeof(text), "%d|%llu", code, (unsigned long long)token);
    return reply_text(text, out_data, out_len);
}

static int cmd_unsubscribe(const uint8_t *payload, size_t payload_len, uint8_t **out_data,
                           size_t *out_len) {
    char args[ARGS_CAP];
    char text[32];
    uint64_t token = 0;
    int code = -11;
    if (copy_payload(payload, payload_len, args, sizeof(args)) == 0) {
        token = strtoull(args, NULL, 10);
        if (g_config != NULL && g_config->unsubscribe != NULL) {
            code = g_config->unsubscribe(g_config->context, token);
        }
    }
    snprintf(text, sizeof(text), "%d", code);
    return reply_text(text, out_data, out_len);
}

#if FIXTURE_ON_EVENT
/* Records host downlink deliveries so tests can prove config writes never use
 * the legacy broadcast path. */
static int module_on_event(uint64_t module_id, const char *kind, const uint8_t *data,
                           size_t data_len) {
    char detail[256];
    (void)module_id;
    (void)data;
    (void)data_len;
    snprintf(detail, sizeof(detail), "%s", kind == NULL ? "" : kind);
    record_marker("on_event", detail);
    return 0;
}
#endif

static int module_call(uint64_t instance, const char *method, const uint8_t *payload,
                       size_t payload_len, uint8_t **out_data, size_t *out_len) {
    (void)instance;
    if (method == NULL || out_data == NULL || out_len == NULL) {
        return -11;
    }
    *out_data = NULL;
    *out_len = 0;
    if (strcmp(method, "dump") == 0) {
        size_t total = 0;
        int i;
        char *joined;
        for (i = 0; i < g_change_count; i++) {
            total += strlen(g_changes[i]) + 1;
        }
        joined = (char *)calloc(total + 1, 1);
        if (joined == NULL) {
            return -7;
        }
        for (i = 0; i < g_change_count; i++) {
            if (i > 0) {
                strcat(joined, "\n");
            }
            strcat(joined, g_changes[i]);
        }
        *out_data = (uint8_t *)joined;
        *out_len = strlen(joined);
        return 0;
    }
    if (strcmp(method, "count") == 0) {
        char text[32];
        snprintf(text, sizeof(text), "%d", g_change_count);
        return reply_text(text, out_data, out_len);
    }
    if (strcmp(method, "clear_records") == 0) {
        g_change_count = 0;
        return reply_text("ok", out_data, out_len);
    }
    if (strcmp(method, "entry_probe") == 0) {
        char text[64];
        snprintf(text, sizeof(text), "%u|%u|%d", g_entry_abi, g_entry_size,
                 g_entry_has_config);
        return reply_text(text, out_data, out_len);
    }
    if (strcmp(method, "get") == 0) {
        return cmd_get(payload, payload_len, out_data, out_len);
    }
    if (strcmp(method, "list") == 0) {
        return cmd_list(payload, payload_len, out_data, out_len);
    }
    if (strcmp(method, "set") == 0) {
        return cmd_set(payload, payload_len, out_data, out_len);
    }
    if (strcmp(method, "subscribe") == 0) {
        return cmd_subscribe(payload, payload_len, out_data, out_len);
    }
    if (strcmp(method, "unsubscribe") == 0) {
        return cmd_unsubscribe(payload, payload_len, out_data, out_len);
    }
    if (strcmp(method, "set_invalid") == 0) {
        char text[32];
        int code = -11;
        if (g_config != NULL && g_config->set != NULL) {
            code = g_config->set(g_config->context, "max_concurrent", "{not-json");
        }
        snprintf(text, sizeof(text), "%d", code);
        return reply_text(text, out_data, out_len);
    }
    if (strcmp(method, "tokens") == 0) {
        char text[64];
        snprintf(text, sizeof(text), "own=%llu,foreign=%llu",
                 (unsigned long long)g_own_token, (unsigned long long)g_foreign_token);
        return reply_text(text, out_data, out_len);
    }
    if (strcmp(method, "slow_on") == 0) {
        g_slow = 1;
        return reply_text("slow", out_data, out_len);
    }
    if (strcmp(method, "resubscribe") == 0) {
        if (g_config != NULL && g_config->subscribe != NULL) {
            (void)g_config->subscribe(g_config->context, NULL, NULL, NULL, record_change,
                                      &g_own_token);
            (void)g_config->subscribe(g_config->context, "theme", NULL, NULL, record_change,
                                      &g_foreign_token);
        }
        return reply_text("ok", out_data, out_len);
    }
    if (strcmp(method, "read_own") == 0) {
        ByteBuf out = {NULL, 0};
        int code = -11;
        if (g_config != NULL && g_config->get != NULL) {
            code = g_config->get(g_config->context, NULL, "max_concurrent", &out);
            if (code == 0 && g_config->free_buf != NULL) {
                g_config->free_buf(out);
            }
        }
        {
            char text[32];
            snprintf(text, sizeof(text), "%d", code);
            return reply_text(text, out_data, out_len);
        }
    }
    if (strcmp(method, "unsubscribe_own_twice") == 0) {
        int first = -11;
        int second = -11;
        if (g_config != NULL && g_config->unsubscribe != NULL) {
            first = g_config->unsubscribe(g_config->context, g_own_token);
            second = g_config->unsubscribe(g_config->context, g_own_token);
        }
        {
            char text[64];
            snprintf(text, sizeof(text), "%d,%d", first, second);
            return reply_text(text, out_data, out_len);
        }
    }
    return -5;
}

static int module_destroy(uint64_t instance) {
    (void)instance;
    return 0;
}

static int module_shutdown(void) {
    record_marker("shutdown", NULL);
    return 0;
}

uint32_t GS_CAT(gstore_mod_, GS_CAT(FIXTURE_NAME, _abi))(void) {
    return FIXTURE_ABI;
}

int GS_CAT(gstore_mod_, GS_CAT(FIXTURE_NAME, _register))(const ModuleEntry *entry,
                                                         ModuleApi *api) {
    if (entry == NULL || api == NULL) {
        return -11;
    }
    g_entry_abi = entry->abi_version;
    g_entry_size = entry->entry_size;
    g_entry_has_config = 0;

#if FIXTURE_ABI >= 5
    if (entry->abi_version < 5 || entry->entry_size < sizeof(ModuleEntry)) {
        return -2;
    }
    if (entry->config == NULL) {
        return -2;
    }
    if (entry->config->abi_version < 5 || entry->config->struct_size < sizeof(ConfigApi)) {
        return -2;
    }
    g_entry_has_config = 1;
    g_config = entry->config;
#else
    if (entry->abi_version < FIXTURE_ABI) {
        return -2;
    }
    /* A v4 module must see exactly the v4 layout, never the v5 full entry. */
    if (entry->entry_size != (uint32_t)offsetof(ModuleEntry, config)) {
        return -2;
    }
    g_config = NULL;
#endif

#if FIXTURE_AUTO_SUBSCRIBE
    if (g_config != NULL && g_config->subscribe != NULL) {
        (void)g_config->subscribe(g_config->context, NULL, NULL, NULL, record_change,
                                  &g_own_token);
        (void)g_config->subscribe(g_config->context, "theme", NULL, NULL, record_change,
                                  &g_foreign_token);
    }
#endif
    record_marker("registered", GS_STR(FIXTURE_NAME));
    {
        int delay_ms = env_int("GS_REGISTER_DELAY_MS", 0);
        if (delay_ms > 0) {
            usleep((useconds_t)delay_ms * 1000);
        }
    }

    api->name = GS_STR(FIXTURE_NAME);
    api->version = 1;
    api->min_host_abi = FIXTURE_MIN_HOST_ABI;
    api->init = NULL;
    api->create = module_create;
    api->call = module_call;
    api->cancel = NULL;
    api->destroy = module_destroy;
    api->shutdown = module_shutdown;
    api->alloc = NULL;
    api->free = module_free;
#if FIXTURE_ON_EVENT
    api->on_event = module_on_event;
#else
    api->on_event = NULL;
#endif
    return 0;
}

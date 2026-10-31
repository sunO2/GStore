/*
 * ABI v4 module fixture (source only; the .so is compiled at test time).
 *
 * This module is deliberately shaped like a module built before the v5
 * `config` slot existed:
 *   - `gstore_mod_v4demo_abi()` returns 4;
 *   - `gstore_mod_v4demo_register()` only accepts an ABI 4 entry whose
 *     `entry_size` is exactly the v4 size (through `platform`, 64 bytes on
 *     x86_64). A v5 host that wrongly reported the full 72-byte size is
 *     rejected with ABI_ERR_ABI_MISMATCH (-2).
 *
 * Compile with `-DFIXTURE_MIN_HOST_ABI=5` to model a config-consuming module
 * that a v4 host must reject at probe time.
 */

#include <stddef.h>
#include <stdint.h>

typedef struct {
  const uint8_t *ptr;
  size_t len;
} ByteBuf;

typedef struct GStoreEntryV4 {
  uint32_t abi_version;
  uint32_t entry_size;
  void (*log)(int level, const char *msg);
  void *(*alloc)(size_t size);
  void (*free)(void *ptr);
  void (*emit_event)(uint64_t module_id, uint64_t instance_id,
                     const uint8_t *data, size_t len);
  void *context;
  int (*protect_fd)(int fd);
  const void *platform;
} GStoreEntryV4;

typedef struct GStoreApiV4 {
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
  int (*on_event)(uint64_t module_id, const char *kind, const uint8_t *data,
                  size_t data_len);
} GStoreApiV4;

#ifndef FIXTURE_MIN_HOST_ABI
#define FIXTURE_MIN_HOST_ABI 3
#endif

#define ABI_OK 0
#define ABI_ERR_NULL (-1)
#define ABI_ERR_ABI_MISMATCH (-2)

static int fixture_init(void) { return ABI_OK; }

static int fixture_create(const uint8_t *config, size_t config_len,
                          uint64_t *out_instance) {
  (void)config;
  (void)config_len;
  if (out_instance == NULL) {
    return ABI_ERR_NULL;
  }
  *out_instance = 1;
  return ABI_OK;
}

static int fixture_call(uint64_t instance, const char *method,
                        const uint8_t *payload, size_t payload_len,
                        uint8_t **out_data, size_t *out_len) {
  (void)instance;
  (void)method;
  (void)payload;
  (void)payload_len;
  (void)out_data;
  (void)out_len;
  return ABI_OK;
}

static int fixture_cancel(uint64_t instance, const char *request_id) {
  (void)instance;
  (void)request_id;
  return ABI_OK;
}

static int fixture_destroy(uint64_t instance) {
  (void)instance;
  return ABI_OK;
}

static int fixture_shutdown(void) { return ABI_OK; }

static void *fixture_alloc(size_t size) {
  (void)size;
  return NULL;
}

static void fixture_free(void *ptr) { (void)ptr; }

static int fixture_on_event(uint64_t module_id, const char *kind,
                            const uint8_t *data, size_t data_len) {
  (void)module_id;
  (void)kind;
  (void)data;
  (void)data_len;
  return ABI_OK;
}

uint32_t gstore_mod_v4demo_abi(void) { return 4; }

int gstore_mod_v4demo_register(const GStoreEntryV4 *entry, GStoreApiV4 *out) {
  if (entry == NULL || out == NULL) {
    return ABI_ERR_NULL;
  }
  if (entry->abi_version != 4) {
    return ABI_ERR_ABI_MISMATCH;
  }
  /* A v4 host must report the v4 entry size (through `platform`), never the
   * v5 full size that includes the `config` slot. */
  if (entry->entry_size !=
      (uint32_t)(offsetof(GStoreEntryV4, platform) + sizeof(void *))) {
    return ABI_ERR_ABI_MISMATCH;
  }

  out->name = "v4demo";
  out->version = 1;
  out->min_host_abi = FIXTURE_MIN_HOST_ABI;
  out->init = fixture_init;
  out->create = fixture_create;
  out->call = fixture_call;
  out->cancel = fixture_cancel;
  out->destroy = fixture_destroy;
  out->shutdown = fixture_shutdown;
  out->alloc = fixture_alloc;
  out->free = fixture_free;
  out->on_event = fixture_on_event;
  return ABI_OK;
}

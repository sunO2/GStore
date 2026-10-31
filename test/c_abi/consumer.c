#include "gstore_platform.h"

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 编译期布局断言：C 侧必须与 Rust #[repr(C)] 的实测布局一致。 */
_Static_assert(sizeof(ByteBuf) == 2 * sizeof(void *),
               "ByteBuf 必须是 {pointer, size_t} 两个机器字");
_Static_assert(offsetof(GStorePlatformApiV1, free_buf) ==
                   sizeof(GStorePlatformApiV1) - sizeof(void *),
               "free_buf 必须是 GStorePlatformApiV1 的最后一个字段");
_Static_assert(offsetof(GStoreModuleEntry, platform) ==
                   offsetof(GStoreModuleEntry, protect_fd) + sizeof(void *),
               "platform 必须紧跟在 protect_fd 之后（v4 末尾追加）");
_Static_assert(offsetof(GStoreModuleEntry, config) ==
                   offsetof(GStoreModuleEntry, platform) + sizeof(void *),
               "config 必须紧跟在 platform 之后（v5 末尾追加）");
_Static_assert(sizeof(GStoreModuleEntry) ==
                   offsetof(GStoreModuleEntry, config) + sizeof(void *),
               "GStoreModuleEntry 必须在 config 槽后结束、无尾部填充");
_Static_assert(offsetof(GStoreConfigApiV1, free_buf) ==
                   sizeof(GStoreConfigApiV1) - sizeof(void *),
               "free_buf 必须是 GStoreConfigApiV1 的最后一个字段");
_Static_assert(offsetof(GStoreConfigApiV1, get) < offsetof(GStoreConfigApiV1, set),
               "配置 vtable 槽位顺序：get < set");
_Static_assert(offsetof(GStoreConfigApiV1, subscribe) <
                   offsetof(GStoreConfigApiV1, unsubscribe),
               "配置 vtable 槽位顺序：subscribe < unsubscribe");
_Static_assert(CONFIG_CAP_ALL == 0xF, "CONFIG_CAP_ALL 必须覆盖低 4 位");

#ifdef SPIKE_INJECT_WRONG_OFFSET
/*
 * 故意写错的断言：check_c_abi.sh --inject-wrong-offset 依赖此处让编译失败，
 * 证明上述布局断言确实在编译期生效（而不是被优化/静默忽略）。
 */
_Static_assert(offsetof(GStoreModuleEntry, platform) ==
                   offsetof(GStoreModuleEntry, protect_fd) + 2 * sizeof(void *),
               "deliberate failure: wrong platform offset must be rejected");
#endif

static int g_free_calls;
static size_t g_freed_len;

static void test_free_buf(ByteBuf buf) {
  g_free_calls += 1;
  g_freed_len = buf.len;
  free(buf.ptr);
}

int main(void) {
  GStorePlatformApiV1 api;
  memset(&api, 0, sizeof(api));
  api.abi_version = GSTORE_MODULE_ABI_VERSION;
  api.struct_size = (uint32_t)sizeof(api);
  api.capabilities = PLATFORM_CAP_INSTALL;
  api.free_buf = test_free_buf;

  GStoreConfigApiV1 config;
  memset(&config, 0, sizeof(config));
  config.abi_version = GSTORE_MODULE_ABI_VERSION;
  config.struct_size = (uint32_t)sizeof(config);
  config.capabilities = CONFIG_CAP_ALL;
  config.free_buf = test_free_buf;

  const char payload[] = "gstore-c-abi";
  const size_t len = sizeof(payload);
  uint8_t *raw = malloc(len);
  assert(raw != NULL);
  memcpy(raw, payload, len);
  ByteBuf buf = {raw, len};

  assert(api.free_buf != NULL);
  api.free_buf(buf);

  assert(g_free_calls == 1);
  assert(g_freed_len == len);

  uint8_t *raw2 = malloc(len);
  assert(raw2 != NULL);
  memcpy(raw2, payload, len);
  ByteBuf buf2 = {raw2, len};
  assert(config.free_buf != NULL);
  config.free_buf(buf2);
  assert(g_free_calls == 2);
  assert(g_freed_len == len);

  printf("sizeof(ByteBuf) = %zu\n", sizeof(ByteBuf));
  printf("sizeof(GStorePlatformError) = %zu\n", sizeof(GStorePlatformError));
  printf("sizeof(GStorePlatformApiV1) = %zu\n", sizeof(GStorePlatformApiV1));
  printf("sizeof(GStoreModuleEntry) = %zu\n", sizeof(GStoreModuleEntry));
  printf("offsetof(GStorePlatformApiV1, free_buf) = %zu\n",
         offsetof(GStorePlatformApiV1, free_buf));
  printf("offsetof(GStoreModuleEntry, protect_fd) = %zu\n",
         offsetof(GStoreModuleEntry, protect_fd));
  printf("offsetof(GStoreModuleEntry, platform) = %zu\n",
         offsetof(GStoreModuleEntry, platform));
  printf("offsetof(GStoreModuleEntry, config) = %zu\n",
         offsetof(GStoreModuleEntry, config));
  printf("sizeof(GStoreConfigApiV1) = %zu\n", sizeof(GStoreConfigApiV1));
  printf("offsetof(GStoreConfigApiV1, get) = %zu\n",
         offsetof(GStoreConfigApiV1, get));
  printf("offsetof(GStoreConfigApiV1, subscribe) = %zu\n",
         offsetof(GStoreConfigApiV1, subscribe));
  printf("offsetof(GStoreConfigApiV1, free_buf) = %zu\n",
         offsetof(GStoreConfigApiV1, free_buf));
  printf("GSTORE_MODULE_ABI_VERSION = %u, MIN_HOST_ABI = %u\n",
         (unsigned)GSTORE_MODULE_ABI_VERSION, (unsigned)MIN_HOST_ABI);
  printf("abi_version = %u, struct_size = %u, capabilities = %llu\n",
         (unsigned)api.abi_version, (unsigned)api.struct_size,
         (unsigned long long)api.capabilities);
  printf("free_buf calls = %d, preserved len = %zu\n", g_free_calls,
         g_freed_len);
  printf("consumer_ok\n");
  return 0;
}

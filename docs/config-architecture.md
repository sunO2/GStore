# Rust 配置核心架构、迁移与备份契约

> 状态：**已实施**（对应 `rust-config-core` 计划 Todo 1–32）。
> 权威代码：`rust/gstore_core/src/config/{model,schema,store,bus,secrets,import}.rs`、
> `rust/gstore_contract/src/abi.rs`、`rust/gstore_core/migrations/V6__config.sql`、
> `lib/core/config/{config_service,config_store,config_registry,rust/config_api}.dart`、
> `lib/core/config/migration/*`、`lib/core/service/backup_service.dart`。
>
> **本文档的机器门禁是 `scripts/tests/config_docs_assert.sh`。**
> `scripts/tests/docs_assert.sh` **不覆盖**本文档，它只断言既有开发文档（doc 12/16 等）。

本文只描述已经落地的行为；未实现的能力不在此承诺。

## 1. 权威边界与模块/键表

Rust core 是用户配置的**唯一写入者**。Dart `ConfigService` 是 Rust `ConfigApi` 的薄门面：
元数据来自 Rust 注册表，读写委托 Rust，敏感值默认脱敏。Dart 本地 `ConfigStore` 仅保留
兼容/测试 seam，不再拥有持久化权威。

配置键的规范形式是 `module.key`，解析时**只在第一个点**拆分，因此 key 本身可以带点
（例如 `download.multi_segment.enabled`）。模块名只允许 `[a-z0-9_-]`，key 允许
`[a-z0-9_.-]` 但拒绝 `..`、首尾点与路径分隔符。

下表由已提交的注册表 `rust/gstore_core/src/config/schema.rs` 派生：**12 个模块、53 个键**。
`module.<name>.enabled` 是每个内置模块的开关。`Sensitive=yes` 的条目按秘密处理；
`Visibility` 为 `Owner` / `PublicRead` / `Secret`。

<!-- BEGIN config-key-table -->
### `agent` (3 keys)
| Key | Type | Visibility | Sensitive |
| --- | --- | --- | --- |
| `agent.model_catalog` | Json | Owner | no |
| `agent.models` | Json | Secret | yes |
| `agent.selected_model_id` | String | Owner | no |

### `catalog` (1 keys)
| Key | Type | Visibility | Sensitive |
| --- | --- | --- | --- |
| `catalog.source_url` | String | PublicRead | no |

### `discovery` (1 keys)
| Key | Type | Visibility | Sensitive |
| --- | --- | --- | --- |
| `discovery.selected_channels` | StringList | Owner | no |

### `download` (6 keys)
| Key | Type | Visibility | Sensitive |
| --- | --- | --- | --- |
| `download.default_connections` | Int | Owner | no |
| `download.max_concurrent` | Int | Owner | no |
| `download.max_retries` | Int | Owner | no |
| `download.multi_segment.enabled` | Bool | Owner | no |
| `download.speed_limit_bps` | Int | Owner | no |
| `download.wifi_only` | Bool | Owner | no |

### `fdroid` (2 keys)
| Key | Type | Visibility | Sensitive |
| --- | --- | --- | --- |
| `fdroid.last_source_id` | String | Owner | no |
| `fdroid.sources` | Json | Owner | no |

### `module` (11 keys)
| Key | Type | Visibility | Sensitive |
| --- | --- | --- | --- |
| `module.agent_tools.enabled` | Bool | Owner | no |
| `module.aggregate.enabled` | Bool | Owner | no |
| `module.backup.enabled` | Bool | Owner | no |
| `module.badge.enabled` | Bool | Owner | no |
| `module.channel.enabled` | Bool | Owner | no |
| `module.download.enabled` | Bool | Owner | no |
| `module.fdroid.enabled` | Bool | Owner | no |
| `module.install.enabled` | Bool | Owner | no |
| `module.theme.enabled` | Bool | Owner | no |
| `module.update.enabled` | Bool | Owner | no |
| `module.webdav.enabled` | Bool | Owner | no |

### `network` (1 keys)
| Key | Type | Visibility | Sensitive |
| --- | --- | --- | --- |
| `network.proxy_url` | String | PublicRead | no |

### `perf` (3 keys)
| Key | Type | Visibility | Sensitive |
| --- | --- | --- | --- |
| `perf.history.enabled` | Bool | Owner | no |
| `perf.profiles` | Json | Owner | no |
| `perf.profiles.enabled` | Bool | Owner | no |

### `proxy` (11 keys)
| Key | Type | Visibility | Sensitive |
| --- | --- | --- | --- |
| `proxy.active_node_label` | Json | Owner | no |
| `proxy.active_profile_id` | String | Owner | no |
| `proxy.always_on_intent` | Bool | Owner | no |
| `proxy.engine_mtu` | Int | Owner | no |
| `proxy.engine_stack` | String | Owner | no |
| `proxy.log_level` | String | Owner | no |
| `proxy.routing_mode` | String | Owner | no |
| `proxy.run_mode` | String | Owner | no |
| `proxy.sheet_view_mode` | String | Owner | no |
| `proxy.split_apps` | StringList | Owner | no |
| `proxy.split_mode` | String | Owner | no |

### `theme` (2 keys)
| Key | Type | Visibility | Sensitive |
| --- | --- | --- | --- |
| `theme.config` | Json | Owner | no |
| `theme.mode` | Int | PublicRead | no |

### `update` (7 keys)
| Key | Type | Visibility | Sensitive |
| --- | --- | --- | --- |
| `update.auto_update_policy` | String | Owner | no |
| `update.channel` | String | Owner | no |
| `update.check_interval_hours` | Int | Owner | no |
| `update.ignore_prerelease` | Bool | Owner | no |
| `update.last_check_time` | String | Owner | no |
| `update.last_updated_version` | String | Owner | no |
| `update.silent_update` | Bool | Owner | no |

### `webdav` (5 keys)
| Key | Type | Visibility | Sensitive |
| --- | --- | --- | --- |
| `webdav.backup_path` | String | Owner | yes |
| `webdav.enable_https` | Bool | Owner | yes |
| `webdav.password` | String | Secret | yes |
| `webdav.url` | String | Owner | yes |
| `webdav.username` | String | Owner | yes |
<!-- END config-key-table -->

**可见性规则**（`ConfigVisibility`）：

| 可见性 | 本模块 | 其他模块 | 宿主 / 可信 Dart | 值脱敏 |
| --- | --- | --- | --- | --- |
| `Owner`（默认） | 读/写/订阅 | 拒绝 | 读/写 | 否（但 `sensitive` 仍脱敏） |
| `PublicRead` | 读/写/订阅 | 可读/可订阅，**不可写** | 读/写 | 否 |
| `Secret` | 读/写/订阅 | 拒绝 | 读/写 | 对外 `***` |

`sensitive: true` 单独就足以把条目当作秘密（WebDAV 的 URL/用户名/路径/HTTPS 开关是
`Owner + sensitive`）：跨模块不可见，非可信面一律脱敏，但 owner/宿主/可信 Dart 仍可读取原始值。

## 2. 存储 schema（`V6__config.sql`）

`config_entry` 是当前状态；`config_change_log` 是仅追加审计；`config_meta` 保存跨条目的
标记。**没有 `config_module` 表**：模块元数据在代码注册表里，模块卸载保留行。

### `config_entry`

| 列 | 类型 | 含义 |
| --- | --- | --- |
| `module` | TEXT NOT NULL | 所属模块（主键之一） |
| `key` | TEXT NOT NULL | 模块内 key（主键之一） |
| `value_json` | TEXT NULL | 非敏感值的 JSON；**敏感条目恒为 NULL** |
| `secret_ref` | TEXT NULL | 版本化秘密文件的 key；仅敏感条目使用 |
| `secret_hash` | TEXT NULL | 值的 SHA-256，用于发现快照恢复后的陈旧秘密 |
| `value_type` | TEXT NULL | 写入时的 JSON 类型标记 |
| `revision` | INTEGER NOT NULL | 条目上次提交的修订号，默认 0 |
| `updated_at` | INTEGER NOT NULL | Unix 时间戳 |
| `updated_by` | TEXT NULL | 来源/调用者 |

主键 `(module, key)`，另有 `ix_config_entry_module(module)`。

### `config_change_log`

| 列 | 类型 | 含义 |
| --- | --- | --- |
| `seq` | INTEGER PRIMARY KEY AUTOINCREMENT | 审计序号 |
| `module` / `key` | TEXT NOT NULL | 变更键 |
| `old_json` / `new_json` | TEXT NULL | 脱敏后的旧/新值；敏感条目为 NULL 或 `"***"` |
| `source` | TEXT | `internal` / `user` / `agent` / `module` / `migration` / `restore` |
| `actor` | TEXT NULL | 调用者标识 |
| `at` | INTEGER | 时间戳 |

索引 `ix_config_change_log_module_key_seq(module, key, seq)`。

### `config_meta`

| 列 | 类型 | 含义 |
| --- | --- | --- |
| `k` | TEXT NOT NULL PRIMARY KEY | 标记名 |
| `v` | TEXT NULL | JSON/文本载荷 |

关键标记：`revision`（全局单调修订号）与 `config.migrated.v1`（迁移完成标记，见 §6）。

**写入语义**：每次接受的写入在**一个 `BEGIN IMMEDIATE` 事务**内完成
upsert `config_entry` → 追加脱敏 `config_change_log` → 递增 `config_meta('revision')`，
提交成功后才更新内存缓存。`remove` 删除行（读取回落到注册表默认值）；`reset` 把默认值
当作普通写入持久化；`import` 先全量校验，再在单个事务内应用有效子集。

## 3. 变更事件与过滤投递

提交成功后，store 把 `ConfigChange` 交给 `ConfigBus::publish`。总线先按注册表校验变更，
再构造**唯一一份脱敏后的 wire 载荷**：

```json
{
  "module": "download",
  "key": "max_concurrent",
  "value": 5,
  "oldValue": 3,
  "revision": 42,
  "source": "user"
}
```

- 字段名严格为 `module` / `key` / `value` / `oldValue` / `revision` / `source`；
  `value == null` 表示清除，`oldValue == null` 表示此前未设置。
- `source` 取值：`internal`、`user`、`agent`、`module`、`migration`、`restore`。
- 秘密条目在载荷中永远是 `"***"`（已设置）或 `null`（未设置），明文不会进入回调。

**过滤投递**：

- 过滤器是 `(module, key: Option<String>)`。`key = None` 表示“该模块内的任意 key”，
  **不是**“任意模块的任意 key”。
- 注册时不因跨模块而拒绝；每次投递都按**该条变更所属条目**的可见性重新裁决。
  只有 `PublicRead` 条目能跨模块送达；`Owner` / `Secret` 永远不跨模块。
- 因此 `key = None` 不会变成“后续新增 `Owner` key 的通行证”。
- 同一变更可同时命中“整模块”和“精确 key”两个订阅（AMQP 风格，不合并去重）。
- 回调在总线锁之外执行，允许回调内再次 `publish`/`unsubscribe`；panic 的回调被移除，
  不影响其他订阅者。

## 4. ABI v5 契约

`rust/gstore_contract/src/abi.rs` 定义 `GSTORE_MODULE_ABI_VERSION = 5`。配置 vtable 是 ABI v5
在 `GStoreModuleEntry` 末尾追加的 `config` 槽：

- `GStoreModuleEntry::CONFIG_OFFSET == 64`，`config` 是结构体末尾的裸指针槽；
  ABI 3 用 `PLATFORM_OFFSET`，ABI 4 用 `CONFIG_OFFSET`（64B），ABI 5 才是完整 entry。
- 模块必须先用 `GStoreModuleEntry::config_if_present()` 守卫，再解引用
  `GStoreConfigApiV1`；小 entry 越界读取是被禁止的。
- **消费配置 vtable 的模块必须设置 `min_host_abi = 5`**。v4 宿主在 probe 阶段直接拒绝，
  不存在“v5 模块在 v4 宿主上降级”的路径。

`GStoreConfigApiV1`（只允许在末尾追加字段）：

| 字段 | 含义 |
| --- | --- |
| `abi_version` / `struct_size` / `capabilities` | 版本、大小、能力位；模块先探测再调用，fail-closed |
| `context` | 指向 `GStoreConfigContextV1`，宿主按模块绑定 |
| `get` | 读配置；跨模块仅 `PublicRead` |
| `set` | 写本模块配置；跨模块写入一律拒绝 |
| `list` | 列条目；外模块仅 `PublicRead` |
| `subscribe` | 订阅；显式外模块 key 非 `PublicRead` 立即拒绝 |
| `unsubscribe` | 只接受本模块创建且仍有效的令牌 |
| `free_buf` | 释放 vtable 分配的 `ByteBuf`（必须在末尾） |

能力位：`CONFIG_CAP_GET`、`CONFIG_CAP_SET`、`CONFIG_CAP_LIST`、`CONFIG_CAP_SUBSCRIBE`
（`CONFIG_CAP_ALL` 为低 4 位全置位）。`has_capability` 在 `struct_size` 过小或位未置位时
返回 false。

**上下文身份**：`GStoreConfigContextV1` 携带宿主分配的 `module_id`、`module_name` 与私有
`host` 指针。模块不能靠参数自报模块名绕过可见性；`module_name` 是宿主绑定的权威身份。

**错误码**：`ABI_ERR_CONFIG_FORBIDDEN`（可见性/跨模块写）、`ABI_ERR_CONFIG_NOT_FOUND`、
`ABI_ERR_CONFIG_INVALID`、`ABI_ERR_CONFIG_BAD_TOKEN`。所有权规则：所有 `ByteBuf` 由宿主
分配，模块只读拷贝后交给 `free_buf`；失败时 `out_json` 保持 `{null, 0}`。

## 5. 秘密处理契约

- **落盘**：敏感条目 `value_json` 恒为 NULL；明文写入 `FileSecretStore`（Unix 0600），
  `config_entry.secret_ref` 保存版本化 key，`config_entry.secret_hash` 保存 SHA-256。
  常规 key 形态是 `config.<module>.<key>.<revision>`；base key 超过 128 字节时使用
  `config.h<sha256(module.key)>.<revision>`。明文秘密永不写入 `config_entry` 或
  `config_change_log`。
- **写序**：先算内容哈希并写新版本文件，再提交行，随后切换缓存，最后删除旧文件。
  提交失败只在 `new_ref != old_ref` 时删除新文件；相同内容是幂等重写，不触碰旧文件。
  `get` 在读秘密文件期间持有缓存读锁（失败时回读 DB），因此轮换期间不会出现 `None`。
- **GC**：`reload_from_db` 只清理 `config.*` 命名空间、带数字 revision 后缀且未被引用的
  版本键；`channel.*`、`core_config.*` 等命名空间永不触碰；未提交的在途键按 revision
  规则保留。
- **脱敏面**：`list`、`snapshot`/`snapshots`、bus/FRB 载荷、`config_change_log`、
  Agent 工具输出与 Dart 镜像只看到 `***`；Dart 镜像绝不缓存秘密明文。
- **可信原始读**：`ConfigCaller::Host`、`ConfigCaller::Dart` 与**所属模块**可通过
  `ConfigApi.get(masked: false)`（Dart `getRaw`）读取原始值；这是显式可信路径，用于
  `AgentModelStore` 与 WebDAV 客户端。
- **导出**：只有备份 `export` 是允许把原始秘密写入产物的面（见 §7）。

## 6. 升级迁移与回滚（事件流 A）

### 事件流 A：升级迁移（legacy → Rust）

`lib/core/config/migration/config_migration_tool.dart` 是独立迁移器，不经过旧的
`ConfigStore`/`ConfigService` 持久化路径。生产调用顺序是
`CoreBootstrap.start` → `CoreApi.init` → 迁移 → `ConfigInitializer.initialize` → toggles。

流程：

1. 读取真实 legacy 存储键（SharedPreferences `config_*` + secure `webdav_*` /
   `secure_config_webdav_*`）。
2. 通过唯一的 `legacy_config_mapping.dart` 表把 storage key 映射为 `module.key`
   （含全部 11 个 `config_proxy_*` 与 11 个 `config_module.<name>.enabled`）。
3. 调用 `ConfigApi.import(entries, source = "migration")` 批量导入。
4. 调用 `ConfigApi.verify` 回读校验；只有 **0 mismatch** 才继续。
5. 通过 `ConfigApi.meta_set` 写入标记 `config.migrated.v1`（JSON 报告，只含
   key/status/统计，不含值）。
6. 再次启动读到该标记即返回 `alreadyDone`，不再触碰任何键。

失败/回滚契约：

- **旧键永不删除**（成功或失败都不删），因此回滚到旧版应用始终可用。
- 任一 key 失败或 verify 不匹配时**不写标记**，下次启动重试；失败被逐 key 隔离，
  其余键照常迁移。
- 标记内容经结构化秘密扫描：只允许已知字段词表，出现用户值/未知字段即判 `secret_leak`，
  不写标记。
- 可选迁移备份使用 `config_migration_backup_` 前缀；**备份中省略 WebDAV 密码、脱敏
  Agent API Key**，写后对备份产物与 `config_meta` 标记做秘密扫描。若备份脱敏了秘密，
  旧 secret 键仍按“旧键保留”策略保留，供回滚。

## 7. 备份格式 v2（事件流 B）

### 事件流 B：备份导出 / 恢复

**导出**（`lib/core/service/backup_service.dart`）所有路径都汇入共享的 `_buildAppConfigMap()`：

1. `ConfigService.exportRaw()` → `ConfigApi.export()` 取原始值（备份是唯一允许明文的导出面）。
2. 生成 grouped `configs`：`module.key → value`（如 `download.max_concurrent`）。
3. 追加 legacy 别名（`theme_config`、`download_config`、`update_config`、`agent_models`、
   `fdroid_sources`、`webdav_*` 等），供旧版导入器读取。
4. 追加 **top-level mirrors** `proxy_url` / `webdav_config`（旧应用从
   `apps.json.appConfig` 读取）。
5. 写出 `config_format: 2`；`ConfigBackupData.version` 保持 **1**，绝不因配置格式而提升。
6. `includeAppConfig` 是总门控：为 false 时**整体省略** `app_config.json` /
   `apps.json.appConfig` 与 extras 中的 `agent_models`、`agent_selected_id`、`js_envs`、
   `fdroid_sources`；**绝不用 `***` 掩码代替省略**（掩码会被旧导入器写回）。

分组/别名/top-level 镜像的关系：`configs` 内同时存在 grouped 与 legacy 别名；顶层镜像
优先级最低。`app_config.json` 与 `apps.json.appConfig` 使用同一份共享载荷。

**恢复**（`lib/core/config/migration/config_restore_adapter.dart`）同时读取
`apps.json.appConfig` 与独立的 `app_config.json`，按形状而非只按 `config_format` 识别：

- 已知 legacy storage key / bare alias → 通过唯一映射表还原为 `module.key`；
- `module.key` → 直接作为 grouped 键导入；
- 同一 wire key 同时出现 grouped 与 legacy 别名时，**grouped 胜出**；
- top-level `proxy_url` / `webdav_config` 优先级最低，会被 grouped/legacy 覆盖；
- 坏 key 逐条报告（稳定 code），不中断其余键；
- 恢复走 Rust `ConfigApi.import(entries, source = "restore")`（`ConfigSource::Restore`
  的规范 code；`ConfigSource::from_str` 只接受 `internal|user|agent|module|migration|restore`），
  报告不含值。

## 8. 断言与证据

`bash scripts/tests/config_docs_assert.sh` 会：

- 从 `rust/gstore_core/src/config/schema.rs` 解析出全部注册键（当前 **53** 个），
  逐一要求在本文 `<!-- BEGIN config-key-table -->` 表格中出现；
- 要求两个事件流标题存在：
  `### 事件流 A：升级迁移（legacy → Rust）` 与 `### 事件流 B：备份导出 / 恢复`，
  并检查各自的关键 token；
- 要求本文包含存储 schema、事件载荷、ABI v5、迁移/回滚、备份 v2、秘密处理等章节；
- 缺失任一 key 行或任一事件流时**非零退出**，并打印匹配数量与被删项。

因此本文档与注册表漂移会被 CI 直接拦下；`docs_assert.sh` 与新文档无关，也不得声称覆盖它。

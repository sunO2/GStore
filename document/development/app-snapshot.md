# 应用快照与快照对比

> 复刻 LibChecker 的快照能力，并在此基础上做**字段级**对比。
> 入口：**应用分析页导航头**（AppBar 历史图标）。

## 1. 定位与取舍

LibChecker 的做法是「几个标量 + 每类一整段 JSON」，对比时对整段字符串做集合差，
因此只能说「这一类的 JSON 变了」，无法回答「变了什么」。

我们手里本来就是**结构化对象**，所以做成：

- 采集侧：**一次遍历**产出结构化载荷
- 对比侧：键控集合 + **字段级**变化（`字段: from → to`）

### 采集为什么放在 Rust（而不是 Dart 逐能力调用）

评估结论：**只把「采集」收敛成 Rust 单入口，diff / 存储 / 展示留在 Dart。**
理由与实证：

1. **重复解析严重**。分散调用时：manifest AXML 解析 **3 次**（`parse_components` /
   `parse_manifest` / `scan_features` 内部各一次）、DEX 类表扫描 **≥2 次**
   （规则匹配 + 特征识别）、zip 中央目录解析 **5~6 次**、ELF 对**全部 ABI** 的
   `.so` 各解压一遍。
2. **快照必须是一致的时间切片**。分散调用之间存在时间窗口，APK 更新中途采集会得到
   **跨版本混合**的快照。这条比性能更重要。
3. **FFI 往返 + 双侧 JSON 编解码**：~10 次 → 1 次。

不搬 diff / 存储 / 展示的原因：diff 是纯计算、数据量小、**改动最频繁**且强耦合展示文案
（中文分节名、字节/时间格式化）；存储已用 sqflite，Rust 再引 SQLite 是净负担；
整体搬迁还会**削弱逐节降级**（单节 bug 会让整个快照失败）。

## 2. Rust 侧：`scan_apk_report`

新增聚合入口，**一次打开 APK** 产出全部节：

| 能力 | 说明 |
|---|---|
| `_from` 变体 | `structure` / `manifest` / `dex_stats` / `elf` / `dex_scan` 各增加「复用已打开的 `ZipArchive<File>`」变体；原 path 包装保留 |
| `features` 纯函数化 | `detect_features(manifest, entry_names, dex_classes, agp_version)`；公开 `collect_entry_names` / `find_agp_version` |
| `rules` 纯函数化 | `match_libraries_with(rules_json, so_names, manifest, dex_classes)`；公开 `dex_patterns_for_rules` |
| DEX 模式并集 | 特征与规则的 DEX pattern **求并集只扫一次**，两侧共用结果 |
| 逐节容错 | 某节失败 → 该节为空 + 原因进 `errors[]`，其余节照常产出 |

FFI payload：`apk_path NUL rules_json [NUL abis_csv]`。

## 3. 数据模型

`SnapshotPayload`（`payloadVersion = 1`）共 10 节：

1. **应用信息**：包名 / 名称 / 版本名 / versionCode / APK 大小 / uid / 系统应用 /
   可调试 / 安装器 / 数据目录 / 主 Activity / 首次安装 / 最近更新 / minSdk /
   targetSdk / compileSdk / sharedUserId / ABI
2. **签名**：签名形态（single/multiple/rotation）/ 方案（V1–V4）/ 证书（主题 / 算法 /
   SHA-256 / SHA-1 / **角色**：当前 / 历史 / 并列签名者）
3. **权限**：名称 / `maxSdkVersion` / 是否已授权 / `neverForLocation`
4. **组件**：类型 / 类名 / exported / enabled / 进程 / actions / **深链 URI**
5. **原生库**：ABI + 名称 + 大小；命中规则；**ELF 元数据**（页对齐 / 16KB /
   zip 对齐 / e_type / DT_NEEDED / JNI 入口 / 是否剥离）
6. **DEX**：文件 / 大小 / **类数量** / CRC32；命中规则
7. **特征与构建版本**：Kotlin / Compose / KMP / Xposed / Play 签名 / PWA /
   实时更新通知；AGP / Kotlin / Gradle / Java / Compose 版本
8. **meta-data**
9. **命中的第三方库**：native / dex / **组件库** / **静态库(6)** / **action(9)**
10. **统计摘要**：各类计数 + APK 大小 + 特征标签（冗余存储，列表页无需解析大 JSON）

## 4. 对比引擎

分三类差异：**新增 / 移除 / 变化**，其中「变化」给出**字段级** `from → to`。

- 标量节（应用信息 / 签名方案 / 构建版本）：逐字段比较
- 集合节（ABI / 深链 / 命中的库）：集合差
- 键控节（原生库 / ELF / DEX / 证书 / 权限 / 组件 / meta-data）：新增 + 移除 +
  **字段级变化**（`.so` 大小、组件 exported、权限 maxSdkVersion、类数量、指纹…）

### 可比性守卫

`payloadVersion` 不同（采集能力变化）时：

- 顶部横幅提示「差异可能来自采集能力变化而非应用本身」
- 新增/移除条目标记为 **uncertain**（UI 显示 `?`）
- 缺整节的做降级处理，不误报为「全部新增」

## 5. 存储

`AppSnapshotStore`：独立 sqflite 库 `app_snapshots.db`，表 `app_snapshot`，
索引 `(package_name, created_at DESC)`；`summary` 单独一列（列表页免解析大 JSON）。
照 `CacheManager` 的裸 sqflite 模式（带版本与迁移位、单例、路径可注入测试）。

## 6. 界面

| 页面 | 内容 |
|---|---|
| 快照列表 | 时间/版本/统计摘要/特征标签；勾选两份→对比；长按菜单→详情/删除；右上角新建 |
| 快照详情 | 分节展示全量数据；有上一份时导航头提供「与上一快照对比」 |
| 快照对比 | 顶部计数（新增/移除/变化）+ 分节差异（`+`/`-`/`~`/`?`），单条变化合并成一行 |

## 7. 测试

- `test/snapshot_models_test.dart`：载荷 JSON 往返、标量与集合差异、字段级变化、
  相同快照无差异、可比性守卫（版本不一致 / uncertain）—— 10 例
- `test/snapshot_store_test.dart`：插入读回（含大载荷往返）、按应用隔离与时间倒序、
  删除与清空、备注与版本 —— 4 例
- `test/app_snapshot_pages_test.dart`：列表入口与空态、对比页渲染、无差异提示、
  详情页分节、详情页对比入口 —— 5 例

## 8. 环境备注（本机测试）

本机只有 `libsqlite3.so.0`、缺开发软链 `libsqlite3.so`，会让**所有 sqflite 测试**
失败（不止快照，仓库里既有的 70+ 个 DB 测试同样如此）。两种解法：

```bash
# 方式一（不改系统）
mkdir -p /tmp/cc-sqlite && ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 /tmp/cc-sqlite/libsqlite3.so
LD_LIBRARY_PATH=/tmp/cc-sqlite flutter test
# 方式二
sudo apt install libsqlite3-dev
```

注：测试里用 `open.overrideFor` 指定 `libsqlite3.so.0` 的写法在当前
`sqflite_common_ffi` 上**不生效**（仓库既有 DB 测试已如此写但仍失败）。

## 9. 数据来源收口（应用分析页）

原先同一项数据存在**双源**（Rust 从 APK 解析 / 平台从 PackageManager 取），会漂移。
现已统一：**能由 APK 文件决定的以 Rust 为准**，平台侧只保留「这台设备上这次安装」的
运行时状态。

| 数据 | 统一后来源 |
|---|---|
| 主 Activity / meta-data / minSdk / targetSdk / **APK 大小** | **Rust 优先**，平台值仅兜底 |
| 构建版本（Kotlin/Gradle/Java/Compose/**AGP**） | **Rust**（`scan_build_versions`），宿主兜底同样只读中央目录 |
| 结构清单 / DEX / 原生库 / ELF / 签名方案 / 特征 / 规则命中 | Rust |
| 权限**授权状态**、组件**启用状态**、安装时间、UID、安装器、数据目录、系统应用标记、应用图标与名称 | 平台（运行时态，搬不走） |
| **规则库数据本身** | 宿主资产 `assets/lcrules/*.json`（匹配在 Rust） |

### Dart 侧兜底路径不再整包解压

`archive` 3.x 没有流式解码接口，原先 6 处兜底都是
`File(path).readAsBytesSync()` + `ZipDecoder().decodeBytes()`（整包进内存 + 全量解压）。

新增 `lib/core/service/apk_zip_index.dart`：**直接解析 zip 中央目录**，条目名/大小/CRC32/
压缩方式零成本获得；需要内容时 `readEntryBytes` 只解压指定条目
（STORED 直取，DEFLATED 用 `RawZLibFilter.inflateFilter(raw: true)`）。

6 处兜底全部改走它：native 规则匹配 / ABI 列表 / 全量原生库 / assets .so / DEX 清单 /
构建版本。分析页上**已不存在整包解压**。

## 10. 后续可做

- 快照备注编辑（如「更新前 / 更新后」）与自动快照（安装/更新前自动采集）
- 跨应用快照总览（LibChecker 的 statistics 页）
- 载荷 schema 演进：新增节时提升 `payloadVersion`，对比页会自动按不可比处理

## 11. Agent 能力（快照协议化接入）

让助手能直接"看出**版本更新改了什么**"，无需用户手动点页面。

### 统一入口：`AppSnapshotService`

新增 `lib/core/snapshot/snapshot_service.dart`，把「采集 → 落库」「对比」「文本化」
收敛成一个服务，UI 与 Agent 共用：

| 方法 | 作用 |
|---|---|
| `create()` | 解析安装包路径 → `SnapshotCollector.capture` → `AppSnapshotStore.insert` |
| `listByApp()` / `listApps()` / `getById()` / `delete()` | 查询与删除 |
| `compare()` | 调 `SnapshotDiffEngine`；省略 id 取最近两份，指定 id 时按时间纠正为"旧 → 新" |
| `renderDiff()` / `renderDetail()` / `renderRecordList()` / `renderAppList()` | 渲染给模型阅读 |

**版本/应用名一律取真实来源**：`create()` 不使用调用方传入的版本值，采集器从
`PackageManager` 或 APK 内 AndroidManifest 读取；记录页的应用名同样以采集到的 label 为准。

### Agent 工具（协议注册表，见第五篇 4 节）

| 工具 | 说明 |
|---|---|
| `appSnapshot` | `action=create/list/apps/detail/delete`；`delete` 属敏感操作，必须先 `confirmAction` |
| `snapshotCompare` | 对比两份快照，返回结论 + 各节明细 |

### 差异文本化（`renderDiff`）

给模型的文本包含：结论（重新构建 / 仅资源更新 / 仅原生更新 / 重新签名…）、
各节指纹是否变化（签名/DEX/原生库/assets/资源表）、逐节明细（字段级 `− 旧` / `+ 新`、
内容指纹是否同一文件、疑似改名/移动）、**APK 体积差（+/− 直接给出）**、
以及"待确认"标记的原因（载荷版本不一致）。每节条目数有上限，避免超长包撑爆上下文。

配套技能「版本差异分析」规定了输出顺序（先一句话结论，再分节明细）与约束
（只陈述差异中的事实，不臆测；签名变化必须提醒用户）。

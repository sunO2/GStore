# 核心模块：F-Droid 与 Rust

> 开发 Wiki 第七篇 · 仓库管理、index-v2 解析与 Rust FFI

## 1. 模块结构

```
lib/core/fdroid/
├── FdroidRepoManager.dart      # 仓库管理器（源切换/加载/搜索/统计）
├── FdroidRepoModels.dart       # 模型（FdroidSource/FdroidApp/FdroidPackage/FdroidVersionInfo）
├── FdroidIndexV2Parser.dart    # index-v2 索引解析
├── FdroidIsolateParser.dart    # isolate 并发解析
├── JsonMergePatch.dart         # RFC 7386 增量合并
├── ConditionalHttpClient.dart  # 条件请求（Last-Modified/ETag）
├── FdroidRepoDao.dart / FdroidRepoDatabase.dart  # Floor 表
└── FdroidTempDatabase.dart     # 临时索引库

lib/core/rust/
├── bridge.dart                 # flutter_rust_bridge 封装
├── FdroidRustRepoManager.dart  # Rust 仓库管理器（下载/查询/APK 解析）
└── frb_generated*.dart         # 生成的 FFI 绑定

rust/fdroid_repo/               # Rust 源码（cargo）
└── src/ bridge.rs / repo.rs / apk.rs / models.rs / lib.rs
```

## 2. FdroidRepoManager

GetxController，管理 F-Droid 数据源与索引：

| 方法 | 说明 |
| --- | --- |
| `switchSource(sourceId)` | 切换当前源 |
| `loadRepository({forceRefresh})` | 加载/刷新索引（支持增量） |
| `searchApps(keyword, {limit})` | 搜索应用 |
| `getAppByPackageName` / `getAllApps` / `getAppCount` | 查询 |
| `getStatistics` | 统计 |
| `addSource` / `removeSource` | 源管理 |
| `checkIncrementalUpdate` / `applyIncrementalUpdate` | 增量更新 |
| `clearData` | 清空数据 |

### 默认源

- `FdroidSource.official`：F-Droid 官方源（含清华等国内镜像）。
- `FdroidSource.tunaMirror`：清华镜像（优先级更高）。

## 3. index-v2 解析与增量更新

- `FdroidIndexV2Parser`：解析 index-v2 JSON 结构为 `FdroidApp` / `FdroidPackage`。
- `JsonMergePatch`：实现 **RFC 7386**，将增量 patch 合并到本地索引（新增/删除键、递归合并、数组整体替换）。
- `FdroidVersionInfo`：记录当前索引版本与可用增量版本列表：
  - `hasUpdate`：可用版本尾部 > 当前版本。
  - `getNextVersion()`：返回下一个待下载版本号。
- `ConditionalHttpClient`：基于 `Last-Modified` / `ETag` 的条件请求，减少重复下载。

## 4. Rust FFI（flutter_rust_bridge 2.x）

### 能力

| 函数 | 说明 |
| --- | --- |
| `parse_apk_info(apk_path)` | 解析 APK 元数据（包名/图标/版本） |
| `initialize(db_path)` | 初始化 Rust 侧 F-Droid 数据库 |
| `get_app_count` / `search_apps` / `get_app_detail` / `get_one_app` | 索引查询 |
| `clear_apps` | 清空 |
| `download_repository`（桥接封装） | 下载仓库索引 |

### 生成绑定

- Dart 侧由 `frb_generated.dart` 提供，平台差异实现 `.io.dart` / `.web.dart`。
- Rust 侧 `frb_generated.rs` 由 build_runner 的 `flutter_rust_bridge_codegen` 生成。

### 构建

见 `rust/BUILD_ANDROID.md`、`rust/ANDROID_BUILD.md`，以及根目录脚本：
`build_android_rust.sh`（NDK 多架构交叉编译）、`setup_rust.sh`。

> 产物输出到 `android/app/src/main/jniLibs`。CI 与本地构建均需先完成 Rust 交叉编译。

## 5. 模型要点

- `FdroidApp`：应用（含 categories / added / lastUpdated / metadata 等内存字段，不落库）。
- `FdroidPackage`：包/APK 条目（apkName / versionCode / size / hash / nativecode），
  提供 `toDownloadInfo(baseUrl)` 转换与 `downloadUrl`。
- 缺失字段均有默认值（如名称缺省用包名、图标缺省 `{packageName}.png`）。

## 6. 相关测试

`test/fdroid_repo_models_test.dart`：源配置序列化、fromIndexV2 解析、增量版本判断。
`test/json_merge_patch_test.dart`：RFC 7386 全场景。

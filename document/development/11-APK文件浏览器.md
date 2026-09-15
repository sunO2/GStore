# APK 文件浏览器

> 把 APK 当「可浏览的容器」打开：目录树 + 搜索 + 多类型内容预览（图片 / 文本 / JSON /
> 字体 / 证书 / 视频音频 / 二进制），支持进入 assets 内的嵌套 zip，并预留 DEX 结构浏览。
> 入口：**应用分析页导航头**（与「应用快照」并列）。

## 1. 架构裁决：解压放哪、解析放哪

### 1.1 原始提案与它的三个问题

初始设想是「按端能力切分」——**Flutter 能解析的放 Flutter，不能解析的放 Rust**。
方向（解压归 Rust）是对的，但**分界线选错了**：

1. **会造出两个解压器**。Dart 已有 `ApkZipIndex`（`lib/core/service/apk_zip_index.dart`），
   Rust 已有 `zip` crate。按「谁能读」切分，等于两套 zip64 / 路径穿越 / zip 炸弹防护，
   必然漂移——现状已经漂了：**Dart 侧明确拒绝 zip64**（`apk_zip_index.dart:76-78`），
   Rust 侧 `zip 2.4.2` 天然支持。
2. **「能不能读」是动态的**。今天 Dart 读不了 DEX，明天引个包就能读，归属会反复搬迁，
   评审成本高、代码注释永远滞后。
3. **真正的成本不在解析库，而在跨 FFI 边界搬字节**。让 Rust「读出来给 Flutter 渲染」
   如果不定义清楚传输形态，就会退化成 base64/JSON 回传，大文件直接爆内存与上下文。

### 1.2 采纳的分界线：按**数据形态**切，并且**单一生产者**

| 层 | 归属 | 规则 |
|---|---|---|
| 容器打开 / 中央目录 / 解压 / 嵌套容器 | **Rust（唯一解压者）** | zip64、路径穿越、zip 炸弹上限、嵌套递归都在这一层收口 |
| 跨边界传输 | **只传「文件路径 + 元数据」，不传字节** | 内容落到应用缓存文件，Dart 用文件路径消费；二进制永不进信封 |
| 语义解析（manifest / arsc / DEX / ELF / 证书） | **Rust**（复用既有解析器） | Dart 不重复实现解析，只消费结构化 JSON |
| 纯展示（图片 / 字体 / 文本 / 视频 / 二进制） | **Dart** | Flutter 本来就不「解析」这些，它吃文件/字节 |
| 目录枚举 | **按层懒加载** | `list(container, dir)` 一次列一层；嵌套包不预先递归展开 |

一句话：**Rust 是 APK 内容的唯一出口**（呼应「资源由 rust 端出口统一处理」的既有原则），
Dart 是唯一渲染者。这样只有一套解压与一套安全校验，且字节不跨边界。

### 1.3 备选方案对比

| 方案 | 说明 | 结论 |
|---|---|---|
| A. 全 Dart（扩 `ApkZipIndex`） | 改动最小，但要在 Dart 重写 zip64、嵌套解压、安全校验 | ✗ 与 Rust 解压并存，双源漂移 |
| B. 全 Rust（含渲染） | 无 Dart 侧解析 | ✗ 展示强耦合主题与文案，且 Rust 无法渲染 |
| **C. 容器归 Rust、展示归 Dart（采纳）** | Rust 出「文件 + 结构化元数据」，Dart 渲染 | ✓ 单解压者、字节不跨界、解析器复用 |
| D. 混合（谁能读谁读） | 原始提案 | ✗ 见 1.1 |

## 2. Rust 侧：`browser` 能力（并入 `gstore_mod_analyzer`）

不新建 crate（APK 域能力归既有 analyzer；新 crate 只用于重依赖隔离）。

新增 `src/browser.rs`，在 `lib.rs` 的 `call` 分发里加两条 method（**不改 C ABI、不加导出符号**）：

| method | payload 编码 | 响应 |
|---|---|---|
| `browse_apk_entries` | `apk_path NUL chain NUL dir` | JSON `BrowseListing` |
| `export_apk_entry` | `apk_path NUL chain NUL entry NUL out_path` | JSON `ExportedEntry` |

- `chain`：嵌套容器链，`!` 分隔（如 `assets/plugins/pack.zip`），空串 = APK 根。
- `dir`：当前容器内的目录前缀，空串 = 容器根。
- `entry`：当前容器内的文件路径。

### 2.1 数据结构

```
BrowseEntry  { path, name, is_dir, size, compressed_size, crc32, stored,
               kind, browsable }
BrowseListing{ container, dir, parent_dir, can_go_up, entries,
               total_files, container_size, truncated }
ExportedEntry{ path, size, crc32, out_path }
```

`kind` 取值：`dir|zip|apk|jar|aar|dex|so|arsc|manifest|image|text|json|font|cert|video|audio|binary`。
`browsable=true` 仅对 zip 家族（zip/apk/jar/aar）——UI 据此允许「进入」。

### 2.2 硬约束与防护

- **zip64**：由 `zip` crate 提供，无需自研（Dart 侧缺的正是这一块）。
- **嵌套**：深度上限 4；内层容器解压上限 64 MB；只读，不写回。
- **导出**：单个条目上限 1 GB；只写调用方给定的 `out_path`（应用缓存目录），
  不按条目名落盘 → **不构成 zip slip**。
- **列目录**：一次最多返回 5000 条（`truncated` 标记），超过由 UI 提示搜索收窄。

## 3. Dart 侧

- 契约：`ModuleTypes.dart` 加 `ApkBrowsableEntry` / `ApkBrowseListing` / `ApkExportedEntry`；
  `Contract.dart` 加两个 decoder；`AnalyzerRustDecoder` 加两个静态方法。
- 服务：`ApkBrowserService`——缓存目录管理、导出文件命名与清理、条目类型判定复用 Rust 结果。
- UI：
  - `ApkBrowserPage`：**一个页面 = 一个容器**（APK 根，或某个压缩包）；
  - `ApkDirectoryView`：**目录组件**，一个组件 = 一层目录；宿主页把各层压进栈并**保活**；
  - 预览：图片 / 文本 / JSON / 字体 / 证书 / 十六进制；视频音频先出**元数据卡 + 导出**；
  - 设计规范：统一 `AppSheet` 弹层、`AppSpacing.lg` 页面边距、深色模式走主题令牌。

### 3.1 导航模型（返回语义 / 压缩包 / 状态保留）

| 交互 | 行为 | 实现 |
|---|---|---|
| 进入文件夹 | 向目录栈**压入一个目录组件** | `_dirs` 追加 + `IndexedStack` 渲染 |
| 手势 / 系统返回 | 栈深 > 1 时**只回退一层**，不退出本页 | `PopScope(canPop: _dirs.length == 1)` + `onPopInvokedWithResult` |
| 标题栏返回按钮 | **直接退出本页**（不逐层回退） | `BackButton(onPressed: Navigator.pop)` 显式绕过 `PopScope` |
| 打开压缩包 | **另开一个页面**（不重置当前页） | `Navigator.push` 新的 `ApkBrowserPage(initialChain: 容器链+包路径)` |
| 返回上一层 | **状态原样保留**（滚动位置 / 搜索词 / 已加载清单） | 各层组件在 `IndexedStack` 中保活，不重新列举 |

要点：**目录留在页内（栈 + 保活），压缩包另开页（新容器 = 新页面）**。
面包屑只表达"本容器内的目录路径"，因此不再需要区分"容器段"与"目录段"两种跳转语义。

### 3.2 布局稳定（避免"搜索框闪一下"）

目录统计行（`条目 N · 当前容器 X`）原来是**有数据才渲染**：进入新目录时该行不存在，
列举回来的瞬间才冒出来，把下面的搜索栏整行顶下去 —— 肉眼就是"搜索框闪一下"。
现在该行**常驻占位**（加载中显示 `正在读取目录…`、失败显示 `—`、有数据才显示统计），
文案永不为空且强制单行，因此搜索栏在整层生命周期内位置不再跳动。
`test/apk_browser_test.dart` 用「加载中 vs 加载后搜索栏 Y 坐标相等」把这条锁住。

## 4. 分期与验收

### P0（本次）
- Rust `browse_apk_entries` + `export_apk_entry`（含 zip64 / 嵌套 / 安全上限）+ 单测。
- Dart 契约 + `ApkBrowserService`。
- `ApkBrowserPage`（目录树 + 搜索 + 面包屑）与预览（图片 / 文本 / JSON / 字体 / hex / 证书）。
- 入口：应用分析页导航头。
- 验收：`cargo test` 通过；`flutter analyze` 无新增告警；相关 `flutter test` 通过。

### P1（本次）
- Agent 工具 `apkBrowser`（`browse` / `read` 动作）。
- 嵌套 zip 深度浏览（同一 API，UI 上层栈）。
- 视频 / 音频：**元数据卡 + 导出到缓存**（内置播放需新增依赖，见风险表，待拍板）。

### 未闭环项（明确记录，不夹带）
- **视频/音频内置播放**：需新增 `video_player` / `just_audio`，会改动 Android 构建面，
  按「优先复用、少引依赖」暂不加；当前只给元数据与导出路径。
- **证书字段解析**：当前 PEM 直接显示文本、DER 显示十六进制；
  完整 X.509 字段（主题/有效期/扩展）未接入（可复用平台侧 `CertificateFactory`）。
- **DEX 结构浏览 / 反汇编 / JAR**：见 P2，未开工。
- **真机端到端验证**：未做（见第 7 节）。


### P2（后续）
- DEX 结构浏览（类 → 方法 / 字段 / 签名）：需在 Rust 遍历 `proto/field/method_ids`
  与 `class_data_item`（现仅读头计数 + 类描述符）。
- DEX 反汇编（smali 文本）。
- **DEX → JAR：列为待决项**。纯 native 无成熟路径（成熟实现全在 Java 生态的
  dex2jar/jadx，需 JVM），等价于自研一个字节码翻译层，成本与风险都高。
- 内容搜索（解压扫描，必须走 `TaskBridge` 带进度与取消）。
- 任意 APK 路径选取（SAF / `content://` → 复制到私有目录）。

## 5. 风险表

| 风险 | 影响 | 对策 |
|---|---|---|
| 大条目 / 大包内存 | OOM、卡顿 | 只按需解压单条；导出落文件；列表限条数 |
| 嵌套 zip 炸弹 | 递归解压爆内存 | 深度 ≤4、内层 ≤64 MB、只读 |
| 双解压器漂移 | 行为不一致 | 收敛为 Rust 单出口（本方案核心） |
| DEX→JAR 无 native 方案 | 需求无法在纯 native 内闭环 | 明示为待决项，不与其他里程碑绑定 |
| 新增媒体播放依赖 | Android 构建面变化 | 视频/音频先只做元数据 + 导出，依赖决策单独拍板 |

## 6. 非目标

- 不修改 / 不重打包 / 不重签目标 APK（只读取其副本）。
- 不在本能力内做内容级搜索（P2）。
- 不引入 Java/JVM 运行时。

## 7. 交付记录（本轮）

### 落点

| 层 | 文件 | 内容 |
|---|---|---|
| Rust | `rust/gstore_mod_analyzer/src/browser.rs` | `browse_entries` / `export_entry`、嵌套链、分类、上限 |
| Rust | `rust/gstore_mod_analyzer/src/lib.rs` | `browse_apk_entries` / `export_apk_entry` 分发、`split_nul` |
| 契约 | `lib/core/rust/contract/ModuleTypes.dart` | `ApkBrowsableEntry` / `ApkBrowseListing` / `ApkExportedEntry` |
| 契约 | `lib/core/rust/Contract.dart` | 两个 decoder |
| 契约 | `lib/core/rust/AnalyzerRustDecoder.dart` | `browseApkEntries` / `exportApkEntry`（+ `chainSep`） |
| 服务 | `lib/core/service/apk_browser_service.dart` | 列表 / 导出 / 文本读取、缓存目录、`apkEntryKindLabel`、`hexDump` |
| UI | `lib/page/apk_browser/view.dart` | 浏览器页壳：容器 = 页面、目录栈 + `PopScope` 返回语义、压缩包另开页 |
| UI | `lib/page/apk_browser/directory_view.dart` | 目录组件（一层目录：面包屑 / 统计 / 搜索 / 列表，可注入 loader 便于测试） |
| UI | `lib/page/apk_browser/preview.dart` | 预览页（图片 / SVG / 文本 / JSON / 字体 / 证书 / 媒体 / hex） |
| 入口 | `lib/page/installed_apps/sdk_analysis_page.dart` | 导航头「文件浏览」 |
| Agent | `lib/core/agent/agent_tool_spec.dart` + `agent_service.dart` | `apkBrowser`（browse/read） |
| 产物 | `android/app/src/main/jniLibs/<abi>/libgstore_mod_analyzer.so` | 4 ABI 重建并替换 |

### 已验证

- `cargo test`（analyzer）：**96 项通过**（含 browser 8 项：根/嵌套列举、分类、导出、目录导出报错、深度上限、链切分）。
- 交叉编译：`aarch64/armv7/x86_64/i686-linux-android` 四个目标均构建成功；
  arm64 产物实测 `ARM aarch64`、LOAD `p_align=0x4000`（16 KB）、`gstore_mod_analyzer_register` 已导出。
- `flutter test`：相关集合 **93 项通过**，其中 `test/apk_browser_test.dart` 13 项——
  契约解码 / hexdump / 工具协议 / 空态，以及**导航与布局 4 项**：
  目录压栈 + 手势返回只回退一层 + 标题栏返回退出本页、压缩包另开页不重置原页、
  返回上一层保留搜索词与过滤结果、加载前后搜索栏位置不位移。
- `flutter analyze`：新增文件 0 问题（`sdk_analysis_page.dart` 的 6 条为既有 info，不在改动行）。
- **APK 已构建并核对**：`build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk`；
  包内 `lib/arm64-v8a/libgstore_mod_analyzer.so` 确认为新构建（含 `browse_apk_entries`）。
  4 个 ABI 的 `.so` 已同步 jniLibs 与 release-modules。

### 未验证（不要当成已修好）

- **真机上未跑过**：目录列举 / 导出 / 预览 / 嵌套进入的端到端行为未在设备上确认；
  上述结论来自单测（Rust 直跑、宿主侧解码、页面导航用注入的假 loader），不代表真机流程已通。
  其中「返回语义 / 压缩包另开页 / 状态保留」三项是用**假数据**验证的交互契约，
  真机上的滚动位置保留还需实测确认。
- **APK 未做安装验证**：包已构建，但未安装到设备核对新 `.so` 是否被加载、
  `browse_apk_entries` 是否可用。
- 若真机出现「分析模块未就绪」，第一个判别数据是：APK 内
  `lib/<abi>/libgstore_mod_analyzer.so` 是否为新构建（大小约 1.05 MB / arm64），
  以及模块日志里的握手行。



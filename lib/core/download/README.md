# 多渠道下载架构（Rust-only 绑定）

## 概述

自 Wave 6B 起，下载只有 Rust 一个实现，Dart 侧**没有回落、没有运行时内核选择器**：

- **RustDownloadService（当前唯一绑定）**：`IDownloadService` 由 `DownloadModule.onRegister`
  直接绑定到 `RustDownloadService.instance`。它是 `DownloadFacade` 之上的薄适配层：
  参数整形、请求头透传、`forceDownload` 语义、`DownloadTask` 视图模型转换。
  模块不可用是**类型化失败**（`DownloadModuleUnavailableException`，错误码
  `CORE_E_DOWNLOAD_MODULE_UNAVAILABLE`），绝不静默回落到任何 Dart 实现。
- **DownloadFacade（类型化 Dart 边界）**：所有启动、查询、变更、事件都经它走 FRB
  `DownloadApi`，并把核心错误（含“模块未挂载”标记）映射成类型化 Dart 异常。没有
  module-direct 分支，因此不存在“模块实例 / 核心实例”两套状态混跑。
- **gstore_core + gstore_mod_download（下载内核）**：core 拥有队列状态与
  `gstore_core.db` 镜像；模块拥有自己的 `gstore_mods/download/download.db` 并执行传输。
  core 只在 resync/reconcile 时**只读**打开模块库做对账，从不改写模块行。
- **DownloadTask（Dart 视图模型）**：`DownloadStatusEnum` 枚举 + 进度/速度/ETA/分段，
  由 core DTO 映射而来；持久化归属已上移到 core/module 两层数据库。
- **下载策略**：各渠道 `IDownloadStrategy` 只负责生成/校验 `DownloadRequest`
  （URL 转换、代理、请求头、超时等预处理），不再触碰传输与持久化。

## 架构层次

```
┌─────────────────────────────────────────────────────────┐
│                     UI / Logic 层                        │
│  (DetailLogic / UpdateLogic / DownloadManagerLogic /   │
│    Agent 工具——全部面向 IDownloadService 接口)           │
└─────────────────────────────────────────────────────────┘
                           ↓ Get<IDownloadService>()
┌─────────────────────────────────────────────────────────┐
│         RustDownloadService（IDownloadService 唯一绑定） │
│   参数整形 / headers / forceDownload / DTO → DownloadTask │
└─────────────────────────────────────────────────────────┘
                           ↓ DownloadRequest + CancelToken
┌─────────────────────────────────────────────────────────┐
│              DownloadFacade（类型化 Dart 边界）           │
│   统一映射 DownloadModuleUnavailableException 等错误      │
└─────────────────────────────────────────────────────────┘
                           ↓ FRB
┌─────────────────────────────────────────────────────────┐
│   DownloadApi → gstore_core 下载端口 → gstore_mod_download │
│   core 镜像库 gstore_core.db / 模块库 download.db（只读对账）│
└─────────────────────────────────────────────────────────┘
                           ↓ 核心广播事件
┌─────────────────────────────────────────────────────────┐
│   DownloadTask（Dart 视图模型）+ watchAll 实时流          │
└─────────────────────────────────────────────────────────┘
```

## 各渠道下载策略

策略层职责收窄为**生成下载请求**：`DownloadStrategyManager`（单例）按渠道分发到对应的
`IDownloadStrategy`，返回 `DownloadRequest?`（url / savePath / headers / fileSize / resume）。

### LocalDbChannel
- **代理来源**: `detailData.extra['proxy']`
- **URL转换**: 非 GitHub 完整 URL 时使用代理拼接（`BaseDownloadStrategy.applyProxy`）
- **特殊处理**: 支持配置化的 GitHub 代理加速

### VivoChannel
- **Headers**: User-Agent, Accept-Language, Accept, Connection
- **URL处理**: 直接使用原始 URL
- **特殊处理**: 添加 vivo 应用市场特定的请求头

### GitHubChannel
- **代理来源**: 全局 `getProxy()` 函数
- **URL转换**: GitHub releases 类 URL 经代理前缀转换（`applyProxy`）
- **特殊处理**: API 请求添加 `Accept: application/vnd.github.v3+json`

### HttpChannel
- **URL处理**: 直接使用原始 URL
- **特殊处理**: 无，保持最简单的实现

## 使用方式

业务代码一律经 `ModuleManager.instance.get<IDownloadService>()` 取当前内核；自 Wave 6B
起它**恒为** `RustDownloadService`（模块不可用时为 `null` 或调用抛类型化
`CORE_E_DOWNLOAD_MODULE_UNAVAILABLE`，绝不静默回落到任何 Dart 实现）：

```dart
final service = ModuleManager.instance.get<IDownloadService>();

// 1. 普通下载（断点续传 / 强制重下）
final task = await service.download(
  appId, appName, version, url, fileName,
  downloadSize: size,
  forceDownload: false,
);

// 1b. 带请求头（UA / Accept-Language / 渠道头由策略层生成后原样透传给模块）
final taskWithHeaders = await service.download(
  appId, appName, version, url, fileName,
  headers: {'User-Agent': '...', 'Accept-Language': 'zh-CN'},
);

// 2. 策略化下载（策略层预处理 URL/代理/Headers 后交给下载服务）
final request = await DownloadStrategyManager.instance.createRequest(download, detail);
if (request != null) {
  task = await service.downloadWithContext(request, appId, appName, version, fileName);
}

// 3. 实时进度 / 终态
final sub = service.watch(task.id!).listen((t) {
  // t.status: queued/downloading/connecting/paused/completed/failed/cancelled
  // t.received/t.total/t.speedBps/t.etaSec
});

// 4. 控制
service.pause(id); service.resume(id); service.cancel(id); service.retry(id);
```

语义说明：

- **headers**：`DownloadRequest.headers` 被原样放进 `DownloadStartRequest.headers` 并转发给
  下载模块；模块负责真正发送。策略层只负责生成，不做二次覆盖。
- **forceDownload**：core start 对同 `destPath` 的已有任务默认保留（`ConflictPolicy::Keep`），
  所以 `forceDownload: true` 不是简单重发，而是重启该 `destPath` 上**最新的 core 行**
  （清空分段/进度并从零重下）；没有匹配行时退回普通 start。
- **安装职责拆分**：下载域只负责字节，`installAfterDownload` 仅随请求记录/转发；真正的
  APK 安装由 `InstallManager` 经 core 安装域执行，下载层不会假装自己完成安装。

策略注册（`DownloadStrategyManager` 已在模块初始化时注册全部内置策略）：

```dart
DownloadStrategyManager.instance.registerAll([
  LocalDbDownloadStrategy(),
  VivoDownloadStrategy(),
  GitHubDownloadStrategy(),
  HttpDownloadStrategy(),
  FdroidDownloadStrategy(),
]);
```

## 传输层说明

- **生产路径**：`gstore_mod_download` 自己执行传输；Dart 侧只传 `DownloadStartRequest`
  （URL、`dest_path`、headers、期望 SHA-256 等），不参与字节搬运。Dart 侧历史传输内核
  已整体删除，不存在第二条字节搬运路径。

## 旧管线已删除

`DownloadService`（`lib/core/service/downloadService.dart`）、
`segment/{segment_planner,segment_downloader,segment_merger}.dart`、
`lib/http/download/DownloadStatus*.dart`（旧 `DownloadStatus` 实体 / Floor 数据库 / DAO）
已全部删除，迁移到上面的新架构。

自 Wave 6B 收尾起，Dart 侧历史下载内核与其 Floor 持久化也已整体删除：旧编排
`download/manager/` 下的管理器、传输内核 `download/core/` 下的引擎与事件、
`download/manager/` 下的 Floor 仓储、`download/model/` 下的 Floor 数据库 / DAO / 实体
（数据库文件 `*_database.dart`、`*_database.g.dart`、`*_dao.dart`、`*_entity.dart`），
以及 `download/rust/` 下仅测试使用的未绑定映射。删除后 Dart 侧**没有**任何下载传输 /
持久化实现，`download_task.db` 不再由 Dart 创建或写入。

新代码请只用 `IDownloadService` + `DownloadTask`；下载状态以 core 镜像库为准。模块不可用时
调用方观察到类型化失败 `DownloadModuleUnavailableException`，绝不静默回落到 Dart Floor。

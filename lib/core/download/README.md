# 多渠道下载架构（DownloadManager 重写后）

## 概述

下载模块在 DownloadManager 重写后拆分为四个职责清晰的层次：

- **DownloadEngine（可替换核心）**：纯传输内核，只负责把一个 `DownloadRequest` 的字节流落到磁盘，
  内部自含 Range 探测 / 多段并发 / 单段回退，不做队列、并发上限、持久化。
- **DownloadManager（编排）**：`IDownloadService` 的唯一实现，负责队列调度、并发控制、
  断点续传、状态机（queued/downloading/paused/completed/failed/cancelled）与 APK 完整性校验。
- **DownloadTask / DownloadRepository**：持久化模型与仓库。`DownloadTask` 是全新的状态模型
  （`DownloadStatusEnum` 枚举 + 进度/速度/ETA/分段），`DownloadRepository` 基于 Floor 的
  `GStoreDownloadDatabase`（`download_task.db`）读写，并提供 `watch(id)` 流实时推送进度。
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
│              DownloadManager（编排 / GetxService）       │
│  队列 + 并发上限 + 状态机 + 断点续传 + 文件校验 + 安装钩子   │
└─────────────────────────────────────────────────────────┘
                           ↓ DownloadRequest + CancelToken
┌─────────────────────────────────────────────────────────┐
│              DownloadEngine（可替换核心）                  │
│  DioDownloadEngine：Range 探测 → 多段并发 / 单段回退       │
└─────────────────────────────────────────────────────────┘
                           ↓ DownloadEvent 流
┌─────────────────────────────────────────────────────────┐
│   DownloadRepository（Floor 持久化 + watch(id) 实时流）   │
│   DownloadTask（DownloadStatusEnum 状态模型）             │
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

业务代码一律经 `ModuleManager.instance.get<IDownloadService>()` 取 `DownloadManager`：

```dart
final service = ModuleManager.instance.get<IDownloadService>();

// 1. 普通下载（断点续传 / 强制重下）
final task = await service.download(
  appId, appName, version, url, fileName,
  downloadSize: size,
  forceDownload: false,
);

// 2. 策略化下载（策略层预处理 URL/代理/Headers 后交给引擎）
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

- 下载走 Dio 的 `DioDownloadEngine`，底层 `HttpClientAdapter` 为 `RhttpAdapter`
  （`lib/http/rhttp_adapter.dart`）。
- **GZip 修复**：rhttp 对 `content-encoding: gzip` 的响应会先解压再移除该头；当头部仍存在
  时说明响应体仍是压缩字节，`RhttpAdapter` 会在适配器层用 `dart:io` 的 `gzip/zlib` 解码器手工解压，
  移除 `content-encoding` 并写入 `x-gstore-decoded-encoding` 标记头。`DownloadEngine` 据此识别
  "已解码流"：不按 `content-length` 校验总字节数、不尝试 Range 分段（gzip 流无法部分读取），
  避免解压后字节数与声明大小不符导致的误判。

## 旧管线已删除

`DownloadService`（`lib/core/service/downloadService.dart`）、
`segment/{segment_planner,segment_downloader,segment_merger}.dart`、
`lib/http/download/DownloadStatus*.dart`（旧 `DownloadStatus` 实体 / Floor 数据库 / DAO）
已全部删除，迁移到上面的新架构。若仍引用这些路径，请改用 `IDownloadService` + `DownloadTask`
+ `DownloadRepository`（本项目已无任何遗留引用）。

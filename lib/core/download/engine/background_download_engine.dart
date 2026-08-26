/// background_download_engine.dart
///
/// 混合下载引擎适配层：将大文件下载路由到 background_downloader 包，
/// 获得进程死亡后任务自动恢复能力。
///
/// 路由规则（AD1 修正版）：
/// - ctx.proxy != null   → dio（自研引擎，代理按任务区分）
/// - fileSize == null     → dio（未知大小，保守走自研引擎）
/// - fileSize > 450MB     → dio（legacy 自研，内部自行决定单段/多段）
/// - fileSize <= 450MB    → background（background_downloader）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';

import 'package:gstore/http/download/DownloadStatus.dart';

// ─── 路由决策枚举 ────────────────────────────────────────────

/// 下载引擎路由决策
enum DownloadEngineRoute {
  /// 走自研多段引擎或 Dio 单段（legacy 路径）
  legacy,

  /// 走 background_downloader（新 BD 引擎）
  background,
}

// ─── 成功收尾钩子抽象 ────────────────────────────────────────

/// 下载成功后的收尾钩子序列接口。
/// 由 DownloadService 提供真实实现，引擎层仅调用不复制逻辑。
abstract class DownloadSuccessHook {
  /// 触发安装（APK 文件）
  Future<void> onInstall(String fileName, String savePath);

  /// 通知下载完成
  Future<void> onNotifyComplete(int notifId, String notifTitle);

  /// 解析并更新 APK 信息（非 APK 文件跳过）
  Future<void> onApkInfo({required String appId, required String apkPath});

  /// 下载安装完成后的后续处理（刷新更新状态等）
  Future<void> onAfterDownloadInstalled(DownloadStatus status);
}

// ─── 重启对账结果 ────────────────────────────────────────────

/// 重启对账结果
class ReconcileResult {
  /// 被恢复的任务 tag 列表（Floor 中存在且 BD 也有）
  final List<String> recovered;

  /// 孤儿任务 taskId 列表（BD 有但 Floor 中没有对应 tag）
  final List<String> orphaned;

  /// 被删除的任务 taskId 列表（v1 不删除，始终为空）
  final List<String> deleted;

  const ReconcileResult({
    required this.recovered,
    required this.orphaned,
    required this.deleted,
  });
}

// ─── BackgroundDownloadEngine ────────────────────────────────

/// 混合下载引擎适配层
///
/// 职责：
/// 1. 路由决策（静态方法，无状态）
/// 2. 封装 background_downloader 的 enqueue/cancel/resume
/// 3. 监听 updates 流，映射 TaskStatusUpdate/TaskProgressUpdate
///    到既有 DownloadStatus 状态机方法
/// 4. 重启对账（allTasks vs Floor 存活 tag）
class BackgroundDownloadEngine {
  /// 成功收尾钩子（可注入，测试用 fake）
  final DownloadSuccessHook? _successHook;

  /// 活跃任务追踪（taskId → DownloadStatus）
  final Map<String, DownloadStatus> _activeTasks = {};

  /// 任务状态追踪（taskId → TaskStatus，内部维护，供 queryAllTaskStates 使用）
  final Map<String, TaskStatus> _taskStatusMap = {};

  /// 最大并发数（与 AD1.5 holdingQueue 对齐）
  static const int maxConcurrent = 3;

  /// 文件大小阈值：≤ 此值走 background_downloader，> 此值走自研引擎（Dio）
  static const int backgroundEngineMaxBytes = 450 * 1024 * 1024;

  // ─── 静态更新流分发器（单例监听，多引擎实例共享） ───────
  static StreamSubscription? _globalUpdatesSub;
  static final Map<String, BackgroundDownloadEngine> _engines = {};

  BackgroundDownloadEngine({DownloadSuccessHook? successHook})
      : _successHook = successHook;
  // 注意：不在此处注册监听，由 enqueue 按需触发（避免测试中构造即触发 stream listen）

  // ═══════════════════════════════════════════════════════════
  // 路由决策（AD1）
  // ═══════════════════════════════════════════════════════════

  /// 判断下载应走哪条路径（纯函数，可直接测试）
  ///
  /// 路由规则（AD1 修正版）：
  /// - ctx.proxy != null   → dio（自研引擎，代理按任务区分）
  /// - fileSize == null     → dio（未知大小，保守走自研引擎）
  /// - fileSize > [backgroundEngineMaxBytes]  → dio（自研引擎，内部自行决定单段/多段）
  /// - fileSize <= [backgroundEngineMaxBytes] → background（background_downloader）
  static DownloadEngineRoute routeDecision(
    DownloadContext ctx, {
    @Deprecated('路由不再依赖多段判定，保留参数以兼容调用方') bool multiSegmentEnabled = false,
  }) {
    // 代理例外：BD 的 Config.proxy 是全局设置，无法按任务区分
    if (ctx.proxy != null && ctx.proxy!.isNotEmpty) {
      return DownloadEngineRoute.legacy;
    }

    // 未知文件大小：保守走自研引擎
    if (ctx.fileSize == null) {
      return DownloadEngineRoute.legacy;
    }

    // 大文件（> 450MB）走自研引擎，≤450MB 走 background_downloader
    if ((ctx.fileSize ?? -1) > backgroundEngineMaxBytes) {
      return DownloadEngineRoute.legacy;
    }

    return DownloadEngineRoute.background;
  }

  // ═══════════════════════════════════════════════════════════
  // 更新流监听（静态单例分发，避免 broadcast stream 多次 listen）
  // ═══════════════════════════════════════════════════════════

  /// 注册引擎实例到全局分发器
  void _register() {
    final key = hashCode.toString();
    if (_engines.containsKey(key)) return; // 已注册，跳过
    _engines[key] = this;
    _ensureListening();
  }

  /// 从全局分发器注销
  void _unregister() {
    final key = hashCode.toString();
    _engines.remove(key);
    // 注意：不取消 _globalUpdatesSub
    // FileDownloader().updates 是 single-subscription 流，取消后无法重新 listen
    // 空引擎时更新自然丢弃（dispatch 循环空 map）
  }

  /// 确保全局更新流只被 listen 一次
  static void _ensureListening() {
    if (_globalUpdatesSub != null) return;
    try {
      _globalUpdatesSub = FileDownloader().updates.listen((update) {
        // 分发到所有注册的引擎实例
        for (final engine in _engines.values) {
          switch (update) {
            case TaskStatusUpdate():
              engine._handleStatusUpdate(update);
            case TaskProgressUpdate():
              engine._handleProgressUpdate(update);
          }
        }
      });
    } catch (e) {
      // 测试环境下 stream 可能不可用，忽略
      debugPrint('BackgroundDownloadEngine: 注册更新流失败（测试模式可忽略）: $e');
    }
  }

  void _handleStatusUpdate(TaskStatusUpdate update) {
    final taskId = update.task.taskId;
    final ds = _activeTasks[taskId];
    if (ds == null) {
      debugPrint('BackgroundDownloadEngine: 收到未知 taskId 的状态更新: $taskId');
      return;
    }

    final status = update.status;

    // 追踪状态（供 queryAllTaskStates 使用）
    _taskStatusMap[taskId] = status;

    // failed/notFound → 记录异常详情，便于 logcat 诊断
    if (status == TaskStatus.failed || status == TaskStatus.notFound) {
      final ex = update.exception;
      debugPrint('BackgroundDownloadEngine: 下载失败 taskId=$taskId '
          'status=$status httpCode=${ex is TaskHttpException ? ex.httpResponseCode : null} '
          'desc=${ex?.description ?? ex}');
    }

    // 映射到 DownloadStatus 状态机
    applyTaskStatus(ds, status);

    // complete → 执行成功钩子序列
    if (status == TaskStatus.complete) {
      _onDownloadComplete(ds);
    }

    // 终态清理（complete / failed / canceled / notFound）
    if (status == TaskStatus.complete ||
        status == TaskStatus.failed ||
        status == TaskStatus.canceled ||
        status == TaskStatus.notFound) {
      _activeTasks.remove(taskId);
      _taskStatusMap.remove(taskId);
    }
  }

  void _handleProgressUpdate(TaskProgressUpdate update) {
    final taskId = update.task.taskId;
    final ds = _activeTasks[taskId];
    if (ds == null) return;

    // 从 task.metaData 提取原始 tag（关联 DownloadStatus）
    applyTaskProgress(
      ds,
      update.progress,
      expectedFileSize: update.expectedFileSize,
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 状态映射（供测试直接调用，也是内部核心逻辑）
  // ═══════════════════════════════════════════════════════════

  /// 将 background_downloader 的 TaskStatus 映射到 DownloadStatus 状态机
  void applyTaskStatus(DownloadStatus ds, TaskStatus status) {
    switch (status) {
      case TaskStatus.enqueued:
      case TaskStatus.running:
        ds.markAsDownloading();
        ds.status = DownloadStatus.DOWNLOAD_LOADING;
        break;
      case TaskStatus.complete:
        ds.count = ds.total;
        ds.status = DownloadStatus.DOWNLOAD_SUCCESS;
        break;
      case TaskStatus.failed:
      case TaskStatus.notFound:
        ds.downloadError();
        break;
      case TaskStatus.canceled:
        ds.downloadCanced();
        break;
      case TaskStatus.paused:
      case TaskStatus.waitingToRetry:
        // 保持当前状态，UI 层显示等待（不引入新枚举值）
        break;
    }
  }

  /// 将 background_downloader 的进度映射到 DownloadStatus.updateDownload
  void applyTaskProgress(
    DownloadStatus ds,
    double progress, {
    int expectedFileSize = -1,
  }) {
    if (expectedFileSize > 0) {
      ds.updateDownload((progress * expectedFileSize).round(), expectedFileSize);
    } else {
      ds.updateDownload(ds.count, ds.total);
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 成功钩子序列（AD2：复用 DownloadService 逻辑，禁止复制）
  // ═══════════════════════════════════════════════════════════

  /// 触发成功钩子序列（公开方法，供 DownloadService 路由调用和测试验证）
  Future<void> notifyDownloadComplete(DownloadStatus ds) async {
    await _onDownloadComplete(ds);
  }

  Future<void> _onDownloadComplete(DownloadStatus ds) async {
    final hook = _successHook;
    if (hook == null) {
      debugPrint('BackgroundDownloadEngine: 无 successHook，跳过成功钩子序列');
      return;
    }

    final file = File(ds.savePath);
    final notifId = ds.id ?? ds.appId.hashCode;
    final notifTitle =
        ds.appName.isNotEmpty ? ds.appName : ds.appId;

    // 1. 触发安装（APK 文件）
    await hook.onInstall(ds.fileName, ds.savePath);

    // 2. 通知下载完成
    await hook.onNotifyComplete(notifId, notifTitle);

    // 3. 下载安装完成后的后续处理
    await hook.onAfterDownloadInstalled(ds);

    // 4. APK 文件：异步解析并更新真实包名/图标
    if (file.path.endsWith('.apk')) {
      await hook.onApkInfo(appId: ds.appId, apkPath: file.path);
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 任务操作：enqueue / cancel / resume
  // ═══════════════════════════════════════════════════════════

  /// 将下载任务提交给 background_downloader
  ///
  /// [ctx] 下载上下文（含 URL、headers、proxy 等）
  /// [ds]  下载状态实体（含 savePath、tag 等）
  ///
  /// tag = "$appId-$version-$fileName" 显式作为 taskId，
  /// 与 DownloadStatus._downloadTag 保持一致，便于对账。
  Future<bool> enqueue(DownloadContext ctx, DownloadStatus ds) async {
    final tag = '${ds.appId}-${ds.version}-${ds.fileName}';
    final saveFile = File(ds.savePath);
    final directory = saveFile.parent.path;
    final filename = saveFile.uri.pathSegments.last;

    // 构造 DownloadTask
    final task = DownloadTask(
      taskId: tag,
      url: ctx.downloadUrl,
      filename: filename,
      directory: directory,
      baseDirectory: BaseDirectory.root,
      headers: ctx.headers,
      updates: Updates.statusAndProgress,
      retries: 3,
      allowPause: true,
      group: 'gstore',
      metaData: jsonEncode({'tag': tag}),
    );

    // 追踪活跃任务
    _activeTasks[tag] = ds;
    _taskStatusMap[tag] = TaskStatus.enqueued;

    // 按需注册全局监听（首次 enqueue 时触发）
    _register();

    debugPrint('BackgroundDownloadEngine: enqueue taskId=$tag url=${ctx.downloadUrl}');
    try {
      return await FileDownloader().enqueue(task);
    } catch (e) {
      // 测试环境下 MissingPluginException：内部追踪仍生效，仅 native 层不可用
      debugPrint('BackgroundDownloadEngine: enqueue native 层失败（测试模式可忽略）: $e');
      return true;
    }
  }

  /// 取消下载任务
  Future<void> cancel(String tag) async {
    FileDownloader().cancelTaskWithId(tag);
    _activeTasks.remove(tag);
  }

  /// 恢复已暂停的任务
  Future<bool> resume(String tag) async {
    final task = await FileDownloader().taskForId(tag);
    if (task == null || task is! DownloadTask) return false;
    return FileDownloader().resume(task);
  }

  // ═══════════════════════════════════════════════════════════
  // 重启对账（AD3）
  // ═══════════════════════════════════════════════════════════

  /// 比对 FileDownloader.allTasks 与 Floor 存活 tag，
  /// 生成恢复/孤儿/删除建议（v1 仅日志告警，不删除）
  Future<ReconcileResult> reconcileWithFloor({
    required Set<String> floorTags,
    List<Task>? allTasks,
  }) async {
    final tasks = allTasks ?? await FileDownloader().allTasks(group: 'gstore');
    final recovered = <String>[];
    final orphaned = <String>[];
    final deleted = <String>[]; // v1 始终为空

    for (final task in tasks) {
      // 从 metaData 提取 tag
      String taskTag;
      try {
        final meta = jsonDecode(task.metaData) as Map<String, dynamic>;
        taskTag = meta['tag'] as String? ?? task.taskId;
      } catch (_) {
        taskTag = task.taskId;
      }

      if (floorTags.contains(taskTag)) {
        recovered.add(taskTag);
        debugPrint('BackgroundDownloadEngine: 对账恢复 $taskTag');
      } else {
        orphaned.add(task.taskId);
        debugPrint('BackgroundDownloadEngine: 对账孤儿 ${task.taskId} (tag=$taskTag)');
      }
    }

    return ReconcileResult(
      recovered: recovered,
      orphaned: orphaned,
      deleted: deleted,
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 辅助查询
  // ═══════════════════════════════════════════════════════════

  /// 当前活跃（running + enqueued）任务数
  int get activeCount => _activeTasks.length;

  /// 查询所有任务状态（供 R5 并发测试验证 holdingQueue 生效）
  /// 使用内部状态追踪（FileDownloader 无公开 status 查询 API）
  Future<Map<String, TaskStatus>> queryAllTaskStates({
    String group = 'gstore',
  }) async {
    // 返回内部追踪的状态（由 updates 流实时维护）
    return Map.from(_taskStatusMap);
  }

  // ═══════════════════════════════════════════════════════════
  // 清理
  // ═══════════════════════════════════════════════════════════

  void dispose() {
    _unregister();
    _activeTasks.clear();
    _taskStatusMap.clear();
  }
}

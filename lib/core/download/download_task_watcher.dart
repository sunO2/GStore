import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/download_notification_service.dart';
import 'package:gstore/core/service/install_manager.dart';

/// 统一监听**所有**下载任务，驱动「通知栏进度」与「下载完自动安装」。
///
/// 为什么要有这一层：这两件事原来都写死在 Dart 版 `DownloadManager` 内部
/// （传输回调里直接调通知服务、完成后调 `onApkReady`）。换成 Rust 内核后
/// **通知与自动安装会一起失效**。改为从 [IDownloadService.watchAll] 这个
/// 全局任务流驱动，两种内核就都覆盖到了。
///
/// Dart 内核的 [DownloadManager.watchAll] 返回**空流**——它已经自己发过通知了，
/// 这里再发一次会重复弹两条。
class DownloadTaskWatcher {
  DownloadTaskWatcher._();

  static final DownloadTaskWatcher instance = DownloadTaskWatcher._();

  /// 测试专用：另建独立实例，避免单例状态在用例间串扰。
  @visibleForTesting
  DownloadTaskWatcher.debug();

  StreamSubscription<DownloadTask>? _sub;

  /// 当前绑定的实现。用于识别"重复绑定同一实现"（见 [start]）。
  IDownloadService? _service;

  /// 已经发过"开始"通知的任务（避免每条进度都重建通知）
  final Set<int> _started = {};

  /// 测试专用：实际建立订阅的次数（证明解析换源后不重绑）。
  @visibleForTesting
  int debugStartCount = 0;

  /// 测试专用：当前已发过"开始"通知的任务 id 快照（证明未被 `clear`）。
  @visibleForTesting
  Set<int> get debugStartedIds => Set<int>.unmodifiable(_started);

  /// 绑定到某个下载实现。
  ///
  /// [LazyDownloadService.watchAll] 是"先 Dart、解析后原地切 Rust"的**单条长期流**，
  /// 所以同一个实现重复调用 [start] 是空操作——既不重订阅，也不清空已发过的
  /// "开始"通知标记；只有换成**另一个**实现时才替换订阅（模块真正重绑内核的场景）。
  void start(IDownloadService service) {
    if (identical(_service, service) && _sub != null) {
      debugPrint('DownloadTaskWatcher: 同一实现已订阅，跳过重绑');
      return;
    }
    debugStartCount++;
    _service = service;
    // 旧订阅取消是 fire-and-forget：显式 unawaited，表明"不阻塞重绑"的意图。
    unawaited(_sub?.cancel());
    _started.clear();
    _sub = service.watchAll().listen(
      _onUpdate,
      onError: (Object e) => debugPrint('DownloadTaskWatcher: 任务流异常 - $e'),
    );
    debugPrint('DownloadTaskWatcher: 已订阅全局任务流');
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
    _service = null;
  }

  void _onUpdate(DownloadTask task) {
    final id = task.id;
    if (id == null) return;
    final title = task.appName.isNotEmpty ? task.appName : task.appId;
    final notif = DownloadNotificationService.instance;

    switch (task.status) {
      case DownloadStatusEnum.queued:
      case DownloadStatusEnum.connecting:
      case DownloadStatusEnum.downloading:
        if (_started.add(id)) {
          notif.onDownloadStart(id, title, task.fileName);
        }
        // 服务内部已做 500ms 节流
        notif.onDownloadProgress(id, title, task.fileName, task.received, task.total);
      case DownloadStatusEnum.paused:
        break;
      case DownloadStatusEnum.completed:
        notif.onDownloadComplete(id);
        _started.remove(id);
        // 自动安装只认任务自己持久化的标记（跨重启也有效）
        if (task.installAfterDownload) _install(task.filePath);
      case DownloadStatusEnum.failed:
        notif.onDownloadError(id, title);
        _started.remove(id);
      case DownloadStatusEnum.cancelled:
        notif.onDownloadCancel(id);
        _started.remove(id);
    }
  }

  void _install(String filePath) {
    final manager = ModuleManager.instance.get<InstallManager>();
    if (manager == null) {
      debugPrint('DownloadTaskWatcher: InstallManager 不可用，跳过自动安装');
      return;
    }
    debugPrint('DownloadTaskWatcher: 下载完成，触发安装 $filePath');
    // 安装失败（如安装器抛异常）不得成为未处理的异步错误：在独立任务里捕获并上报。
    unawaited(_installQuietly(manager, filePath));
  }

  /// 执行自动安装并吞掉异常（含堆栈上报），避免 `unawaited` 产生未处理异步错误。
  Future<void> _installQuietly(InstallManager manager, String filePath) async {
    try {
      await manager.installApk(filePath);
    } catch (e, st) {
      debugPrint('DownloadTaskWatcher: 自动安装失败 $filePath - $e\n$st');
    }
  }
}

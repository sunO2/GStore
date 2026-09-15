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

  StreamSubscription<DownloadTask>? _sub;

  /// 已经发过"开始"通知的任务（避免每条进度都重建通知）
  final Set<int> _started = {};

  /// 绑定到某个下载实现。重复调用会替换订阅。
  void start(IDownloadService service) {
    _sub?.cancel();
    _started.clear();
    _sub = service.watchAll().listen(
      _onUpdate,
      onError: (Object e) => debugPrint('DownloadTaskWatcher: 任务流异常 - $e'),
    );
    debugPrint('DownloadTaskWatcher: 已订阅全局任务流');
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
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
    unawaited(Future<void>(() => manager.installApk(filePath)));
  }
}

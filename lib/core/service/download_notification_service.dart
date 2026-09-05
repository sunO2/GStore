import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';

/// 下载通知服务
/// 职责：
/// - flutter_local_notifications：每个下载任务的进度通知（通知栏可见进度）
/// - flutter_foreground_task：前台服务，保持进程存活使下载在后台继续运行
///
/// 注意：此服务仅在任务进入 LOADING 状态后才会被调用（通过
/// DownloadService._performDownload()）。QUEUED 状态的任务不会
/// 触发任何通知，因为它们尚未获取下载信号量。
class DownloadNotificationService {
  DownloadNotificationService._();

  static final DownloadNotificationService instance =
      DownloadNotificationService._();

  /// 下载进度通知渠道
  static const String _channelId = 'download_progress';
  static const String _channelName = '下载任务';

  /// 前台服务 ID
  static const int _foregroundServiceId = 997;

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// 活跃下载数（用于前台服务启停）
  int _activeDownloads = 0;

  /// 进度通知节流（避免高频刷新）
  final Map<int, DateTime> _lastNotify = {};

  /// 初始化（应用启动时调用）
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      // flutter_local_notifications
      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher_foreground'),
        ),
        onDidReceiveNotificationResponse: (response) {
          // 点击进度通知跳转下载中心
          if (response.payload == 'download_center') {
            try {
              appRouter.push(AppRoute.downloadCenter);
            } catch (e) {
              appLog.error('DownloadNotificationService: 跳转下载中心失败 - $e');
            }
          }
        },
      );

      // 创建通知渠道
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: '下载任务进度通知',
              importance: Importance.low,
            ),
          );

      // flutter_foreground_task 配置
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'foreground_service',
          channelName: '后台下载',
          channelDescription: '保持后台下载运行',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
        ),
      );
    } catch (e) {
      appLog.error('DownloadNotificationService: 初始化失败 - $e');
    }
  }

  /// 请求通知权限（Android 13+ 必需）
  Future<void> requestPermission() async {
    await init();
    try {
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      appLog.error('DownloadNotificationService: 请求通知权限失败 - $e');
    }
  }

  /// 安全执行通知操作：同步与异步错误都兜住，通知失败绝不影响下载流程。
  /// （单元测试等无 Flutter binding 环境下，插件 Future 会以异步错误抛出）
  void _safeNotify(Future<void> Function() action) {
    try {
      unawaited(action().catchError((Object e) {
        appLog.error('DownloadNotificationService: 通知操作失败 - $e');
      }));
    } catch (e) {
      appLog.error('DownloadNotificationService: 通知操作失败 - $e');
    }
  }

  // ==================== 任务进度通知 ====================

  /// 下载开始
  void onDownloadStart(int id, String title, String fileName) {
    _activeDownloads++;
    _showProgress(id, title, fileName, 0, 0);
    startForegroundService();
  }

  /// 下载进度（节流更新）
  void onDownloadProgress(
    int id,
    String title,
    String fileName,
    int count,
    int total,
  ) {
    final now = DateTime.now();
    final last = _lastNotify[id];
    if (last != null && now.difference(last).inMilliseconds < 500) return;
    _lastNotify[id] = now;
    _showProgress(id, title, fileName, count, total);
  }

  /// 下载完成（移除进度通知）
  void onDownloadComplete(int id) {
    _lastNotify.remove(id);
    _activeDownloads = (_activeDownloads - 1) < 0 ? 0 : _activeDownloads - 1;
    _safeNotify(() => _local.cancel(id: id));
    _stopIfIdle();
  }

  /// 下载失败（显示失败通知）
  void onDownloadError(int id, String title) {
    _lastNotify.remove(id);
    _activeDownloads = (_activeDownloads - 1) < 0 ? 0 : _activeDownloads - 1;
    _safeNotify(() => _local.show(
          id: id,
          title: '下载失败',
          body: title,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              importance: Importance.high,
              priority: Priority.high,
              autoCancel: true,
            ),
          ),
        ));
    _stopIfIdle();
  }

  /// 下载取消（移除通知）
  void onDownloadCancel(int id) {
    _lastNotify.remove(id);
    _activeDownloads = (_activeDownloads - 1) < 0 ? 0 : _activeDownloads - 1;
    _safeNotify(() => _local.cancel(id: id));
    _stopIfIdle();
  }

  /// 显示/更新进度通知
  void _showProgress(
    int id,
    String title,
    String fileName,
    int count,
    int total,
  ) {
    final percent = total > 0 ? (count / total * 100).round() : 0;
    _safeNotify(() => _local.show(
          id: id,
          title: title,
          body: '下载中 $percent% · $fileName',
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              importance: Importance.low,
              priority: Priority.low,
              onlyAlertOnce: true,
              showProgress: true,
              progress: total > 0 ? count : 0,
              maxProgress: total > 0 ? total : 0,
              indeterminate: total <= 0,
              autoCancel: false,
            ),
          ),
          payload: 'download_center',
        ));
  }

  // ==================== 前台服务（后台保活）====================

  /// 启动前台服务（保持进程，下载后台继续）
  Future<void> startForegroundService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceId: _foregroundServiceId,
        notificationTitle: '后台下载中',
        notificationText: 'GStore 正在后台下载应用',
        notificationInitialRoute: AppRoute.downloadCenter,
        callback: downloadForegroundTaskCallback,
      );
    } catch (e) {
      appLog.error('DownloadNotificationService: 启动前台服务失败 - $e');
    }
  }

  /// 无活动下载时停止前台服务
  void _stopIfIdle() {
    if (_activeDownloads <= 0) {
      _activeDownloads = 0;
      _stopForegroundService();
    }
  }

  Future<void> _stopForegroundService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      appLog.error('DownloadNotificationService: 停止前台服务失败 - $e');
    }
  }
}

/// 前台服务后台 isolate 入口
/// 仅用于保活进程，具体下载由主 isolate 的 DownloadService 执行
@pragma('vm:entry-point')
void downloadForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_DownloadForegroundTaskHandler());
}

/// 空任务处理器（保活用）
class _DownloadForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}

  @override
  void onNotificationDismissed() {}
}

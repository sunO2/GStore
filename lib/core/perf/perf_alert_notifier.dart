/// 性能告警的 Flutter 出口实现（应用内横幅 + 系统通知）。
///
/// * 横幅复用项目统一入口 [AppDialogs.showWarning]（Snackbar，经全局
///   `scaffoldMessengerKey`；测试宿主无 key 时静默 no-op，绝不抛错）；
/// * 系统通知复用既有 `flutter_local_notifications` 依赖，channel / id 空间独立
///   （`gstore_perf_alerts`，与下载 / 代理 / AI 助手隔离），初始化与渠道创建
///   沿用既有通知服务的模式（见 `proxy_status_notification.dart`）。
///
/// 本文件是唯一带 Flutter 依赖的告警文件；[evaluate] / [PerfAlertDispatcher]
/// 保持在 `perf_alert_service.dart` 中纯净、可单测。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/perf/perf_alert_service.dart';

/// 生产告警出口：Snackbar 横幅 + `flutter_local_notifications` 通知。
class LocalPerfAlertNotifier implements PerfAlertNotifier {
  /// 通知 id 基础（每种 kind 一条，与其它服务的 id 空间隔离）。
  static const int notificationIdBase = 900;

  /// 独立渠道 id。
  static const String channelId = 'gstore_perf_alerts';
  static const String channelName = '性能告警';

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// 初始化插件与通知渠道（幂等；失败只记日志）。
  Future<void> init() async {
    if (_initialized) return;
    try {
      await _local.initialize(
        settings: const InitializationSettings(
          android:
              AndroidInitializationSettings('@mipmap/ic_launcher_foreground'),
        ),
      );
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              channelId,
              channelName,
              description: '性能阈值告警（CPU / 温度 / Jank / 帧率）',
              importance: Importance.high,
            ),
          );
      _initialized = true;
    } catch (error) {
      debugPrint('[PerfAlertNotifier] 初始化失败: $error');
    }
  }

  /// 请求通知权限（Android 13+ 的 POST_NOTIFICATIONS）；best-effort。
  Future<void> requestPermission() async {
    try {
      await init();
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (error) {
      debugPrint('[PerfAlertNotifier] 请求通知权限失败: $error');
    }
  }

  @override
  Future<void> showBanner(PerfAlert alert) async {
    try {
      AppDialogs.showWarning(alert.message, title: '性能告警');
    } catch (error) {
      debugPrint('[PerfAlertNotifier] 展示横幅失败: $error');
    }
  }

  @override
  Future<void> notify(PerfAlert alert) async {
    try {
      await init();
      await _local.show(
        id: notificationIdBase + alert.kind.index,
        title: '性能告警',
        body: alert.message,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            importance: Importance.high,
            priority: Priority.high,
            autoCancel: true,
          ),
        ),
      );
    } catch (error) {
      debugPrint('[PerfAlertNotifier] 推送通知失败: $error');
    }
  }
}

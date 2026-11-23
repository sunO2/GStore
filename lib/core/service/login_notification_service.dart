import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gstore/core/core.dart';

/// GitHub 登录轮询通知服务
///
/// - flutter_local_notifications：通知栏显示验证码（前台通知，持续显示）；
/// - flutter_foreground_task：前台服务，保持进程存活（用户去 GitHub 浏览
///   时轮询继续，不会被系统杀后台）。
class LoginNotificationService {
  LoginNotificationService._();

  static final LoginNotificationService instance = LoginNotificationService._();

  /// 通知渠道
  static const String _channelId = 'login_poll';
  static const String _channelName = 'GitHub 登录';

  /// 通知 ID
  static const int _notificationId = 998;

  /// 前台服务 ID
  static const int _foregroundServiceId = 998;

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// 上次写入通知栏的验证码（更新进度时保持可见）
  String _lastCode = '';

  @visibleForTesting
  static int debugPostCount = 0;

  @visibleForTesting
  void debugResetForTest() {
    debugPostCount = 0;
  }

  /// 通知细节（前台通知：持续显示，不可滑动关闭）
  static const NotificationDetails _notificationDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
    ),
  );

  /// 初始化（幂等）
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _local.initialize(
        settings: const InitializationSettings(
          android:
              AndroidInitializationSettings('@mipmap/ic_launcher_foreground'),
        ),
      );

      // 创建通知渠道
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: 'GitHub 登录轮询进度通知',
              importance: Importance.low,
            ),
          );

      // flutter_foreground_task 配置（后台保活）
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'foreground_service',
          channelName: '后台 GitHub 登录',
          channelDescription: '保持 GitHub 登录轮询运行',
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
      appLog.error('LoginNotificationService: 初始化失败 - $e');
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
      appLog.error('LoginNotificationService: 请求通知权限失败 - $e');
    }
  }

  /// 安全执行通知操作：同步与异步错误都兜住，通知失败绝不影响登录流程。
  void _safeNotify(Future<void> Function() action) {
    try {
      unawaited(action().catchError((Object e) {
        appLog.error('LoginNotificationService: 通知操作失败 - $e');
      }));
    } catch (e) {
      appLog.error('LoginNotificationService: 通知操作失败 - $e');
    }
  }

  /// 显示登录轮询通知（验证码写入通知栏）
  void showLoginNotification(String code) {
    if (!_initialized) return;
    _lastCode = code;
    _safeNotify(() => _local.show(
          id: _notificationId,
          title: 'GitHub 登录',
          body: '验证码：$code（等待授权中）',
          notificationDetails: _notificationDetails,
          payload: 'login_poll',
        ));
  }

  /// 更新轮询进度（保持通知栏验证码，显示当前进度日志）
  void updatePollProgress(String log) {
    if (!_initialized) return;
    final body = _lastCode.isNotEmpty
        ? '验证码：$_lastCode—— $log'
        : log;
    _safeNotify(() => _local.show(
          id: _notificationId,
          body: body,
          notificationDetails: _notificationDetails,
          payload: 'login_poll',
        ));
  }

  /// 取消登录通知（登录成功/失败/取消时）
  void cancel() {
    if (!_initialized) return;
    _lastCode = '';
    _safeNotify(() => _local.cancel(id: _notificationId));
    _stopForegroundService();
  }

  /// 启动前台服务（保持进程存活）
  Future<void> startForegroundService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceId: _foregroundServiceId,
        notificationTitle: '后台 GitHub 登录',
        notificationText: 'GStore 正在后台进行 GitHub 登录轮询',
        notificationInitialRoute: AppRoute.auth,
        callback: loginForegroundTaskCallback,
      );
    } catch (e) {
      appLog.error('LoginNotificationService: 启动前台服务失败 - $e');
    }
  }

  Future<void> _stopForegroundService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      appLog.error('LoginNotificationService: 停止前台服务失败 - $e');
    }
  }
}

/// 前台服务后台 isolate 入口
@pragma('vm:entry-point')
void loginForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_LoginForegroundTaskHandler());
}

/// 前台服务后台任务处理器（保活用）
class _LoginForegroundTaskHandler extends TaskHandler {
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

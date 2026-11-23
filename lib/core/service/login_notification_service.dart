import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gstore/core/core.dart';

/// GitHub 登录轮询通知服务
///
/// - Android 16+：走原生 Live Updates（promoted ongoing notification），由
///   OPPO/荣耀/小米/vivo 等系统自行渲染成灵动岛/胶囊形态；
/// - 低版本：flutter_local_notifications 普通进度通知兜底；
/// - flutter_foreground_task：前台服务，保持进程存活（用户去 GitHub 浏览
///   时轮询继续，不会被系统杀后台）。
class LoginNotificationService {
  LoginNotificationService._();

  static final LoginNotificationService instance = LoginNotificationService._();

  /// 通知渠道
  static const String _channelId = 'login_poll';
  static const String _channelName = 'GitHub 登录';

  /// 验证码通知 ID（与前台服务通知 ID 区分，避免被服务通知覆盖）
  static const int _notificationId = 999;

  /// 前台服务 ID
  static const int _foregroundServiceId = 998;

  /// Android 16 Live Updates 原生通道（ProgressStyle + promoted ongoing）。
  static const MethodChannel _liveUpdateChannel =
      MethodChannel('gstore/login_live_update');

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Live Updates 是否可用（null 表示尚未探测）。
  bool? _liveUpdateSupported;

  /// 渲染序号：异步探测/调用返回时丢弃过期结果，避免进度条回跳。
  int _renderSeq = 0;

  /// 轮询日志回调（登录页用于把 Live Updates 能力/提升结果写进日志）。
  void Function(String message)? _onLog;

  /// Android SDK 版本（诊断日志展示）。
  int? _sdkInt;

  /// 本次验证码是否已输出过「支持/不支持」能力日志。
  bool _supportLogged = false;

  /// 上一次 Live Update 提升状态（避免每秒刷新时反复刷日志）。
  String? _lastLiveUpdateStatus;

  /// 当前验证码（通知标题展示）
  String _lastCode = '';

  /// 验证码有效期倒计时定时器（进度条）
  Timer? _countdownTimer;

  /// 验证码过期时间（null 表示无倒计时）
  DateTime? _expiresAt;

  /// 验证码总有效秒数（进度条分母）
  int _expiresInSeconds = 0;

  @visibleForTesting
  static int debugPostCount = 0;

  @visibleForTesting
  void debugResetForTest() {
    debugPostCount = 0;
  }

  /// 剩余有效秒数（已过期返回 0）
  int get _remainingSeconds {
    final expiresAt = _expiresAt;
    if (expiresAt == null) return 0;
    final remaining = expiresAt.difference(DateTime.now()).inSeconds;
    return remaining > 0 ? remaining : 0;
  }

  /// 剩余有效期百分比（0~100，用于通知栏进度条）
  int get _progressPercent {
    if (_expiresAt == null || _expiresInSeconds <= 0) return 0;
    return (_remainingSeconds * 100 / _expiresInSeconds)
        .round()
        .clamp(0, 100);
  }

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
              description: 'GitHub 设备验证码与有效期倒计时',
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

  /// 立即显示验证码通知，并用进度条呈现有效期倒计时。
  ///
  /// [expiresIn] 为验证码有效秒数（GitHub device/code 的 expires_in），
  /// 传入后每秒刷新一次进度条；为 null 时只显示静态通知。
  void showLoginNotification(
    String code, {
    int? expiresIn,
    void Function(String message)? onLog,
  }) {
    if (!_initialized) return;
    _onLog = onLog;
    _supportLogged = false;
    _lastLiveUpdateStatus = null;
    _lastCode = code;
    _expiresInSeconds = expiresIn ?? 0;
    _expiresAt = _expiresInSeconds > 0
        ? DateTime.now().add(Duration(seconds: _expiresInSeconds))
        : null;

    // 先立即渲染一次，不必等第一次轮询
    _renderNow();

    _countdownTimer?.cancel();
    _countdownTimer = null;
    if (_expiresAt == null) return;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _renderNow();
      if (_remainingSeconds <= 0) {
        _countdownTimer?.cancel();
        _countdownTimer = null;
      }
    });
  }

  /// 按当前平台能力选择渲染路径（Live Updates / 普通通知）。
  void _renderNow() {
    final seq = ++_renderSeq;
    unawaited(_renderNowAsync(seq));
  }

  Future<void> _renderNowAsync(int seq) async {
    final live = await _supportsLiveUpdate();
    if (seq != _renderSeq) return;
    if (live) {
      if (!_supportLogged) {
        _supportLogged = true;
        _log('Live Updates：支持（Android SDK ${_sdkInt ?? '?'}），尝试提升为实时通知');
      }
      await _renderLiveUpdate();
    } else {
      if (!_supportLogged) {
        _supportLogged = true;
        _log('Live Updates：不支持（Android SDK ${_sdkInt ?? '?'}），使用普通进度通知');
      }
      _renderLoginNotification();
    }
  }

  /// 探测 Android 16+ Live Updates 通道（结果缓存）。
  Future<bool> _supportsLiveUpdate() async {
    final cached = _liveUpdateSupported;
    if (cached != null) return cached;
    if (defaultTargetPlatform != TargetPlatform.android) {
      _liveUpdateSupported = false;
      return false;
    }
    try {
      final sdkInt = await _liveUpdateChannel.invokeMethod<int>('sdkInt');
      _sdkInt = sdkInt;
      final supported =
          await _liveUpdateChannel.invokeMethod<bool>('isSupported') ?? false;
      _liveUpdateSupported = supported;
      return supported;
    } catch (e) {
      // 通道缺失（测试/旧壳）时全部降级为普通通知。
      _liveUpdateSupported = false;
      return false;
    }
  }

  /// 通过原生 ProgressStyle 通知渲染（Android 16+，厂商系统自动映射为岛）。
  Future<void> _renderLiveUpdate() async {
    final expired = _expiresAt != null && _remainingSeconds <= 0;
    final remaining = _remainingSeconds;
    final shortText = expired
        ? '已过期'
        : '${(remaining ~/ 60).toString().padLeft(2, '0')}:'
            '${(remaining % 60).toString().padLeft(2, '0')}';
    try {
      final result = await _liveUpdateChannel.invokeMethod<Map<Object?, Object?>>(
        'show',
        {
          'title': '验证码：$_lastCode',
          'body': expired ? '验证码已过期，请重新获取' : '登录 GitHub 并输入设备验证码登录',
          'progress': _progressPercent,
          'shortText': shortText,
        },
      );
      final allowed = result?['allowed'] == true;
      final promoted = result?['promoted'] == true;
      final status = 'allowed=$allowed promoted=$promoted';
      if (status != _lastLiveUpdateStatus) {
        _lastLiveUpdateStatus = status;
        _log(
          'Live Update：系统允许实时通知=${allowed ? '是' : '否'}，'
          '已提升=${promoted ? '是' : '否'}'
          '${promoted ? '' : '（厂商未映射或用户未开启实时通知）'}',
        );
      }
    } catch (e) {
      appLog.error('LoginNotificationService: Live Update 通知失败 - $e');
    }
  }

  /// 写入登录页轮询日志（无回调时静默）。
  void _log(String message) {
    final onLog = _onLog;
    if (onLog == null) return;
    try {
      onLog(message);
    } catch (e) {
      appLog.error('LoginNotificationService: 写入轮询日志失败 - $e');
    }
  }

  /// 渲染验证码通知：标题为验证码，副标题为操作说明，进度条为剩余有效期。
  void _renderLoginNotification() {
    final expired = _expiresAt != null && _remainingSeconds <= 0;
    _safeNotify(() => _local.show(
          id: _notificationId,
          title: '验证码：$_lastCode',
          body: expired ? '验证码已过期，请重新获取' : '登录 GitHub 并输入设备验证码登录',
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              importance: Importance.low,
              priority: Priority.low,
              onlyAlertOnce: true,
              ongoing: true,
              autoCancel: false,
              showProgress: _expiresAt != null,
              maxProgress: 100,
              progress: _progressPercent,
              indeterminate: false,
              category: AndroidNotificationCategory.progress,
            ),
          ),
          payload: 'login_poll',
        ));
  }

  /// 取消登录通知（登录成功/失败/取消时）
  void cancel() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _expiresAt = null;
    _expiresInSeconds = 0;
    _lastCode = '';
    _onLog = null;
    _lastLiveUpdateStatus = null;
    _renderSeq++;
    if (!_initialized) return;
    _safeNotify(() => _local.cancel(id: _notificationId));
    // 原生 Live Update 与插件通知同 id；两条路径都取消，保证不残留。
    try {
      unawaited(_liveUpdateChannel.invokeMethod<bool>('cancel').then<void>(
        (_) {},
        onError: (Object e) {
          appLog.error('LoginNotificationService: 取消 Live Update 失败 - $e');
        },
      ));
    } catch (e) {
      appLog.error('LoginNotificationService: 取消 Live Update 失败 - $e');
    }
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

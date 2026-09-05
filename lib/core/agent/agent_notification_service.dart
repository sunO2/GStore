import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';

/// Agent 助手后台通知服务
///
/// 职责：AI 助手执行长任务（下载/备份/更新检查）或需要用户确认时，
/// 通过通知栏汇报进度与结果——**退出 AI 页面后仍可见可交互**。
///
/// 架构定位（B2/B3/B4）：
/// - 与 AgentService 解耦：页面销毁不影响执行，通知是"退出后感知"的通道
/// - 复用 flutter_local_notifications（与下载通知同插件，独立渠道）
/// - confirmAction 在页面不可见时升级为带按钮的通知（B3）
///
/// 安全护栏（B5）：本服务只汇报，不代用户做决定；
/// 敏感操作仍由 confirmAction 走用户确认（页面或通知按钮）。
class AgentNotificationService {
  AgentNotificationService._();

  static final AgentNotificationService instance =
      AgentNotificationService._();

  /// 通知渠道
  static const String _channelId = 'agent_assistant';
  static const String _channelName = 'AI 助手';

  /// 通知 ID 基础（下载/工具/确认分区，避免与下载中心 ID 冲突）
  static const int _idBase = 3000;
  static const int _confirmIdBase = 3100;

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// 进度节流
  final Map<int, DateTime> _lastNotify = {};

  /// 当前 agent 工具通知 ID 计数器
  int _notifySeq = 0;

  /// 初始化（首次使用时惰性初始化）
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher_foreground'),
        ),
        onDidReceiveNotificationResponse: (response) {
          _handleResponse(response);
        },
      );
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: 'AI 助手任务进度与确认通知',
              importance: Importance.low,
            ),
          );
    } catch (e) {
      appLog.error('AgentNotificationService: 初始化失败 - $e');
    }
  }

  /// 请求通知权限（Android 13+）
  Future<void> requestPermission() async {
    await init();
    try {
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      appLog.error('AgentNotificationService: 请求通知权限失败 - $e');
    }
  }

  /// 安全执行通知操作（通知失败绝不影响任务本身）
  void _safeNotify(Future<void> Function() action) {
    try {
      unawaited(action().catchError((Object e) {
        appLog.error('AgentNotificationService: 通知操作失败 - $e');
      }));
    } catch (e) {
      appLog.error('AgentNotificationService: 通知操作失败 - $e');
    }
  }

  /// 通知响应（点按跳 AI 页 / 确认按钮回写）
  void _handleResponse(NotificationResponse response) {
    final payload = response.payload ?? '';
    try {
      if (payload.startsWith('agent:confirm:')) {
        // 确认按钮：通知栏直接做出选择（回写 AgentService）
        final parts = payload.split('|');
        if (parts.length >= 3) {
          final msgId = parts[1];
          final choice = parts[2];
          final service = ModuleManager.instance.get<AgentService>();
          if (service != null) {
            service.resolveConfirmation(msgId, choice);
          }
        }
        return;
      }
      if (payload == 'agent:open') {
        appRouter.push(AppRoute.agent);
        return;
      }
      if (payload == 'download_center') {
        appRouter.push(AppRoute.downloadCenter);
        return;
      }
    } catch (e) {
      appLog.error('AgentNotificationService: 响应处理失败 - $e');
    }
  }

  // ==================== 工具进度通知（B2） ====================

  /// 工具执行阶段变化（如"下载中 45%"）——节流更新，避免高频刷新
  void onToolProgress({
    required String title,
    required String message,
    int? progress,
    int? maxProgress,
  }) {
    final id = _idBase + (_notifySeq % 100);
    final now = DateTime.now();
    final last = _lastNotify[id];
    if (last != null && now.difference(last).inMilliseconds < 800) return;
    _lastNotify[id] = now;
    _safeNotify(() => _local.show(
          id: id,
          title: title,
          body: message,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              importance: Importance.low,
              priority: Priority.low,
              onlyAlertOnce: true,
              showProgress: progress != null,
              progress: progress ?? 0,
              maxProgress: maxProgress ?? 0,
              indeterminate: progress == null,
              autoCancel: false,
            ),
          ),
          payload: 'agent:open',
        ));
  }

  /// 工具执行完成（成功/失败）——通知栏汇总
  void onToolDone({
    required bool success,
    required String message,
  }) {
    _notifySeq++;
    final id = _idBase + (_notifySeq % 100);
    _safeNotify(() => _local.show(
          id: id,
          title: success ? 'AI 助手 · 任务完成' : 'AI 助手 · 任务失败',
          body: message,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              importance: success ? Importance.low : Importance.high,
              priority: success ? Priority.low : Priority.high,
              autoCancel: true,
            ),
          ),
          payload: 'agent:open',
        ));
  }

  /// 清除指定工具通知
  void onToolCancel() {
    _notifySeq++;
    _safeNotify(() => _local.cancel(id: _idBase + (_notifySeq % 100)));
  }

  // ==================== 待确认通知（B3） ====================

  /// 页面不可见时，confirmAction 升级为带按钮的通知
  /// [multiSelect] 多选模式：通知栏无法逐项勾选，退化为"打开应用去选择"
  void onConfirmRequest({
    required String msgId,
    required String question,
    List<String>? options,
    bool multiSelect = false,
  }) {
    _notifySeq++;
    final id = _confirmIdBase + (_notifySeq % 10);
    final buttons = multiSelect
        ? [
            // 多选需应用内勾选 → 跳转 AI 页完成选择
            AndroidNotificationAction(
              'agent:open',
              '去选择',
              showsUserInterface: true,
            ),
          ]
        : options != null && options.isNotEmpty
            ? [
                for (final opt in options.take(3))
                  AndroidNotificationAction(
                    'agent:confirm:$msgId|$opt',
                    opt.length > 12 ? '${opt.substring(0, 12)}…' : opt,
                    showsUserInterface: false,
                  ),
              ]
            : [
                AndroidNotificationAction(
                  'agent:confirm:$msgId|确认',
                  '确认',
                  showsUserInterface: false,
                ),
                AndroidNotificationAction(
                  'agent:confirm:$msgId|取消',
                  '取消',
                  showsUserInterface: false,
                ),
              ];

    _safeNotify(() => _local.show(
          id: id,
          title: 'AI 助手需要确认',
          body: question,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              importance: Importance.high,
              priority: Priority.high,
              autoCancel: true,
              actions: buttons,
            ),
          ),
          payload: 'agent:open',
        ));
  }

  /// 取消待确认通知
  void onConfirmResolved() {
    _notifySeq++;
    _safeNotify(() => _local.cancel(id: _confirmIdBase + (_notifySeq % 10)));
  }
}
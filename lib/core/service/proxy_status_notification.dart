/// 代理运行状态通知服务（独立于 VPN 前台服务）。
///
/// 职责：以应用级单条常驻通知动态展示代理的：
/// * 当前上/下行速率（来自 `proxy.stats`，节流 ~1s）；
/// * 当前节点（`node.list.current` 优先，回退持久化选中节点 / stats outbound）；
/// * 当前订阅（`profile.list` + 持久化的选中 profile id；无显式选择时 Rust
///   默认用存储顺序第一个，这里同口径回退首个）；
/// * 代理模式（`proxy.state` / `proxy.mode` 事件）。
///
/// 设计要点：
/// * **不触碰 Rust/Kotlin**：只订阅 [ProxyModule.events] 并经既有门面调用读取
///   只读展示数据（`node.list` / `profile.list`），不新增任何 RPC。
/// * **不加载模块**：启动时仅挂载事件订阅，不做任何门面调用；模块只在引擎
///   事件到达（即用户已使用代理）后才被读取，避免违反「按需安装」门禁。
/// * **可注入/可测**：事件流、门面读取、通知出口、时钟与节流窗口全部可注入，
///   单元测试无需 Flutter binding 或原生模块。
/// * **best-effort**：任何一环失败（模块不可用 / 通知权限缺失 / 存储异常）都
///   只记录日志，绝不向上抛错，更不影响应用启动。
library;

import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/page/proxy/proxy_active_node_store.dart';
import 'package:gstore/page/proxy/proxy_active_profile_store.dart';

// ==================== 人类可读速率 ====================

/// 把字节/秒格式化为人类可读的速率（复用项目 [byteSize] 口径）。
///
/// 例：`0` → `0 B/s`；`512` → `512 B/s`；`1536` → `1.50 KB/s`；
/// `2 * 1024 * 1024` → `2.00 MB/s`。负值归零（速率无意义）。
String formatProxySpeed(int bytesPerSecond) {
  if (bytesPerSecond <= 0) return '0 B/s';
  return '${byteSize(bytesPerSecond)}/s';
}

// ==================== 注入接缝 ====================

/// 通知出口接缝：生产走 `flutter_local_notifications`，测试注入 spy。
abstract class ProxyStatusNotifier {
  /// 初始化插件与通知渠道（幂等）。
  Future<void> init();

  /// 请求通知权限（Android 13+ 的 POST_NOTIFICATIONS）。
  ///
  /// 在代理启动（引擎进入运行态）时调用一次，使常驻状态通知能够展示。
  /// best-effort：失败只记录日志，不抛错。
  Future<void> requestPermission();

  /// 展示/刷新固定 id 的常驻状态通知。
  ///
  /// [body] 为折叠态正文（Android 仅单行展示）；[subText] 为副标题
  /// （如代理模式）；[lines] 为展开态（InboxStyle）逐行内容，最多取前 5 条。
  /// 三者皆 best-effort，实现可忽略无法呈现的字段。
  Future<void> show({
    required String title,
    required String body,
    String? subText,
    List<String>? lines,
  });

  /// 取消状态通知。
  Future<void> cancel();
}

/// 代理只读数据来源接缝：生产转发 [ProxyModule]，测试注入假实现。
abstract class ProxyStatusSource {
  /// 类型化代理事件流。
  Stream<ProxyEvent> get events;

  /// `node.list`：各代理组实时选中 + 当前路由分组 + 引擎是否运行。
  Future<NodeListResult> nodeList();

  /// `profile.list`：稳定排序的订阅摘要。
  Future<ProfileList> profileList();
}

/// 生产实现：转发冻结的 [ProxyModule] 单例（不在构造期触碰 FFI）。
class ProxyModuleProxyStatusSource implements ProxyStatusSource {
  ProxyModuleProxyStatusSource([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Stream<ProxyEvent> get events => _module.events;

  @override
  Future<NodeListResult> nodeList() => _module.nodeList();

  @override
  Future<ProfileList> profileList() => _module.profileList();
}

// ==================== 生产通知实现 ====================

/// 基于 `flutter_local_notifications` 的常驻代理状态通知。
///
/// channel：`gstore_proxy_status`（IMPORTANCE_LOW）；固定 id [notificationId]；
/// `ongoing: true` + `onlyAlertOnce: true` + `autoCancel: false` → 静默常驻、
/// 内容原地更新，不与 [DownloadNotificationService] 的渠道/通知互相干扰。
class LocalProxyStatusNotifier implements ProxyStatusNotifier {
  /// 固定通知 id（与下载进度通知的 id 空间隔离）。
  static const int notificationId = 998;

  /// 独立渠道 id。
  static const String channelId = 'gstore_proxy_status';
  static const String channelName = '代理状态';

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  @override
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
              description: '代理运行状态（速率 / 节点 / 订阅 / 模式）',
              importance: Importance.low,
            ),
          );
      _initialized = true;
    } catch (e) {
      appLog.error('LocalProxyStatusNotifier: 初始化失败 - $e');
    }
  }

  @override
  Future<void> requestPermission() async {
    try {
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      appLog.error('ProxyStatusNotificationService: 请求通知权限失败 - $e');
    }
  }

  @override
  Future<void> show({
    required String title,
    required String body,
    String? subText,
    List<String>? lines,
  }) async {
    await init();
    // 展开态 InboxStyle：最多 5 行；无行时保持纯正文，不设置 styleInformation。
    final style = (lines != null && lines.isNotEmpty)
        ? InboxStyleInformation(
            lines.take(5).toList(),
            contentTitle: title,
            summaryText: subText,
          )
        : null;
    await _local.show(
      id: notificationId,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          onlyAlertOnce: true,
          autoCancel: false,
          showWhen: false,
          subText: subText,
          styleInformation: style,
        ),
      ),
    );
  }

  @override
  Future<void> cancel() async {
    if (!_initialized) return;
    await _local.cancel(id: notificationId);
  }
}

// ==================== 服务 ====================

/// 代理状态通知服务。
///
/// 生产入口：[instance]（应用启动时调用一次 [start]）。测试经构造函数注入
/// 假的 [ProxyStatusNotifier] / [ProxyStatusSource] / 存储 / 时钟，无需 binding。
class ProxyStatusNotificationService {
  ProxyStatusNotificationService({
    ProxyStatusNotifier? notifier,
    ProxyStatusSource? source,
    ProxyActiveProfileStore? profileStore,
    ProxyActiveNodeStore? nodeStore,
    DateTime Function()? clock,
    Duration speedThrottle = const Duration(seconds: 1),
    Duration infoThrottle = const Duration(seconds: 5),
  })  : _notifier = notifier ?? LocalProxyStatusNotifier(),
        _source = source ?? ProxyModuleProxyStatusSource(),
        _profileStore = profileStore ?? const ConfigStoreProxyActiveProfileStore(),
        _nodeStore = nodeStore ?? const ConfigStoreProxyActiveNodeStore(),
        _clock = clock ?? DateTime.now,
        _speedThrottle = speedThrottle,
        _infoThrottle = infoThrottle;

  /// 生产单例。
  static final ProxyStatusNotificationService instance =
      ProxyStatusNotificationService();

  static const String _title = 'GStore 代理';

  final ProxyStatusNotifier _notifier;
  final ProxyStatusSource _source;
  final ProxyActiveProfileStore _profileStore;
  final ProxyActiveNodeStore _nodeStore;
  final DateTime Function() _clock;
  final Duration _speedThrottle;
  final Duration _infoThrottle;

  StreamSubscription<ProxyEvent>? _sub;
  bool _started = false;
  bool _running = false;
  bool _shown = false;

  /// 本次代理会话是否已请求过通知权限（每次启动仅请求一次）。
  bool _permissionRequested = false;

  int _upBps = 0;
  int _downBps = 0;

  /// 累计上行 / 下行字节（来自 `proxy.stats` 的 uploadBytes/downloadBytes）。
  int _upTotal = 0;
  int _downTotal = 0;
  String _nodeName = '';
  String _subscriptionName = '';
  String? _currentOutbound;
  ProxyMode _mode = ProxyMode.unknown;

  DateTime? _lastNotifyAt;
  DateTime? _lastInfoAt;

  /// 是否已启用（测试/诊断用）。
  bool get isStarted => _started;

  /// 应用启动时调用一次：初始化通知渠道并挂载事件订阅。
  ///
  /// 幂等；整体 best-effort（初始化或订阅失败只记录日志，绝不抛错）。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await _notifier.init();
    } catch (e) {
      appLog.warning('ProxyStatusNotificationService: 通知初始化失败 - $e');
    }
    try {
      _sub = _source.events.listen(_onEvent, onError: _onEventError);
    } catch (e) {
      appLog.warning('ProxyStatusNotificationService: 事件订阅失败 - $e');
    }
  }

  /// 释放订阅并取消状态通知（测试/重置用）。
  Future<void> stop() async {
    _started = false;
    final sub = _sub;
    _sub = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (e) {
        appLog.warning('ProxyStatusNotificationService: 取消订阅失败 - $e');
      }
    }
    await _cancelNotification();
  }

  // ==================== 事件分发 ====================

  void _onEvent(ProxyEvent event) {
    switch (event) {
      case ProxyStatsEvent e:
        unawaited(_onStats(e));
      case ProxyStateEvent e:
        unawaited(_onState(e));
      case ProxyModeEvent e:
        _mode = e.mode;
        _maybeNotify(force: true);
      case ProxyConfigAppliedEvent _:
        unawaited(_onConfigApplied());
      default:
        break;
    }
  }

  void _onEventError(Object error) {
    appLog.warning('ProxyStatusNotificationService: 事件流错误 - $error');
  }

  /// `proxy.stats`：更新速率，节流刷新节点/订阅，再按 ~1s 地板刷新通知。
  Future<void> _onStats(ProxyStatsEvent event) async {
    _upBps = event.upBps;
    _downBps = event.downBps;
    _upTotal = event.uploadBytes;
    _downTotal = event.downloadBytes;
    if (event.topDomains.isNotEmpty) {
      final outbound = event.topDomains.first.outbound;
      if (outbound.isNotEmpty) _currentOutbound = outbound;
    }
    await _refreshInfo();
    _maybeNotify();
  }

  /// `proxy.state`：运行 → 事件驱动刷新并展示；非运行 → 取消通知。
  Future<void> _onState(ProxyStateEvent event) async {
    _running = event.isRunning;
    _mode = event.mode;
    if (!_running) {
      await _cancelNotification();
      return;
    }
    await _requestPermissionOnce();
    await _refreshInfo(force: true);
    _maybeNotify(force: true);
  }

  /// `proxy.config.applied`：配置热应用后订阅/节点可能变化，事件驱动刷新。
  Future<void> _onConfigApplied() async {
    await _refreshInfo(force: true);
    _maybeNotify(force: true);
  }

  /// 本次代理启动仅请求一次通知权限（best-effort，失败只记日志）。
  Future<void> _requestPermissionOnce() async {
    if (_permissionRequested) return;
    _permissionRequested = true;
    try {
      await _notifier.init();
      await _notifier.requestPermission();
    } catch (e) {
      appLog.error('ProxyStatusNotificationService: 请求通知权限失败 - $e');
    }
  }

  // ==================== 只读数据刷新 ====================

  /// 刷新订阅 + 节点；非运行态短路；非强制时受 [infoThrottle] 地板限制。
  Future<void> _refreshInfo({bool force = false}) async {
    if (!_running) return;
    final now = _clock();
    final last = _lastInfoAt;
    if (!force && last != null && now.difference(last) < _infoThrottle) {
      return;
    }
    _lastInfoAt = now;
    await _refreshSubscription();
    await _refreshNode();
  }

  /// 解析「当前订阅」：持久化选中 id 命中优先，否则回退首个
  ///（与 Rust「无显式 profileId 用存储顺序第一个」同口径）。
  Future<void> _refreshSubscription() async {
    try {
      final list = (await _source.profileList()).profiles;
      final persistedId = await _profileStore.read();
      ProfileSummary? selected;
      if (persistedId != null) {
        for (final profile in list) {
          if (profile.id == persistedId) {
            selected = profile;
            break;
          }
        }
      }
      selected ??= list.isEmpty ? null : list.first;
      _subscriptionName = selected?.name ?? '';
    } catch (e) {
      appLog.debug('ProxyStatusNotificationService: 读取订阅失败 - $e');
    }
  }

  /// 解析「当前节点」：`node.list.current` 优先（叶子节点 > 实时出站），
  /// 引擎未上报时回退持久化选中节点，最后回退 stats outbound。
  Future<void> _refreshNode() async {
    try {
      final live = await _source.nodeList();
      if (live.engineRunning) {
        final current = live.current;
        if (current != null) {
          final leaf = current.node;
          if (leaf != null && leaf.isNotEmpty) {
            _nodeName = leaf;
            return;
          }
          final now = current.now;
          if (now != null && now.isNotEmpty) {
            _nodeName = now;
            return;
          }
        }
      }
    } catch (e) {
      appLog.debug('ProxyStatusNotificationService: 读取节点失败 - $e');
    }
    try {
      final active = await _nodeStore.read();
      if (active != null && active.node.isNotEmpty) {
        _nodeName = active.node;
        return;
      }
    } catch (_) {
      // best-effort：读取失败保持旧值。
    }
    final outbound = _currentOutbound;
    if (outbound != null && outbound.isNotEmpty) _nodeName = outbound;
  }

  // ==================== 通知 ====================

  /// 运行态下按 [speedThrottle] 地板刷新通知；[force] 绕过节流（事件驱动）。
  void _maybeNotify({bool force = false}) {
    if (!_running) return;
    final now = _clock();
    final last = _lastNotifyAt;
    if (!force && last != null && now.difference(last) < _speedThrottle) {
      return;
    }
    _lastNotifyAt = now;
    _shown = true;
    unawaited(_safeShow());
  }

  Future<void> _safeShow() async {
    try {
      await _notifier.show(
        title: _title,
        body: _body,
        subText: _modeLabel(_mode),
        lines: _lines,
      );
    } catch (e) {
      appLog.error('ProxyStatusNotificationService: 展示通知失败 - $e');
    }
  }

  Future<void> _cancelNotification() async {
    // 代理停止：本次会话结束，下一次启动需重新请求权限。
    _permissionRequested = false;
    // 未展示过则无需取消（也避免无谓的平台调用）。
    if (!_shown) {
      _lastNotifyAt = null;
      _lastInfoAt = null;
      return;
    }
    _shown = false;
    _lastNotifyAt = null;
    _lastInfoAt = null;
    try {
      await _notifier.cancel();
    } catch (e) {
      appLog.error('ProxyStatusNotificationService: 取消通知失败 - $e');
    }
  }

  /// 折叠态正文：仅实时速率（Android contentText 单行展示，不可含 `\n`）。
  String get _body =>
      '↑ ${formatProxySpeed(_upBps)}  ↓ ${formatProxySpeed(_downBps)}';

  /// 展开态（InboxStyle）四行：实时 / 累计 / 订阅 / 节点。
  List<String> get _lines {
    final node = _nodeName.isEmpty ? '自动' : _nodeName;
    final subscription =
        _subscriptionName.isEmpty ? '未选择订阅' : _subscriptionName;
    return <String>[
      '实时  ↑ ${formatProxySpeed(_upBps)}  ↓ ${formatProxySpeed(_downBps)}',
      '累计  ↑ ${byteSize(_upTotal)}  ↓ ${byteSize(_downTotal)}',
      '订阅  $subscription',
      '节点  $node',
    ];
  }

  String _modeLabel(ProxyMode mode) => switch (mode) {
        ProxyMode.off => '关闭',
        ProxyMode.vpn => 'VPN',
        ProxyMode.lanProxy => '局域网代理',
        ProxyMode.unknown => '未知',
      };
}

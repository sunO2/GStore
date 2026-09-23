/// 快捷设置磁贴「连接」意图桥（UI 无关，依赖全部注入）。
///
/// Android 快捷设置磁贴（[ProxyTileService]）在未运行时不会直接起前台服务，而是
/// 拉起 `MainActivity` 并携带 `ACTION_PROXY_CONNECT`；原生侧据此置位一次性请求
/// 标志。本桥负责在**冷启动**与**每次回到前台**（[AppLifecycleState.resumed]）
/// 消费该请求，命中则调用注入的 `onConnectRequested`，由调用方复用首页同款
/// [ProxyConnectController] 连接编排（prepare → core.start → 路由重放）——磁贴与
/// 首页因此走**完全同一**连接流程。
///
/// * [start]：注册 [WidgetsBindingObserver] 并立即做一次冷启动消费；
/// * [handleAppResumed]：真正的纯逻辑（消费一次 → 命中才回调），可脱离
///   [WidgetsBinding] 单测；带**重入保护**，重叠的 resumed 事件绝不重复连接；
/// * [dispose]：注销观察者。
///
/// 所有异常都被吞掉并 `debugPrint` 记录：磁贴触发的连接失败绝不允许崩溃 App。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

/// 消费一次「磁贴连接请求」：返回是否存在待处理请求（并在原生侧清除）。
typedef ProxyConnectRequestConsumer = Future<bool> Function();

/// 磁贴连接请求被消费到时的回调（复用首页连接编排）。
typedef ProxyConnectRequestHandler = Future<void> Function();

/// 消费「快捷设置磁贴连接请求」并触发连接的回前台意图桥。
class ProxyConnectIntentBridge with WidgetsBindingObserver {
  ProxyConnectIntentBridge({
    required ProxyConnectRequestConsumer consumeRequest,
    required ProxyConnectRequestHandler onConnectRequested,
  })  : _consumeRequest = consumeRequest,
        _onConnectRequested = onConnectRequested;

  final ProxyConnectRequestConsumer _consumeRequest;
  final ProxyConnectRequestHandler _onConnectRequested;

  /// [start] 是否已执行（幂等，避免重复注册观察者）。
  bool _started = false;

  /// 重入保护：消费 / 回调进行中时，重叠的 [handleAppResumed] 直接返回。
  bool _handling = false;

  /// 注册生命周期观察者，并立即执行一次冷启动消费。
  ///
  /// 幂等：重复调用不重复注册。cold-start 消费以 `unawaited` 触发（best-effort，
  /// 不阻塞启动）。
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(handleAppResumed());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(handleAppResumed());
    }
  }

  /// 纯逻辑：消费一次磁贴请求；命中才回调 [ProxyConnectRequestHandler]。
  ///
  /// 重入保护：进行中的调用未结束时再次进入直接返回，保证重叠 resumed 事件
  /// 不会重复连接。所有异常（消费或连接失败）均被吞掉并记录，绝不抛出。
  Future<void> handleAppResumed() async {
    if (_handling) return;
    _handling = true;
    try {
      final requested = await _consumeRequest();
      if (requested) {
        await _onConnectRequested();
      }
    } catch (error, stack) {
      debugPrint(
        '[ProxyConnectIntentBridge] 处理磁贴连接请求失败（已忽略）: '
        '$error\n$stack',
      );
    } finally {
      _handling = false;
    }
  }

  /// 注销生命周期观察者。未 [start] 时安全 no-op。
  void dispose() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
  }
}

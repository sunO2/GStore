/// 安装回前台校验桥（UI 无关，依赖注入）。
///
/// 系统安装器在前台运行时，Android 会拦截发往后台应用的隐式
/// `PACKAGE_ADDED` / `PACKAGE_REPLACED` 广播（on-device：
/// `BroadcastQueue: Background execution not allowed`），`install_events` 因而
/// 可能永远收不到终端结果，`pending` 行会一直悬着直到超时。本桥在应用回到前台
/// （用户从安装器返回）时，调用注入的 [onResumed] 对仍 `pending` 的安装做一次
/// 平台校验（目标包是否已按预期版本安装），命中即上报 `installed`。
///
/// * [start]：注册 [WidgetsBindingObserver]（幂等，重复调用不重复注册）；
/// * [handleAppResumed]：纯逻辑（带重入保护），可脱离 [WidgetsBinding] 单测；
/// * [dispose]：注销观察者。
///
/// 所有异常都被吞掉并 `debugPrint` 记录：回前台校验失败绝不允许崩溃 App。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

/// 回到前台时执行一次的校验回调（生产为 `InstallManager.recheckPendingInstalls`）。
typedef InstallResumeHandler = Future<void> Function();

/// 在 [AppLifecycleState.resumed] 触发安装平台校验的生命周期桥。
class InstallResumeBridge with WidgetsBindingObserver {
  InstallResumeBridge({required InstallResumeHandler onResumed})
      : _onResumed = onResumed;

  final InstallResumeHandler _onResumed;

  /// [start] 是否已执行（幂等，避免重复注册观察者）。
  bool _started = false;

  /// 重入保护：校验进行中时，重叠的 resumed 事件直接返回。
  bool _handling = false;

  /// 注册生命周期观察者。幂等：重复调用不重复注册。
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // dispose 之后即使有迟到的生命周期回调也不触发（观察者已注销）。
    if (!_started) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(handleAppResumed());
    }
  }

  /// 纯逻辑：带重入保护地执行一次校验；异常吞掉并记录，绝不抛出。
  Future<void> handleAppResumed() async {
    if (_handling) return;
    _handling = true;
    try {
      await _onResumed();
    } catch (error) {
      debugPrint('[InstallResumeBridge] 回前台安装校验失败（已忽略）: $error');
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

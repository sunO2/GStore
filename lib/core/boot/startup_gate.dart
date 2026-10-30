/// 首帧启动门：把「首帧之后才完成的昂贵启动装配」暴露成一个小开关，
/// 让首个 UI 帧先渲染真实页面骨架（列表 loading），而不是等装配完成后的白屏。
///
/// **默认关闭**（[_enabled] = false）：单元/组件测试从不调用 `main()`，
/// 门在测试里必须完全惰性 —— [isReady] 保持 false、[wait] 立即返回、
/// [isEnabled] 为 false，因此所有既有测试的分支与拆分前完全一致。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// 全局启动门（纯静态，无实例、无异步副作用）。
class StartupGate {
  StartupGate._();

  /// 是否启用门控。只有真正跑 `main()` 的生产路径会调用 [enable]。
  static bool _enabled = false;

  /// 首帧后的启动装配是否已完成。
  static bool _ready = false;

  static Completer<void>? _completer;

  /// 由 `main()` 在 `runApp` 之前调用，开启门控（之后 [wait]/[isReady] 才生效）。
  static void enable() {
    _enabled = true;
    _completer ??= Completer<void>();
  }

  /// 门控是否启用（测试中恒为 false）。
  static bool get isEnabled => _enabled;

  /// 首帧后的启动装配是否已完成。门未启用时恒为 false（测试不受影响）。
  static bool get isReady => _ready;

  /// 等待首帧后的启动装配完成。
  ///
  /// 门未启用或已完成 → 立即返回（零开销，测试与首帧后的调用都是同步完成）。
  static Future<void> wait() => (!_enabled || _ready)
      ? Future<void>.value()
      : (_completer ??= Completer<void>()).future;

  /// 标记启动装配完成；幂等，重复调用安全。
  static void complete() {
    _ready = true;
    final completer = _completer;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// 测试专用：恢复默认（关闭）状态，避免静态状态跨用例泄漏。
  @visibleForTesting
  static void resetForTests() {
    _enabled = false;
    _ready = false;
    _completer = null;
  }
}

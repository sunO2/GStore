/// 配置初始化
///
/// 负责把 Rust 配置客户端接入应用启动流程：建立 `ConfigStore` 的兼容后端，
/// 并让 `ConfigService` 从 Rust `ConfigApi.list()` 水合同步元数据。
///
/// **顺序约束**：必须在 `CoreBootstrap.start()` 成功创建 Rust `CoreApi` **之后**
/// 调用。`ConfigApi.init()` 依赖已初始化的核心；在核心就绪前调用会以明确的
/// [StateError] 失败（而不是静默降级或写入半初始化状态）。
library;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:gstore/core/logger/LogManager.dart' show appLog;

import 'config_service.dart';
import 'config_store.dart';

/// 一个初始化步骤（仅测试可注入，生产固定为真实实现）。
typedef ConfigInitializerStep = Future<void> Function();

/// 配置初始化器
///
/// 启动顺序假设（见 `lib/main.dart`）：`CoreBootstrap.start()` →
/// `ConfigInitializer.initialize()` → 模块注册/`ModuleToggleConfig.preApplyToggles`。
/// 只有 `ConfigApi` 就绪后，模块开关等配置读取才有权威数据。
class ConfigInitializer {
  ConfigInitializer._();

  /// 是否已初始化（幂等标记；初始化失败时保持 false，允许重试）。
  static bool _initialized = false;

  static ConfigInitializerStep _initializeStore = _defaultInitializeStore;
  static ConfigInitializerStep _ensureServiceReady = _defaultEnsureServiceReady;

  /// 测试观察初始化状态（仅测试用）。
  @visibleForTesting
  static bool get debugInitialized => _initialized;

  static Future<void> _defaultInitializeStore() =>
      ConfigStore.instance.initialize();

  /// 水合 `ConfigService`。原生桥缺失/核心未就绪时统一转为 [StateError]，
  /// 让失败在启动日志里是明确类型而不是不可分类的 FFI 异常。
  ///
  /// 只包装 [Exception]（桥/FFI 失败）。编程错误（[Error] 子类，如
  /// [ArgumentError]/[TypeError]）原样抛出，绝不被误标为桥错误；包装时保留
  /// 原始堆栈，便于定位真正的失败点。
  static Future<void> _defaultEnsureServiceReady() async {
    try {
      await ConfigService.instance.ensureReady();
    } on StateError {
      rethrow;
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        StateError(
          'ConfigInitializer: Rust ConfigApi 初始化失败'
          '（CoreApi/原生桥未就绪）: $error',
        ),
        stackTrace,
      );
    }
  }

  /// 注入初始化步骤（仅测试使用；未传的步骤恢复生产实现）。
  @visibleForTesting
  static void debugSetSteps({
    ConfigInitializerStep? initializeStore,
    ConfigInitializerStep? ensureServiceReady,
  }) {
    _initializeStore = initializeStore ?? _defaultInitializeStore;
    _ensureServiceReady = ensureServiceReady ?? _defaultEnsureServiceReady;
    _initialized = false;
  }

  /// 恢复生产步骤与幂等标记（仅测试使用）。
  @visibleForTesting
  static void debugReset() {
    _initializeStore = _defaultInitializeStore;
    _ensureServiceReady = _defaultEnsureServiceReady;
    _initialized = false;
  }

  /// 初始化配置管理系统
  ///
  /// 这应该在应用启动时调用，且必须晚于 `CoreBootstrap.start()`；在所有其他
  /// 配置读写/模块开关预置之前完成。重复调用为 no-op。
  static Future<void> initialize() async {
    // 幂等性检查
    if (_initialized) {
      debugPrint('ConfigInitializer: 已初始化，跳过重复初始化');
      return;
    }

    appLog.info('ConfigInitializer: 开始初始化 Rust 配置客户端');

    // 1) 建立 ConfigStore 兼容适配器后端（生产为 Rust 后端，测试为内存 fake）。
    await _initializeStore();

    // 2) 唯一调用 ConfigApi.init()/list() 的水合点：Rust 注册表 → 同步元数据。
    await _ensureServiceReady();

    _initialized = true;
    appLog.info('ConfigInitializer: Rust 配置客户端初始化完成 '
        '(共 ${ConfigService.instance.list().length} 项配置)');
  }
}

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:gstore/core/rust/generated/frb_generated.dart' show RustLib;

/// flutter_rust_bridge 全局初始化守卫（幂等 + 并发安全）
///
/// FRB 的 `RustLib.init()` 不允许重复调用；`FdroidRustRepoManager` 与
/// `QrRustDecoder` 等入口若各自持有独立初始化标志，先后调用会触发
/// "Should not initialize flutter_rust_bridge twice"。统一经此单例守卫。
class RustBridge {
  RustBridge._();

  static bool _initialized = false;
  static Future<void>? _pending;

  /// 测试专用：强制原生桥「不可用」（模拟无宿主 `.so` 的环境）。
  ///
  /// 默认 `false`，生产行为不变。测试宿主（Linux/CI）可能恰好存在构建出的
  /// `libgstore_host.so`，此时 `RustLib.init()` 会成功，把真实 JNI/平台调用引入
  /// `testWidgets` 的 FakeAsync（挂起或残留定时器），使页面无法走既有降级路径。
  /// 全局测试配置把它置 `true`；需要真实原生桥的冒烟测试（如 `core_api_test`）
  /// 在自身 `setUpAll` 中置回 `false`。
  @visibleForTesting
  static bool debugForceUnavailable = false;

  /// 确保 bridge 恰好初始化一次；并发调用共享同一个初始化 Future。
  static Future<void> ensureInitialized() {
    if (debugForceUnavailable) {
      return Future<void>.error(
        StateError('RustBridge: 测试环境强制禁用原生桥（无宿主 .so）'),
      );
    }
    if (_initialized) return Future.value();
    return _pending ??= _init();
  }

  static Future<void> _init() async {
    try {
      await RustLib.init();
      _initialized = true;
    } finally {
      _pending = null;
    }
  }
}

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

  /// 确保 bridge 恰好初始化一次；并发调用共享同一个初始化 Future。
  static Future<void> ensureInitialized() {
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

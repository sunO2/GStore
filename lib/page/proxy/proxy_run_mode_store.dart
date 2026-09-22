/// 「用户选择的运行模式」持久化接缝（page 层）。
///
/// 引擎只上报**当前**运行模式（`ping.mode` / `proxy.state.mode`），没有「记住用户
/// 选择的运行模式」的持久化：断开重连 / 离开再进入代理页时，目标模式会回落到默认
/// VPN。这里定义可注入的小接口：生产实现沿用统一 [ConfigStore]
/// （`proxy_run_mode`，值为 `ProxyMode.wire`），测试注入内存实现即可。
///
/// 为**不改动冻结契约**（`lib/core/rust/proxy/*`），本文件只做持久化，不新增任何
/// 门面方法；`core.start` / `core.set_mode` 的调用语义保持不变。
library;

import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 用户选择的运行模式的只读 + 写入接缝。
abstract class ProxyRunModeStore {
  /// 读取用户选择的运行模式；未设置 / 读取失败返回 `null`。
  Future<ProxyMode?> read();

  /// 持久化用户选择的运行模式。
  Future<void> write(ProxyMode mode);

  /// 清除用户选择（回落到默认 VPN）。
  Future<void> clear();
}

/// 生产实现：统一 [ConfigStore]（共享偏好 / 加密存储自动路由）。
///
/// 所有读写都做 best-effort：`ConfigStore` 未初始化 / 存储异常时读返回 `null`、
/// 写静默忽略，绝不因持久化失败而崩溃页面。
class ConfigStoreProxyRunModeStore implements ProxyRunModeStore {
  const ConfigStoreProxyRunModeStore();

  /// 持久化 key（沿用代理设置页 `proxy_*` 命名）。
  static const String key = 'proxy_run_mode';

  @override
  Future<ProxyMode?> read() async {
    try {
      final value = await ConfigStore.instance.readString(key);
      if (value == null || value.isEmpty) return null;
      return ProxyMode.fromWire(value);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(ProxyMode mode) async {
    if (mode.wire.isEmpty) return;
    try {
      await ConfigStore.instance.writeString(key, mode.wire);
    } catch (_) {
      // 持久化失败不阻断选择（本次会话仍以内存选择为准）。
    }
  }

  @override
  Future<void> clear() async {
    try {
      await ConfigStore.instance.remove(key);
    } catch (_) {
      // best-effort
    }
  }
}

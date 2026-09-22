/// 「用户选择的路由模式」持久化接缝（page 层）。
///
/// 引擎的路由模式（直连/规则/全局）在新隧道建立时会回落到默认 `rule`，模块自身
/// 不记住用户选择。这里定义可注入的小接口：生产实现沿用统一 [ConfigStore]
/// （`proxy_routing_mode`，值为 `direct`|`rule`|`global`），测试注入内存实现即可。
///
/// 与 [ProxyRunModeStore]（VPN / 局域网运行模式）是**两个独立**的持久化值：
/// 路由模式表达流量如何分流，运行模式表达数据面由谁承载。
library;

import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 用户选择的路由模式的只读 + 写入接缝。
abstract class ProxyRoutingModeStore {
  /// 读取用户选择的路由模式；未设置 / 读取失败返回 `null`。
  Future<ProxyRoutingMode?> read();

  /// 持久化用户选择的路由模式。
  Future<void> write(ProxyRoutingMode mode);

  /// 清除用户选择（回落到默认规则模式）。
  Future<void> clear();
}

/// 生产实现：统一 [ConfigStore]（共享偏好 / 加密存储自动路由）。
///
/// 所有读写都做 best-effort：`ConfigStore` 未初始化 / 存储异常时读返回 `null`、
/// 写静默忽略，绝不因持久化失败而崩溃页面。
class ConfigStoreProxyRoutingModeStore implements ProxyRoutingModeStore {
  const ConfigStoreProxyRoutingModeStore();

  /// 持久化 key（沿用代理设置页 `proxy_*` 命名）。
  static const String key = 'proxy_routing_mode';

  @override
  Future<ProxyRoutingMode?> read() async {
    try {
      final value = await ConfigStore.instance.readString(key);
      if (value == null || value.isEmpty) return null;
      final mode = ProxyRoutingMode.fromWire(value);
      return mode == ProxyRoutingMode.unknown ? null : mode;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(ProxyRoutingMode mode) async {
    if (mode.wire.isEmpty || mode == ProxyRoutingMode.unknown) return;
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

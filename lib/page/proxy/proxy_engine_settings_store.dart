/// 代理引擎侧设置的持久化接缝（page 层）。
///
/// `core.start` / `core.restart` 的请求（[GenerateRequest]）可携带 `stack` /
/// `mtu`，并在隧道 (重) 建时生效；Rust 侧只按当次请求处理，不记住用户选择。
/// 这里把用户选择的引擎参数持久化到应用侧，供首页 / 设置页在启动引擎时读取。
///
/// 为**不改动冻结契约**（`lib/core/rust/proxy/*`），本文件只做持久化，不新增
/// 任何模块方法。生产实现沿用统一 [ConfigStore]（key：`proxy_engine_stack` /
/// `proxy_engine_mtu`）；测试注入内存实现即可。
///
/// 所有读写都做 best-effort：`ConfigStore` 未初始化 / 存储异常 / 值损坏时回落到
/// 默认（stack `gvisor`，mtu `1500`），绝不因持久化失败崩溃页面。
library;

import 'package:gstore/core/config/config_store.dart';

/// 引擎侧设置（隧道的 stack 与 MTU）。
class ProxyEngineSettings {
  const ProxyEngineSettings({this.stack = 'gvisor', this.mtu = 1500});

  /// 隧道 stack（如 `gvisor` / `system`）。
  final String stack;

  /// 隧道 MTU。
  final int mtu;

  ProxyEngineSettings copyWith({String? stack, int? mtu}) =>
      ProxyEngineSettings(stack: stack ?? this.stack, mtu: mtu ?? this.mtu);

  @override
  bool operator ==(Object other) =>
      other is ProxyEngineSettings &&
      other.stack == stack &&
      other.mtu == mtu;

  @override
  int get hashCode => Object.hash(stack, mtu);

  @override
  String toString() => 'ProxyEngineSettings(stack: $stack, mtu: $mtu)';
}

/// 引擎侧设置的只读 + 写入接缝。
abstract class ProxyEngineSettingsStore {
  /// 读取引擎设置；未设置 / 损坏返回默认（不抛错）。
  Future<ProxyEngineSettings> read();

  /// 持久化引擎设置（best-effort，失败静默）。
  Future<void> write(ProxyEngineSettings settings);
}

/// 生产实现：统一 [ConfigStore]（共享偏好 / 加密存储自动路由）。
class ConfigStoreProxyEngineSettingsStore implements ProxyEngineSettingsStore {
  const ConfigStoreProxyEngineSettingsStore();

  /// stack 持久化 key。
  static const String keyStack = 'proxy_engine_stack';

  /// mtu 持久化 key（整型，经 `ConfigStore.write` 原样存回）。
  static const String keyMtu = 'proxy_engine_mtu';

  /// 默认 stack。
  static const String defaultStack = 'gvisor';

  /// 默认 MTU。
  static const int defaultMtu = 1500;

  @override
  Future<ProxyEngineSettings> read() async {
    try {
      final stack = await ConfigStore.instance.readString(keyStack);
      final mtu = await ConfigStore.instance.readInt(keyMtu);
      return ProxyEngineSettings(
        stack: (stack == null || stack.isEmpty) ? defaultStack : stack,
        mtu: mtu ?? defaultMtu,
      );
    } catch (_) {
      // ConfigStore 未初始化 / 存储异常 → 默认值。
      return const ProxyEngineSettings();
    }
  }

  @override
  Future<void> write(ProxyEngineSettings settings) async {
    try {
      await ConfigStore.instance.writeString(keyStack, settings.stack);
      await ConfigStore.instance.write(keyMtu, settings.mtu);
    } catch (_) {
      // best-effort：持久化失败不阻断本次会话内的选择。
    }
  }
}

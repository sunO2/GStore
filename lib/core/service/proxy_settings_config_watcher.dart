import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';

/// 代理设置外部配置变化的重新应用器。
///
/// 设置页写入路径本身会把聚合配置推送给运行中的 `ProxyVpnService`；但经
/// Agent / 备份恢复 / 其他外部写入方修改 `proxy.*` 时，运行中的服务不会
/// 自动感知。本监听器订阅 [ConfigService.onChange]，仅对四个代理设置键做
/// 100ms 防抖，读取最新聚合配置后重新下发给服务。
///
/// 设计约束：
/// * [start] 不主动 apply：启动时 VPN 通常未运行（由连接路径读取配置）。
/// * 所有平台调用都是 best-effort，异常只记录日志，绝不向上抛。
class ProxySettingsConfigWatcher {
  ProxySettingsConfigWatcher({
    ProxySettingsStore? store,
    ProxyVpnConfigApplier? applier,
  })  : _store = store ?? const ConfigStoreProxySettingsStore(),
        _applier = applier ?? const PlatformProxyVpnConfigApplier();

  static final ProxySettingsConfigWatcher instance =
      ProxySettingsConfigWatcher();

  final ProxySettingsStore _store;
  final ProxyVpnConfigApplier _applier;

  StreamSubscription<ConfigChangeEvent>? _sub;
  Timer? _debounce;
  bool _started = false;

  static const Set<String> _keys = <String>{
    ConfigKeys.proxySplitMode,
    ConfigKeys.proxySplitApps,
    ConfigKeys.proxyAlwaysOnIntent,
    ConfigKeys.proxyLogLevel,
  };

  /// 幂等启动；不主动 apply（启动时 VPN 通常未运行，由连接路径读取配置）。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _sub = ConfigService.instance.onChange.listen((event) {
      if (!_keys.contains(event.key)) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 100), () {
        unawaited(applyNow());
      });
    }, onError: (Object error, StackTrace stack) {
      debugPrint('[ProxySettingsConfigWatcher] 配置监听失败: $error');
    });
  }

  /// 读取当前聚合配置并推送给运行中的 VPN 服务（best-effort，不抛）。
  Future<void> applyNow() async {
    try {
      final config = await _store.read();
      await _applier.apply(config.toVpnConfigJson());
    } catch (error) {
      debugPrint('[ProxySettingsConfigWatcher] 应用代理配置失败（忽略）: $error');
    }
  }

  Future<void> stop() async {
    _debounce?.cancel();
    _debounce = null;
    await _sub?.cancel();
    _sub = null;
    _started = false;
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    await stop();
  }
}

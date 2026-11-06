// P2b：外部 `proxy.*` 配置变化必须重新应用到运行中的 VPN 服务。
//
// 全部密闭式：ConfigStore 使用内存后端，applier 注入假实现，不触碰平台通道。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/service/proxy_settings_config_watcher.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';

class _FakeApplier implements ProxyVpnConfigApplier {
  final List<String> applied = [];

  @override
  Future<void> apply(String configJson) async => applied.add(configJson);
}

/// 超过 100ms 防抖 + 异步读取/下发的时间窗。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 250));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(
      storages: [MemoryConfigStorage(), MemoryConfigStorage()],
    );
    await ConfigService.instance.ensureReady();
  });

  tearDown(() async {
    ConfigStore.instance.resetForTest();
    await ConfigService.instance.resetForTest();
  });

  test('外部写入 proxy.* 配置后重新应用到运行中的 VPN 服务', () async {
    final fake = _FakeApplier();
    final watcher = ProxySettingsConfigWatcher(
      store: const ConfigStoreProxySettingsStore(),
      applier: fake,
    );
    addTearDown(watcher.resetForTest);

    await watcher.start();

    // 模拟外部写入（非设置页写入路径）：三个代理设置键。
    await ConfigService.instance.set(ConfigKeys.proxySplitMode, 'allow');
    await ConfigService.instance.set(
      ConfigKeys.proxySplitApps,
      <String>['com.example.one'],
    );
    await ConfigService.instance.set(ConfigKeys.proxyLogLevel, 'debug');

    await _settle();

    expect(fake.applied, isNotEmpty, reason: '代理配置变化应触发一次 apply');
    final last = fake.applied.last;
    expect(last, contains('allow'));
    expect(last, contains('com.example.one'));

    final payload = jsonDecode(last) as Map<String, dynamic>;
    expect(payload['mode'], 'allow');
    expect(payload['allowedApps'], contains('com.example.one'));

    // stop 后不再应用。
    await watcher.stop();
    fake.applied.clear();

    await ConfigService.instance.set(ConfigKeys.proxySplitMode, 'disallow');
    await _settle();

    expect(fake.applied, isEmpty, reason: 'stop 之后不得再 apply');
  });

  test('非代理设置键的变化不触发 apply', () async {
    final fake = _FakeApplier();
    final watcher = ProxySettingsConfigWatcher(
      store: const ConfigStoreProxySettingsStore(),
      applier: fake,
    );
    addTearDown(watcher.resetForTest);

    await watcher.start();

    await ConfigService.instance.set(ConfigKeys.themeMode, 1);
    await _settle();

    expect(fake.applied, isEmpty, reason: '仅监听四个 proxy.* 键');
  });
}

// Todo 18: proxy persistence call sites use the registered `proxy.*` keys.
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_active_node_store.dart';
import 'package:gstore/page/proxy/proxy_active_profile_store.dart';
import 'package:gstore/page/proxy/proxy_engine_settings_store.dart';
import 'package:gstore/page/proxy/proxy_routing_mode_store.dart';
import 'package:gstore/page/proxy/proxy_run_mode_store.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';
import 'package:gstore/page/proxy/proxy_sheet_view_mode_store.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = ConfigService.instance;

  setUp(() async {
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(
      storages: [MemoryConfigStorage(), MemoryConfigStorage()],
    );
  });

  tearDown(() async {
    ConfigStore.instance.resetForTest();
    await service.resetForTest();
  });

  group('proxy stores use grouped keys', () {
    test('engine stack/mtu round-trip on proxy.engine_*', () async {
      expect(ConfigStoreProxyEngineSettingsStore.keyStack, 'proxy.engine_stack');
      expect(ConfigStoreProxyEngineSettingsStore.keyMtu, 'proxy.engine_mtu');

      const store = ConfigStoreProxyEngineSettingsStore();
      const settings = ProxyEngineSettings(stack: 'system', mtu: 1400);
      await store.write(settings);

      expect(await store.read(), settings);
      expect(
        await ConfigStore.instance.readString(ConfigKeys.proxyEngineStack),
        'system',
      );
      expect(
        await ConfigStore.instance.readInt(ConfigKeys.proxyEngineMtu),
        1400,
      );
    });

    test('routing mode round-trips on proxy.routing_mode', () async {
      const store = ConfigStoreProxyRoutingModeStore();
      expect(ConfigStoreProxyRoutingModeStore.key, 'proxy.routing_mode');

      await store.write(ProxyRoutingMode.global);
      expect(await store.read(), ProxyRoutingMode.global);
      expect(
        await ConfigStore.instance.readString(ConfigKeys.proxyRoutingMode),
        'global',
      );

      await store.clear();
      expect(await store.read(), isNull);
    });

    test('run mode round-trips on proxy.run_mode', () async {
      const store = ConfigStoreProxyRunModeStore();
      expect(ConfigStoreProxyRunModeStore.key, 'proxy.run_mode');

      await store.write(ProxyMode.lanProxy);
      expect(await store.read(), ProxyMode.lanProxy);
      expect(
        await ConfigStore.instance.readString(ConfigKeys.proxyRunMode),
        'lanProxy',
      );
    });

    test('active node round-trips on proxy.active_node_label', () async {
      const store = ConfigStoreProxyActiveNodeStore();
      expect(
        ConfigStoreProxyActiveNodeStore.key,
        'proxy.active_node_label',
      );

      const node = ProxyActiveNode(group: 'PROXY', node: 'Node A');
      await store.write(node);

      final read = await store.read();
      expect(read?.group, 'PROXY');
      expect(read?.node, 'Node A');
      expect(
        await ConfigStore.instance.readString(
          ConfigKeys.proxyActiveNodeLabel,
        ),
        contains('Node A'),
      );
    });

    test('active profile round-trips on proxy.active_profile_id', () async {
      const store = ConfigStoreProxyActiveProfileStore();
      expect(
        ConfigStoreProxyActiveProfileStore.key,
        'proxy.active_profile_id',
      );

      await store.write('profile-1');
      expect(await store.read(), 'profile-1');
      expect(
        await ConfigStore.instance.readString(
          ConfigKeys.proxyActiveProfileId,
        ),
        'profile-1',
      );
    });

    test('sheet view mode round-trips on proxy.sheet_view_mode', () async {
      const store = ConfigStoreProxySheetViewModeStore();
      expect(
        ConfigStoreProxySheetViewModeStore.key,
        'proxy.sheet_view_mode',
      );

      await store.writeGridMode(true);
      expect(await store.readGridMode(), isTrue);
      expect(
        await ConfigStore.instance.readString(ConfigKeys.proxySheetViewMode),
        'grid',
      );

      await store.writeGridMode(false);
      expect(await store.readGridMode(), isFalse);
      expect(
        await ConfigStore.instance.readString(ConfigKeys.proxySheetViewMode),
        'list',
      );
    });

    test('settings facade round-trips split/apps/always-on/log keys', () async {
      const store = ConfigStoreProxySettingsStore();
      const config = ProxySettingsConfig(
        splitMode: ProxySplitTunnelMode.allow,
        selectedApps: <String>{'com.example.app'},
        alwaysOnIntent: true,
        logLevel: ProxyLogLevel.debug,
      );

      await store.write(config);
      final read = await store.read();

      expect(read.splitMode, ProxySplitTunnelMode.allow);
      expect(read.selectedApps, <String>{'com.example.app'});
      expect(read.alwaysOnIntent, isTrue);
      expect(read.logLevel, ProxyLogLevel.debug);

      expect(
        await ConfigStore.instance.readString(ConfigKeys.proxySplitMode),
        'allow',
      );
      expect(
        await ConfigStore.instance.readStringList(ConfigKeys.proxySplitApps),
        <String>['com.example.app'],
      );
      expect(
        await ConfigStore.instance.readBool(ConfigKeys.proxyAlwaysOnIntent),
        isTrue,
      );
      expect(
        await ConfigStore.instance.readString(ConfigKeys.proxyLogLevel),
        'debug',
      );
    });

    test('all proxy keys round-trip through ConfigService grouped keys',
        () async {
      final cases = <String, Object>{
        ConfigKeys.proxyUrl: 'https://proxy.example/',
        ConfigKeys.proxyEngineStack: 'system',
        ConfigKeys.proxyEngineMtu: 1400,
        ConfigKeys.proxyRoutingMode: 'global',
        ConfigKeys.proxyRunMode: 'lanProxy',
        ConfigKeys.proxyActiveNodeLabel: <String, dynamic>{
          'group': 'PROXY',
          'node': 'Node A',
        },
        ConfigKeys.proxyActiveProfileId: 'profile-1',
        ConfigKeys.proxySheetViewMode: 'grid',
        ConfigKeys.proxySplitMode: 'allow',
        ConfigKeys.proxySplitApps: <String>['com.example.app'],
        ConfigKeys.proxyAlwaysOnIntent: true,
        ConfigKeys.proxyLogLevel: 'debug',
      };

      for (final entry in cases.entries) {
        final result = await service.set(entry.key, entry.value);
        expect(result.success, isTrue, reason: '${entry.key}: ${result.message}');
        expect(await service.getRaw(entry.key), entry.value);
      }

      // The proxy cache key is the cross-module `network.proxy_url`; the other
      // persistence keys all live under `proxy.*`.
      expect(ConfigKeys.proxyUrl, 'network.proxy_url');
      for (final key in cases.keys) {
        if (key == ConfigKeys.proxyUrl) continue;
        expect(key, startsWith('proxy.'));
      }
    });
  });
}

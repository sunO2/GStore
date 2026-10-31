import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Todo 20: settings page reads/writes grouped download keys through
  // ConfigService grouped keys (legacy provider map removed).
  group('download settings via grouped ConfigService keys', () {
    final service = ConfigService.instance;

    Future<void> initForTest() async {
      ConfigStore.instance.resetForTest();
      await ConfigStore.instance.initialize(storages: [
        MemoryConfigStorage(),
        MemoryConfigStorage(),
      ]);
      ConfigRegistry.registerAll(service);
    }

    setUp(() async {
      await initForTest();
    });

    test('wire keys are grouped under download.*', () {
      expect(
        ConfigKeys.downloadMultiSegmentEnabled,
        'download.multi_segment.enabled',
      );
      expect(ConfigKeys.downloadMaxConcurrent, 'download.max_concurrent');
      expect(ConfigKeys.downloadDefaultConnections,
          'download.default_connections');
      expect(ConfigKeys.downloadMaxRetries, 'download.max_retries');
      expect(ConfigKeys.downloadSpeedLimitBps, 'download.speed_limit_bps');
      expect(ConfigKeys.downloadWifiOnly, 'download.wifi_only');
    });

    test('defaults read back through the facade', () async {
      expect(
        await service.getT<bool>(ConfigKeys.downloadMultiSegmentEnabled),
        true,
      );
      expect(await service.getT<int>(ConfigKeys.downloadMaxConcurrent), 3);
      expect(await service.getT<int>(ConfigKeys.downloadDefaultConnections), 4);
      expect(await service.getT<int>(ConfigKeys.downloadMaxRetries), 3);
      expect(await service.getT<int>(ConfigKeys.downloadSpeedLimitBps), 0);
      expect(await service.getT<bool>(ConfigKeys.downloadWifiOnly), false);
    });

    test('settings-style concurrency write is used by the next read',
        () async {
      // Mirrors the slider tile: clamp to the UI range, then persist.
      final selected = 7.clamp(1, 10);
      final result = await service.set(
        ConfigKeys.downloadMaxConcurrent,
        selected,
        source: ConfigChangeSource.user,
      );
      expect(result.success, true);

      // A subsequent settings load reads the new value, not a stale provider
      // cache. ConfigStore sees the same persisted grouped key.
      expect(await service.getT<int>(ConfigKeys.downloadMaxConcurrent), 7);
      expect(
        await ConfigStore.instance.readInt(ConfigKeys.downloadMaxConcurrent),
        7,
      );
    });

    test('wifi-only persists and is readable', () async {
      final enabled = await service.set(
        ConfigKeys.downloadWifiOnly,
        true,
        source: ConfigChangeSource.user,
      );
      expect(enabled.success, true);
      expect(await service.getT<bool>(ConfigKeys.downloadWifiOnly), true);
      expect(
        await ConfigStore.instance.readBool(ConfigKeys.downloadWifiOnly),
        true,
      );

      final disabled = await service.set(
        ConfigKeys.downloadWifiOnly,
        false,
        source: ConfigChangeSource.user,
      );
      expect(disabled.success, true);
      expect(await service.getT<bool>(ConfigKeys.downloadWifiOnly), false);
    });

    test('out-of-range concurrency is rejected and keeps the prior value',
        () async {
      final baseline = await service.set(
        ConfigKeys.downloadMaxConcurrent,
        6,
        source: ConfigChangeSource.user,
      );
      expect(baseline.success, true);

      final tooHigh = await service.set(
        ConfigKeys.downloadMaxConcurrent,
        99,
        source: ConfigChangeSource.user,
      );
      expect(tooHigh.success, false);
      final tooLow = await service.set(
        ConfigKeys.downloadMaxConcurrent,
        0,
        source: ConfigChangeSource.user,
      );
      expect(tooLow.success, false);

      expect(await service.getT<int>(ConfigKeys.downloadMaxConcurrent), 6);
    });
  });
}

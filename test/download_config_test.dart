import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/providers/download_config_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadConfig', () {
    test('default values', () {
      const config = DownloadConfig();
      expect(config.multiSegmentEnabled, true);
      expect(config.maxSegments, 8);
      expect(config.maxConcurrentDownloads, 3);
      expect(config.wifiOnly, false);
      expect(config.maxRetryCount, 3);
    });

    test('toJson/fromJson roundtrip', () {
      const original = DownloadConfig(
        multiSegmentEnabled: false,
        maxConcurrentDownloads: 5,
        wifiOnly: true,
        maxRetryCount: 2,
      );
      final json = original.toJson();
      final restored = DownloadConfig.fromJson(json);
      expect(restored.multiSegmentEnabled, false);
      expect(restored.maxConcurrentDownloads, 5);
      expect(restored.wifiOnly, true);
      expect(restored.maxRetryCount, 2);
    });

    test('copyWith preserves unmodified fields', () {
      const original = DownloadConfig();
      final modified = original.copyWith(maxConcurrentDownloads: 7);
      expect(modified.maxConcurrentDownloads, 7);
      expect(modified.multiSegmentEnabled, true);
      expect(modified.wifiOnly, false);
    });
  });

  // Todo 20: settings page reads/writes grouped download keys through
  // ConfigService (no ConfigManager provider map).
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

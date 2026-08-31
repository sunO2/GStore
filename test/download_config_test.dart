import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/providers/download_config_provider.dart';

void main() {
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
}

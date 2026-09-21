// 字节进度 → 下载阶段比例映射的纯函数测试（无 FFI / 无网络）。
//
// `mapByteProgress` 把下载层上报的 (received, total) 映射到 `[0.05, 0.70]`：
// 分母优先取下载层总长，其次清单声明体积；两者皆未知则固定 0.05。
//
// ignore_for_file: file_names

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show mapByteProgress;

void main() {
  group('mapByteProgress', () {
    test('未知 total 时回退 expectedSize，且随 received 单调递增到 0.70', () {
      final f0 = mapByteProgress(0, null, 1000);
      final f25 = mapByteProgress(250, null, 1000);
      final f50 = mapByteProgress(500, null, 1000);
      final f100 = mapByteProgress(1000, null, 1000);

      expect(f0, closeTo(0.05, 1e-9));
      expect(f25, greaterThan(f0));
      expect(f50, greaterThan(f25));
      expect(f100, closeTo(0.70, 1e-9));
      for (final f in <double>[f0, f25, f50, f100]) {
        expect(f, inInclusiveRange(0.05, 0.70));
      }
    });

    test('优先使用下载层 total 作为分母（而非 expectedSize）', () {
      expect(
        mapByteProgress(50, 100, 1000),
        closeTo(0.05 + 0.65 * 0.5, 1e-9),
      );
    });

    test('received > denom（压缩/回退）夹取到 0.70', () {
      expect(mapByteProgress(2000, 1000, null), 0.70);
      expect(mapByteProgress(2000, null, 1000), 0.70);
      expect(mapByteProgress(4000, 100, 100), 0.70);
    });

    test('denom 全未知 → 固定 0.05', () {
      expect(mapByteProgress(123, null, null), 0.05);
      expect(mapByteProgress(0, null, null), 0.05);
    });

    test('零/负分母保护 → 0.05（绝不除零/越界）', () {
      expect(mapByteProgress(10, 0, null), 0.05);
      expect(mapByteProgress(10, 0, 0), 0.05);
      expect(mapByteProgress(10, -5, null), 0.05);
      expect(mapByteProgress(10, null, 0), 0.05);
      expect(mapByteProgress(10, null, -5), 0.05);
    });

    test('整段采样单调不减且始终落在 [0.05, 0.70]', () {
      double? previous;
      for (var received = 0; received <= 1200; received += 50) {
        final f = mapByteProgress(received, null, 1000);
        expect(f, inInclusiveRange(0.05, 0.70));
        if (previous != null) {
          expect(f, greaterThanOrEqualTo(previous));
        }
        previous = f;
      }
    });
  });
}

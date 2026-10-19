import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/foreground_source.dart';

void main() {
  group('foregroundReadingFromJson', () {
    test('启用且已有前台包', () {
      final reading = foregroundReadingFromJson(
        '{"enabled":true,"package":"com.a","activity":".Main",'
        '"updatedAtMs":1700000000000}',
      );

      expect(reading, isNotNull);
      expect(reading!.enabled, isTrue);
      expect(reading.package, 'com.a');
      expect(reading.activity, '.Main');
      expect(reading.updatedAtMs, 1700000000000);
      expect(reading.usable, isTrue);
    });

    test('服务未启用 → 不可用', () {
      final reading = foregroundReadingFromJson(
        '{"enabled":false,"package":null,"activity":null,"updatedAtMs":0}',
      );

      expect(reading, isNotNull);
      expect(reading!.enabled, isFalse);
      expect(reading.package, isNull);
      expect(reading.usable, isFalse);
    });

    test('已启用但尚未收到事件 → 不可用', () {
      final reading = foregroundReadingFromJson(
        '{"enabled":true,"package":null,"activity":null,"updatedAtMs":0}',
      );
      expect(reading?.usable, isFalse);
    });

    test('非法 / 非对象 JSON → null；缺失 enabled 按 false', () {
      expect(foregroundReadingFromJson('nope'), isNull);
      expect(foregroundReadingFromJson('[]'), isNull);
      final reading = foregroundReadingFromJson('{"package":"com.a"}');
      expect(reading, isNotNull);
      expect(reading!.enabled, isFalse);
      expect(reading.usable, isFalse);
    });
  });

  group('RustJniForegroundBridge', () {
    test('注入读取器：正常 JSON → 模型', () async {
      final bridge = RustJniForegroundBridge(
        readJson: () async => '{"enabled":true,"package":"com.a"}',
      );
      final reading = await bridge.read();
      expect(reading?.package, 'com.a');
      expect(reading?.usable, isTrue);
    });

    test('注入读取器：null / 抛异常 / 空串 → null', () async {
      expect(
        await RustJniForegroundBridge(readJson: () async => null).read(),
        isNull,
      );
      expect(
        await RustJniForegroundBridge(readJson: () async => '').read(),
        isNull,
      );
      expect(
        await RustJniForegroundBridge(
          readJson: () async => throw StateError('ffi'),
        ).read(),
        isNull,
      );
    });
  });
}

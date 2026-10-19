import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/refresh_auto_store.dart';

RefreshAutoEntry _entry(String pkg, {int min = 60, int peak = 120}) =>
    RefreshAutoEntry(package: pkg, label: pkg, min: min, peak: peak);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decodeRefreshAutoConfig · 容错', () {
    test('null / 空串 / 非 JSON / 非 Map → 空配置', () {
      expect(decodeRefreshAutoConfig(null).enabled, isFalse);
      expect(decodeRefreshAutoConfig('').enabled, isFalse);
      expect(decodeRefreshAutoConfig('not json').entries, isEmpty);
      expect(decodeRefreshAutoConfig('[1,2,3]').entries, isEmpty);
      expect(decodeRefreshAutoConfig('   ').entries, isEmpty);
    });

    test('坏条目跳过，好条目保留', () {
      const raw = '{"enabled":true,"defaultMin":60,"defaultPeak":60,'
          '"entries":{"com.a":{"package":"com.a","label":"A","min":60,"peak":120},'
          '"bad":"not-a-map"}}';
      final config = decodeRefreshAutoConfig(raw);

      expect(config.enabled, isTrue);
      expect(config.defaultMin, 60);
      expect(config.defaultPeak, 60);
      expect(config.entries.keys, equals(<String>['com.a']));
      expect(config.entries['com.a']!.min, 60);
      expect(config.entries['com.a']!.peak, 120);
    });

    test('条目缺 package → 以 map 键归一；缺 label → 回退包名', () {
      const raw = '{"entries":{"com.x":{"min":90,"peak":90}}}';
      final entry = decodeRefreshAutoConfig(raw).entries['com.x']!;

      expect(entry.package, 'com.x');
      expect(entry.label, 'com.x');
      expect(entry.min, 90);
      expect(entry.peak, 90);
    });

    test('字符串数值宽容解析', () {
      const raw = '{"defaultMin":"60","defaultPeak":"120",'
          '"entries":{"com.x":{"package":"com.x","min":"90","peak":"120"}}}';
      final config = decodeRefreshAutoConfig(raw);

      expect(config.defaultMin, 60);
      expect(config.defaultPeak, 120);
      expect(config.entries['com.x']!.min, 90);
    });
  });

  group('encode / decode 往返', () {
    test('往返保持 enabled / defaults / entries', () {
      final config = RefreshAutoConfig(
        enabled: true,
        defaultMin: 60,
        defaultPeak: 90,
        entries: <String, RefreshAutoEntry>{
          'com.a': _entry('com.a', min: 120, peak: 120),
        },
      );

      final again = decodeRefreshAutoConfig(encodeRefreshAutoConfig(config));

      expect(again.enabled, isTrue);
      expect(again.defaultMin, 60);
      expect(again.defaultPeak, 90);
      expect(again.entries['com.a'], equals(_entry('com.a', min: 120, peak: 120)));
    });
  });

  group('InMemoryRefreshAutoStore', () {
    test('upsert / remove / clear / setEnabled / setDefaults', () async {
      final store = InMemoryRefreshAutoStore();

      await store.setEnabled(true);
      await store.upsert(_entry('com.a'));
      await store.setDefaults(min: 60, peak: 60);
      var config = await store.load();
      expect(config.enabled, isTrue);
      expect(config.entries.containsKey('com.a'), isTrue);
      expect(config.hasDefaults, isTrue);

      await store.remove('com.a');
      config = await store.load();
      expect(config.entries, isEmpty);

      await store.setDefaults();
      config = await store.load();
      expect(config.hasDefaults, isFalse);

      await store.clear();
      config = await store.load();
      expect(config.enabled, isFalse);
      expect(config.entries, isEmpty);
    });

    test('空包名 upsert 不写', () async {
      final store = InMemoryRefreshAutoStore();
      expect(await store.upsert(_entry('')), isFalse);
      expect((await store.load()).entries, isEmpty);
    });
  });

  group('SharedPrefsRefreshAutoStore', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('save → load 往返', () async {
      const store = SharedPrefsRefreshAutoStore();
      await store.setEnabled(true);
      await store.upsert(_entry('com.a', min: 90, peak: 120));
      await store.setDefaults(min: 60, peak: 60);

      final config = await store.load();
      expect(config.enabled, isTrue);
      expect(config.defaultMin, 60);
      expect(config.entries['com.a']!.min, 90);
      expect(config.entries['com.a']!.peak, 120);
    });

    test('存储坏 JSON → 容错为空配置（不抛）', () async {
      SharedPreferences.setMockInitialValues(
        <String, Object>{
          SharedPrefsRefreshAutoStore.storageKey: 'not-json',
        },
      );
      const store = SharedPrefsRefreshAutoStore();
      expect((await store.load()).entries, isEmpty);
    });
  });
}

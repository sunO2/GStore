import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/perf_alert_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PerfAlertSettings 模型', () {
    test('默认值：告警关闭 + 提示阈值', () {
      const s = PerfAlertSettings.defaults;
      expect(s.enabled, isFalse);
      expect(s.cpuPercent, 80);
      expect(s.temperatureC, 45);
      expect(s.jankPercent, 5);
      expect(s.minFps, 50);
      expect(s.notify, isTrue);
      expect(s.banner, isTrue);
    });

    test('copyWith 覆盖指定字段', () {
      final s = PerfAlertSettings.defaults.copyWith(
        enabled: true,
        cpuPercent: 90,
        notify: false,
      );
      expect(s.enabled, isTrue);
      expect(s.cpuPercent, 90);
      expect(s.notify, isFalse);
      expect(s.temperatureC, 45);
    });

    test('toMap/fromMap 往返一致', () {
      const s = PerfAlertSettings(
        enabled: true,
        cpuPercent: 70.5,
        temperatureC: 42,
        jankPercent: 8,
        minFps: 45,
        notify: false,
        banner: true,
      );
      expect(PerfAlertSettings.fromMap(s.toMap()), s);
    });

    test('fromMap 宽容：缺失/非法字段回退默认值', () {
      final s = PerfAlertSettings.fromMap(<String, dynamic>{
        'enabled': 'yes', // 非 bool → false
        'cpu_percent': 'abc', // 非法 → 默认 80
        'min_fps': 45, // 合法数字
      });
      expect(s.enabled, isFalse);
      expect(s.cpuPercent, 80);
      expect(s.minFps, 45);
      expect(s.temperatureC, 45);
    });
  });

  group('SharedPrefsPerfAlertSettingsStore', () {
    test('保存后读取一致（跨实例）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const store = SharedPrefsPerfAlertSettingsStore();
      const settings = PerfAlertSettings(
        enabled: true,
        cpuPercent: 88,
        temperatureC: 47,
        jankPercent: 6,
        minFps: 55,
        notify: false,
        banner: false,
      );

      await store.save(settings);
      final loaded =
          await const SharedPrefsPerfAlertSettingsStore().load();
      expect(loaded, settings);
    });

    test('无记录 → null', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final loaded = await const SharedPrefsPerfAlertSettingsStore().load();
      expect(loaded, isNull);
    });

    test('损坏 JSON → null（不抛）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPrefsPerfAlertSettingsStore.storageKey: '{not json',
      });
      final loaded = await const SharedPrefsPerfAlertSettingsStore().load();
      expect(loaded, isNull);
    });
  });

  group('InMemoryPerfAlertSettingsStore', () {
    test('保存/读取往返', () async {
      final store = InMemoryPerfAlertSettingsStore();
      expect(await store.load(), isNull);
      await store.save(PerfAlertSettings.defaults.copyWith(enabled: true));
      expect((await store.load())!.enabled, isTrue);
    });
  });
}

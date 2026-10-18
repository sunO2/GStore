import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/perf_auto_export_settings.dart';
import 'package:gstore/core/perf/perf_report_store.dart' show PerfReportFormat;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PerfAutoExportFormat', () {
    test('reportFormats 映射', () {
      expect(
        PerfAutoExportFormat.json.reportFormats,
        const <PerfReportFormat>[PerfReportFormat.json],
      );
      expect(
        PerfAutoExportFormat.csv.reportFormats,
        const <PerfReportFormat>[PerfReportFormat.csv],
      );
      expect(
        PerfAutoExportFormat.both.reportFormats,
        const <PerfReportFormat>[
          PerfReportFormat.json,
          PerfReportFormat.csv,
        ],
      );
    });

    test('fromValue 宽容：未知 / 缺省回退 json', () {
      expect(PerfAutoExportFormat.fromValue('csv'), PerfAutoExportFormat.csv);
      expect(PerfAutoExportFormat.fromValue('both'), PerfAutoExportFormat.both);
      expect(
        PerfAutoExportFormat.fromValue('nope'),
        PerfAutoExportFormat.json,
      );
      expect(PerfAutoExportFormat.fromValue(null), PerfAutoExportFormat.json);
    });
  });

  group('PerfAutoExportSettings 模型', () {
    test('默认值：关闭 + 5 分钟 + json + 保留 20', () {
      const s = PerfAutoExportSettings.defaults;
      expect(s.enabled, isFalse);
      expect(s.intervalMinutes, kPerfAutoExportDefaultIntervalMinutes);
      expect(s.format, PerfAutoExportFormat.json);
      expect(s.maxKeep, kPerfAutoExportDefaultMaxKeep);
    });

    test('copyWith 覆盖指定字段', () {
      final s = PerfAutoExportSettings.defaults.copyWith(
        enabled: true,
        intervalMinutes: 15,
        format: PerfAutoExportFormat.both,
        maxKeep: 7,
      );
      expect(s.enabled, isTrue);
      expect(s.intervalMinutes, 15);
      expect(s.format, PerfAutoExportFormat.both);
      expect(s.maxKeep, 7);
    });

    test('toMap/fromMap 往返一致', () {
      const s = PerfAutoExportSettings(
        enabled: true,
        intervalMinutes: 30,
        format: PerfAutoExportFormat.csv,
        maxKeep: 5,
      );
      expect(PerfAutoExportSettings.fromMap(s.toMap()), s);
      expect(s, s.copyWith());
    });

    test('fromMap 宽容：缺失 / 非法回退默认 + 下限钳制', () {
      final s = PerfAutoExportSettings.fromMap(<String, dynamic>{
        'enabled': 'yes', // 非 bool → false
        'interval_minutes': 0, // < 1 → 钳到 1
        'format': 'unknown', // → json
        'max_keep': -3, // < 1 → 钳到 1
      });
      expect(s.enabled, isFalse);
      expect(s.intervalMinutes, kPerfAutoExportMinIntervalMinutes);
      expect(s.format, PerfAutoExportFormat.json);
      expect(s.maxKeep, kPerfAutoExportMinMaxKeep);
    });

    test('fromMap 接受数字 / 数字字符串', () {
      final s = PerfAutoExportSettings.fromMap(<String, dynamic>{
        'interval_minutes': '12',
        'max_keep': 3.0,
      });
      expect(s.intervalMinutes, 12);
      expect(s.maxKeep, 3);
    });
  });

  group('SharedPrefsPerfAutoExportSettingsStore', () {
    test('保存后读取一致（跨实例）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const store = SharedPrefsPerfAutoExportSettingsStore();
      const settings = PerfAutoExportSettings(
        enabled: true,
        intervalMinutes: 30,
        format: PerfAutoExportFormat.both,
        maxKeep: 5,
      );

      await store.save(settings);
      final loaded = await const SharedPrefsPerfAutoExportSettingsStore().load();
      expect(loaded, settings);
    });

    test('无记录 → null', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(
        await const SharedPrefsPerfAutoExportSettingsStore().load(),
        isNull,
      );
    });
  });

  group('InMemoryPerfAutoExportSettingsStore', () {
    test('save/load 往返', () async {
      final store = InMemoryPerfAutoExportSettingsStore();
      expect(await store.load(), isNull);

      const settings = PerfAutoExportSettings(
        enabled: true,
        intervalMinutes: 10,
        format: PerfAutoExportFormat.csv,
        maxKeep: 3,
      );
      await store.save(settings);
      expect(await store.load(), settings);
    });

    test('构造注入初值', () async {
      const seed = PerfAutoExportSettings(enabled: true, intervalMinutes: 2);
      final store = InMemoryPerfAutoExportSettingsStore(seed);
      expect(await store.load(), seed);
    });
  });
}

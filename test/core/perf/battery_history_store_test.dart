import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/battery_history.dart';
import 'package:gstore/core/perf/battery_history_store.dart';

/// 便捷构造：一条屏幕点亮、放电(status=3)的有效功耗样本。
BatteryHistoryRecord _rec({
  required int timeMs,
  int session = 1,
  String package = 'com.app',
  String mode = 'balance',
  int current = 100,
  double voltage = 4.0,
  double temperature = 30,
  int status = kBatteryStatusDischarging,
  int screenOn = 1,
}) =>
    BatteryHistoryRecord(
      time: '$timeMs',
      session: session,
      temperature: temperature,
      status: status,
      mode: mode,
      current: current,
      voltage: voltage,
      package: package,
      screenOn: screenOn,
      capacity: 50,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BatteryHistoryRecord JSON', () {
    test('round-trip 逐字段重建（Scene 列名）', () {
      final record = _rec(timeMs: 1000, session: 7, current: 250, voltage: 3.85);
      final json = record.toJson();
      // 键 = Scene 列名（VERBATIM）。
      expect(
        json.keys.toSet(),
        <String>{
          'time',
          'session',
          'temperature',
          'status',
          'mode',
          'current',
          'voltage',
          'package',
          'screen_on',
          'capacity',
        },
      );
      expect(BatteryHistoryRecord.fromJson(json), record);
    });

    test('缺失 / 非法字段降级为 Scene 默认值', () {
      final record = BatteryHistoryRecord.fromJson(<String, dynamic>{
        'time': 123, // 非字符串 → toString 容忍
        'session': '9', // 字符串数字 → 解析
        'temperature': 'not-a-number',
        'voltage': null,
      });
      expect(record.time, '123');
      expect(record.session, 9);
      expect(record.temperature, -1); // 默认
      expect(record.status, -1); // 默认
      expect(record.current, -1); // 默认
      expect(record.voltage, 0); // 缺失 → 0
      expect(record.package, '');
      expect(record.screenOn, 0);
      expect(record.capacity, 0);
    });
  });

  group('InMemoryBatteryHistoryStore', () {
    test('append/load 往返；clear', () async {
      final store = InMemoryBatteryHistoryStore();
      await store.append(_rec(timeMs: 2000));
      await store.append(_rec(timeMs: 1000));
      final list = await store.load();
      expect(list.map((r) => r.time).toList(), <String>['1000', '2000']);
      await store.clear();
      expect(await store.load(), isEmpty);
    });

    test('按会话裁剪最旧（保留最新 99 会话）', () async {
      final store = InMemoryBatteryHistoryStore(capacity: 2);
      await store.append(_rec(timeMs: 100, session: 1));
      await store.append(_rec(timeMs: 200, session: 2));
      await store.append(_rec(timeMs: 300, session: 3));
      await store.append(_rec(timeMs: 301, session: 3));
      final list = await store.load();
      // 会话 1 被裁剪；会话 2、3 全保留。
      expect(list.map((r) => r.session).toSet(), <int>{2, 3});
      expect(list.length, 3);
    });
  });

  group('SharedPrefsBatteryHistoryStore', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('跨实例往返 + 会话容量裁剪', () async {
      const store = SharedPrefsBatteryHistoryStore(capacity: 2);
      await store.append(_rec(timeMs: 100, session: 1, current: 10));
      await store.append(_rec(timeMs: 200, session: 2, current: 20));
      await store.append(_rec(timeMs: 300, session: 3, current: 30));

      const store2 = SharedPrefsBatteryHistoryStore(capacity: 2);
      final list = await store2.load();
      expect(list.map((r) => r.session).toList(), <int>[2, 3]);
      expect(list.map((r) => r.current).toList(), <int>[20, 30]);
    });

    test('损坏 JSON / 空 / 非数组 → 静默降级为空', () async {
      for (final raw in <Object>['{not json', '', '42', 'null', '"x"']) {
        SharedPreferences.setMockInitialValues(<String, Object>{
          SharedPrefsBatteryHistoryStore.storageKey: raw,
        });
        final list = await const SharedPrefsBatteryHistoryStore().load();
        expect(list, isEmpty, reason: 'raw=$raw');
      }
    });

    test('列表内损坏条目被跳过，其余正常读取', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPrefsBatteryHistoryStore.storageKey:
            '[{"time":"5","session":1,"current":10}, 42, "bad", '
                '{"time":"7","session":1,"current":20}]',
      });
      final list = await const SharedPrefsBatteryHistoryStore().load();
      expect(list.map((r) => r.current).toList(), <int>[10, 20]);
    });

    test('clear 清空', () async {
      const store = SharedPrefsBatteryHistoryStore();
      await store.append(_rec(timeMs: 1000));
      await store.clear();
      expect(await store.load(), isEmpty);
    });
  });

  group('聚合（Scene SQL 逐字）', () {
    test('per-app 分组：过滤 screen_on=1 & status in(3,4) & package!=', () {
      final records = <BatteryHistoryRecord>[
        // 有效：com.a / balance —— current 100, 200；voltage 4.0, 5.0
        _rec(timeMs: 1, package: 'com.a', mode: 'balance', current: 100,
            voltage: 4.0, temperature: 20),
        _rec(timeMs: 2, package: 'com.a', mode: 'balance', current: 200,
            voltage: 5.0, temperature: 40),
        // 有效：com.b / perf
        _rec(timeMs: 3, package: 'com.b', mode: 'perf', current: 50,
            voltage: 4.0, temperature: 30),
        // 被过滤：screen_on=0
        _rec(timeMs: 4, package: 'com.a', mode: 'balance', current: 9999,
            voltage: 4.0, screenOn: 0),
        // 被过滤：status=2（CHARGING，不在 (3,4)）
        _rec(timeMs: 5, package: 'com.a', mode: 'balance', current: 8888,
            voltage: 4.0, status: 2),
        // 被过滤：package 为空
        _rec(timeMs: 6, package: '', current: 7777),
        // 被过滤：其它 session
        _rec(timeMs: 7, session: 2, package: 'com.a', current: 6666),
        // NOT_CHARGING(4) 也计入
        _rec(timeMs: 8, package: 'com.b', mode: 'perf', current: 150,
            voltage: 4.0, temperature: 50, status: kBatteryStatusNotCharging),
      ];

      final stats = aggregateAppPower(records, session: 1);
      expect(stats.length, 2);

      // Scene `order by current` 升序 → com.b(avg 100) < com.a(avg 150)。
      expect(stats.map((s) => s.package).toList(), <String>['com.b', 'com.a']);

      final b = stats.first;
      expect(b.mode, 'perf');
      expect(b.current, closeTo(100, 1e-9)); // (50 + 150) / 2
      expect(b.power, closeTo(400, 1e-9)); // (50*4 + 150*4) / 2
      expect(b.avgTemperature, closeTo(40, 1e-9)); // (30 + 50) / 2
      expect(b.minTemperature, 30);
      expect(b.maxTemperature, 50);
      expect(b.count, 2);

      final a = stats.last;
      expect(a.current, closeTo(150, 1e-9)); // (100 + 200) / 2
      expect(a.power, closeTo(700, 1e-9)); // (100*4 + 200*5) / 2
      expect(a.avgTemperature, closeTo(30, 1e-9)); // (20 + 40) / 2
      expect(a.count, 2);
    });

    test('会话功耗 = avg(current*voltage)；无样本为 0', () {
      final records = <BatteryHistoryRecord>[
        _rec(timeMs: 1, current: 100, voltage: 4.0),
        _rec(timeMs: 2, current: 200, voltage: 5.0),
        // 过滤项不应参与
        _rec(timeMs: 3, current: 500, voltage: 4.0, screenOn: 0),
      ];
      expect(aggregateSessionPower(records, session: 1), closeTo(700, 1e-9));
      expect(aggregateSessionPower(records, session: 99), 0);
    });

    test('有效样本计数 + 会话记录查询（time 升序）', () {
      final records = <BatteryHistoryRecord>[
        _rec(timeMs: 300, session: 1),
        _rec(timeMs: 100, session: 1),
        _rec(timeMs: 200, session: 2),
      ];
      expect(countSessionSamples(records, session: 1), 2);
      final list = batteryRecordsForSession(records, session: 1);
      expect(list.map((r) => r.time).toList(), <String>['100', '300']);
    });

    test('store 查询委托与纯函数一致', () async {
      final store = InMemoryBatteryHistoryStore();
      await store.appendAll(<BatteryHistoryRecord>[
        _rec(timeMs: 1, package: 'com.a', current: 100, voltage: 4.0),
        _rec(timeMs: 2, package: 'com.a', current: 200, voltage: 4.0),
      ]);
      final apps = await store.appPowerForSession(1);
      expect(apps.single.package, 'com.a');
      expect(apps.single.current, closeTo(150, 1e-9));
      expect(await store.sessionPower(1), closeTo(600, 1e-9));
      expect((await store.recordsForSession(1)).length, 2);
    });
  });
}

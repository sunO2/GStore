import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/charge_history.dart';
import 'package:gstore/core/perf/charge_history_store.dart';

ChargeRecord _rec(
  int time,
  int session, {
  int capacity = 50,
  int current = 1000,
  double voltage = 4.0,
  double temperature = 30.0,
}) =>
    ChargeRecord(
      time: time,
      session: session,
      current: current,
      voltage: voltage,
      capacity: capacity,
      temperature: temperature,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChargeRecord · JSON 往返 / 宽容', () {
    test('字段逐字往返（Scene charge8.records 列名）', () {
      const record = ChargeRecord(
        time: 1710000000000,
        session: 7,
        current: 1523,
        voltage: 4.21,
        capacity: 66,
        temperature: 33.5,
      );
      final json = record.toJson();
      expect(
        json.keys.toList(),
        <String>[
          'time',
          'session',
          'current',
          'voltage',
          'capacity',
          'temperature',
        ],
      );
      expect(ChargeRecord.fromJson(json), record);
    });

    test('缺失 / 非法字段降级为 0，不抛', () {
      final record = ChargeRecord.fromJson(<String, dynamic>{
        'time': '123',
        'session': 1,
        'current': null,
        'voltage': double.nan,
        'temperature': 'bad',
      });
      expect(record.time, 123);
      expect(record.current, 0);
      expect(record.voltage, 0);
      expect(record.capacity, 0);
      expect(record.temperature, 0);
    });

    test('power = current * voltage / 1000（单位 unverified）', () {
      expect(_rec(0, 1, current: 2000, voltage: 4.0).power, closeTo(8.0, 1e-9));
    });
  });

  group('summarizeChargeSessions', () {
    test('按 session 分组、time 升序、capacityRatio = 首−末', () {
      final sessions = summarizeChargeSessions(<ChargeRecord>[
        _rec(300, 2, capacity: 80),
        _rec(100, 1, capacity: 50),
        _rec(400, 2, capacity: 90),
        _rec(200, 1, capacity: 60),
      ]);
      expect(sessions.map((s) => s.session).toList(), <int>[1, 2]);
      expect(sessions[0].startTime, 100);
      expect(sessions[0].endTime, 200);
      expect(sessions[0].startCapacity, 50);
      expect(sessions[0].endCapacity, 60);
      expect(sessions[0].capacityRatio, -10);
      expect(sessions[0].durationMs, 100);
      expect(sessions[0].sampleCount, 2);
      expect(sessions[1].capacityRatio, -10);
    });

    test('空输入 → 空列表', () {
      expect(summarizeChargeSessions(const <ChargeRecord>[]), isEmpty);
    });
  });

  group('pruneChargeHistory', () {
    test('未超上限时保持 time 升序', () {
      final result = pruneChargeHistory(
        <ChargeRecord>[_rec(300, 2), _rec(100, 1), _rec(200, 1)],
      );
      expect(result.map((r) => r.time).toList(), <int>[100, 200, 300]);
    });

    test('超上限丢弃容量摆动幅度最小的会话', () {
      // session1 |−10|、session2 |−40|、session3 |−5|
      final records = <ChargeRecord>[
        _rec(100, 1, capacity: 50),
        _rec(200, 1, capacity: 60),
        _rec(300, 2, capacity: 50),
        _rec(400, 2, capacity: 90),
        _rec(500, 3, capacity: 50),
        _rec(600, 3, capacity: 55),
      ];
      final result =
          pruneChargeHistory(records, maxSessions: 2);
      expect(result.map((r) => r.session).toSet(), <int>{1, 2});
      expect(result.map((r) => r.time).toList(), <int>[100, 200, 300, 400]);
    });
  });

  group('InMemoryChargeHistoryStore', () {
    test('append 按 time 升序；clear', () async {
      final store = InMemoryChargeHistoryStore();
      await store.append(_rec(200, 1));
      await store.append(_rec(100, 1));
      expect(
        (await store.load()).map((r) => r.time).toList(),
        <int>[100, 200],
      );
      await store.clear();
      expect(await store.load(), isEmpty);
    });

    test('save 覆盖写入', () async {
      final store = InMemoryChargeHistoryStore();
      await store.save(<ChargeRecord>[_rec(500, 1), _rec(100, 1)]);
      expect(
        (await store.load()).map((r) => r.time).toList(),
        <int>[100, 500],
      );
    });
  });

  group('SharedPrefsChargeHistoryStore', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('跨实例往返（含会话裁剪）', () async {
      const store = SharedPrefsChargeHistoryStore(maxSessions: 1);
      await store.save(<ChargeRecord>[
        _rec(100, 1, capacity: 50),
        _rec(200, 1, capacity: 60),
        _rec(300, 2, capacity: 50),
        _rec(400, 2, capacity: 90),
      ]);

      const store2 = SharedPrefsChargeHistoryStore(maxSessions: 1);
      final loaded = await store2.load();
      // session2 摆动更大（|−40| > |−10|），保留 session2。
      expect(loaded.map((r) => r.session).toSet(), <int>{2});
      expect(loaded.map((r) => r.time).toList(), <int>[300, 400]);
      expect(loaded.first.voltage, 4.0);
    });

    test('损坏 JSON 静默降级为空列表', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPrefsChargeHistoryStore.storageKey: '{not json',
      });
      expect(await const SharedPrefsChargeHistoryStore().load(), isEmpty);
    });

    test('列表内损坏条目被跳过，其余正常读取', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPrefsChargeHistoryStore.storageKey:
            '[{"time":5,"session":1,"current":1500,"voltage":4.0,'
                '"capacity":50,"temperature":30.0}, 42, '
                '{"time":7,"session":2,"current":1200,"voltage":4.1,'
                '"capacity":60,"temperature":31.0}]',
      });
      final loaded = await const SharedPrefsChargeHistoryStore().load();
      expect(loaded.map((r) => r.session).toList(), <int>[1, 2]);
    });

    test('clear 清空', () async {
      const store = SharedPrefsChargeHistoryStore();
      await store.save(<ChargeRecord>[_rec(100, 1)]);
      await store.clear();
      expect(await store.load(), isEmpty);
    });
  });
}

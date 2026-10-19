// fake_async 是 flutter_test 的传递依赖（未直接列入 pubspec，故忽略该 lint）。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/battery_history.dart';
import 'package:gstore/core/perf/battery_history_recorder.dart';
import 'package:gstore/core/perf/battery_history_store.dart';

/// 可推进时钟。
class _Clock {
  int ms = 1000;
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(ms);
  void advance(int deltaMs) => ms += deltaMs;
}

/// 放电（DISCHARGING）有效样本。
BatteryHistorySample _sample({
  int status = kBatteryStatusDischarging,
  bool screenOn = true,
  double? temperatureC = 33.5,
  double? currentMa = -850,
  double? voltageV = 4.2,
  double? capacityPercent = 61.4,
  String package = 'com.example.app',
  String mode = 'balance',
}) =>
    BatteryHistorySample(
      status: status,
      screenOn: screenOn,
      temperatureC: temperatureC,
      currentMa: currentMa,
      voltageV: voltageV,
      capacityPercent: capacityPercent,
      package: package,
      mode: mode,
    );

void main() {
  group('状态映射 batteryStatusFromLabel（todo 33）', () {
    test('sysfs 状态字符串 → Android BATTERY_STATUS_*', () {
      expect(batteryStatusFromLabel('Charging'), kBatteryStatusCharging);
      expect(batteryStatusFromLabel('charging'), kBatteryStatusCharging);
      expect(batteryStatusFromLabel('Discharging'), kBatteryStatusDischarging);
      expect(batteryStatusFromLabel('Not charging'), kBatteryStatusNotCharging);
      expect(batteryStatusFromLabel('Full'), kBatteryStatusFull);
      expect(batteryStatusFromLabel('Unknown'), kBatteryStatusUnknown);
      expect(batteryStatusFromLabel(null), kBatteryStatusUnknown);
      expect(batteryStatusFromLabel('  '), kBatteryStatusUnknown);
    });
  });

  group('记录器门控（Scene PowerStat 等价）', () {
    test('亮屏 + 放电 → 落库一行（字段逐字对齐 power8.records）', () async {
      final clock = _Clock();
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(
        store: store,
        clock: clock.now,
        session: 7,
        sampler: () async => _sample(),
      );

      expect(await recorder.sampleOnce(), isTrue);
      final rows = await store.load();
      expect(rows.length, 1);
      final row = rows.single;
      expect(row.time, '1000');
      expect(row.session, 7);
      expect(row.temperature, 33.5);
      expect(row.status, kBatteryStatusDischarging);
      expect(row.mode, 'balance');
      expect(row.current, -850);
      expect(row.voltage, 4.2);
      expect(row.package, 'com.example.app');
      expect(row.screenOn, 1);
      expect(row.capacity, 61); // 61.4.round()
      expect(recorder.insertedCount, 1);
      recorder.dispose();
    });

    test('状态 == 2（CHARGING）→ 不落库', () async {
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(
        store: store,
        sampler: () async => _sample(status: kBatteryStatusCharging),
      );
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      recorder.dispose();
    });

    test('状态 == 5（FULL）→ 不落库', () async {
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(
        store: store,
        sampler: () async => _sample(status: kBatteryStatusFull),
      );
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      recorder.dispose();
    });

    test('熄屏 → 不落库，计入熄屏跳过数', () async {
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(
        store: store,
        sampler: () async => _sample(screenOn: false),
      );
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      expect(recorder.skippedForScreenOffCount, 1);
      recorder.dispose();
    });

    test('数值缺失 / 非有限 → 不落库', () async {
      final store = InMemoryBatteryHistoryStore();
      for (final sampler in <BatteryHistorySampler>[
        () async => _sample(currentMa: null),
        () async => _sample(voltageV: null),
        () async => _sample(voltageV: 0), // Scene `if (dP > 0)`：非正电压丢弃
        () async => _sample(voltageV: double.nan),
        () async => _sample(temperatureC: null),
        () async => _sample(capacityPercent: null),
      ]) {
        final recorder =
            BatteryHistoryRecorder(store: store, sampler: sampler);
        expect(await recorder.sampleOnce(), isFalse);
        recorder.dispose();
      }
      expect(await store.load(), isEmpty);
    });

    test('sampler 返回 null → 跳过（不抛、不落库）', () async {
      final store = InMemoryBatteryHistoryStore();
      final recorder =
          BatteryHistoryRecorder(store: store, sampler: () async => null);
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      recorder.dispose();
    });

    test('sampler 抛异常（权限 / Shizuku 拒绝）→ 跳过本拍，绝不抛出', () async {
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(
        store: store,
        sampler: () async => throw StateError('shizuku denied'),
      );
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      recorder.dispose();
    });
  });

  group('buildBatteryHistoryRecord 纯函数', () {
    test('门控通过 → 记录字段正确（time 为字符串、screen_on=1）', () {
      final record = buildBatteryHistoryRecord(
        _sample(),
        time: 1234567890,
        session: 42,
      );
      expect(record, isNotNull);
      expect(record!.time, '1234567890');
      expect(record.session, 42);
      expect(record.status, kBatteryStatusDischarging);
      expect(record.screenOn, 1);
      expect(record.package, 'com.example.app');
    });

    test('门控不通过 → null', () {
      expect(
        buildBatteryHistoryRecord(
          _sample(status: kBatteryStatusCharging),
          time: 1,
          session: 1,
        ),
        isNull,
      );
      expect(
        buildBatteryHistoryRecord(
          _sample(screenOn: false),
          time: 1,
          session: 1,
        ),
        isNull,
      );
    });

    test('passesBatteryHistoryGate：UNKNOWN 状态（非充电/满电）仍可落库', () {
      expect(
        passesBatteryHistoryGate(_sample(status: kBatteryStatusUnknown)),
        isTrue,
      );
      expect(
        passesBatteryHistoryGate(
          _sample(status: kBatteryStatusNotCharging),
        ),
        isTrue,
      );
    });
  });

  group('会话 id', () {
    test('未注入 session 时默认取启动时刻（clock ms）', () {
      final clock = _Clock()..ms = 1712345678;
      final store = InMemoryBatteryHistoryStore();
      final recorder =
          BatteryHistoryRecorder(store: store, clock: clock.now);
      expect(recorder.sessionId, 1712345678);
      recorder.dispose();
    });

    test('start(session:) 覆盖当前会话 id', () {
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(store: store, session: 1);
      recorder.start(session: 99);
      expect(recorder.sessionId, 99);
      recorder.dispose();
    });
  });

  group('3s 采样定时器（Scene a0.e(1000L, 3000L)）', () {
    test('start 后按初始延迟 + 3s 周期采样并落库；stop 停表', () {
      fakeAsync((async) {
        final clock = _Clock();
        final store = InMemoryBatteryHistoryStore();
        final recorder = BatteryHistoryRecorder(
          store: store,
          clock: clock.now,
          initialDelay: Duration.zero,
          interval: const Duration(seconds: 3),
          session: 3,
          sampler: () async => _sample(),
        );

        recorder.start();
        expect(recorder.isRecording, isTrue);

        clock.advance(1000);
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        // 初始 tick + 1 个 3s 周期 tick。
        expect(recorder.insertedCount, 2);

        recorder.stop();
        async.flushMicrotasks();
        expect(recorder.isRecording, isFalse);

        final countAtStop = recorder.insertedCount;
        clock.advance(9000);
        async.elapse(const Duration(seconds: 9));
        async.flushMicrotasks();
        expect(recorder.insertedCount, countAtStop);

        recorder.dispose();
        async.flushMicrotasks();

        List<BatteryHistoryRecord> rows = <BatteryHistoryRecord>[];
        store.load().then((value) => rows = value);
        async.flushMicrotasks();
        expect(rows.length, 2);
      });
    });

    test('dispose 后 start 为 no-op（幂等释放）', () {
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(
        store: store,
        sampler: () async => _sample(),
      );
      recorder.dispose();
      recorder.start();
      expect(recorder.isRecording, isFalse);
      expect(recorder.isDisposed, isTrue);
    });
  });

  group('默认单例', () {
    test('batteryHistoryRecorder 使用 SharedPrefs store 且初始未录制', () {
      expect(batteryHistoryRecorder.isRecording, isFalse);
      expect(batteryHistoryRecorder.isDisposed, isFalse);
    });
  });
}

// fake_async 是 flutter_test 的传递依赖（未直接列入 pubspec，故忽略该 lint）。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/charge_history.dart';
import 'package:gstore/core/perf/charge_history_recorder.dart';
import 'package:gstore/core/perf/charge_history_store.dart';

/// 可推进时钟。
class _Clock {
  int ms = 1000;
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(ms);
  void advance(int deltaMs) => ms += deltaMs;
}

ChargeSnapshot _snapshot({
  double? currentMa = 1500,
  double? voltageV = 4.2,
  double? capacityPercent = 55,
  double? temperatureC = 33.5,
  String? status = 'Charging',
}) =>
    ChargeSnapshot(
      currentMa: currentMa,
      voltageV: voltageV,
      capacityPercent: capacityPercent,
      temperatureC: temperatureC,
      status: status,
    );

void main() {
  group('门控（todo 33 取证：status==2 && |current|>100）', () {
    test('充电且 |current|>100 → 落库一行（字段正确）', () async {
      final clock = _Clock();
      final store = InMemoryChargeHistoryStore();
      final recorder = ChargeHistoryRecorder(
        store: store,
        clock: clock.now,
        session: 7,
        sampler: () async => _snapshot(),
      );

      expect(await recorder.sampleOnce(), isTrue);
      final rows = await store.load();
      expect(rows.length, 1);
      final row = rows.single;
      expect(row.time, 1000);
      expect(row.session, 7);
      expect(row.current, 1500);
      expect(row.voltage, 4.2);
      expect(row.capacity, 55);
      expect(row.temperature, 33.5);
      expect(recorder.insertedCount, 1);
      recorder.dispose();
    });

    test('|current| == 100（非严格大于）→ 不落库', () async {
      final store = InMemoryChargeHistoryStore();
      final recorder = ChargeHistoryRecorder(
        store: store,
        sampler: () async => _snapshot(currentMa: 100),
      );
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      recorder.dispose();
    });

    test('|current| == 99 → 不落库（低于门限）', () async {
      final store = InMemoryChargeHistoryStore();
      final recorder = ChargeHistoryRecorder(
        store: store,
        sampler: () async => _snapshot(currentMa: 99),
      );
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      recorder.dispose();
    });

    test('非充电（Discharging）→ 不落库', () async {
      final store = InMemoryChargeHistoryStore();
      final recorder = ChargeHistoryRecorder(
        store: store,
        sampler: () async => _snapshot(status: 'Discharging'),
      );
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      recorder.dispose();
    });

    test('充电但 current 缺失（invalid）→ 不落库', () async {
      final store = InMemoryChargeHistoryStore();
      final recorder = ChargeHistoryRecorder(
        store: store,
        sampler: () async => _snapshot(currentMa: null),
      );
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      recorder.dispose();
    });

    test('充电且电流达标但 voltage/capacity/temperature 缺失 → 不落库', () async {
      final store = InMemoryChargeHistoryStore();
      final recorder = ChargeHistoryRecorder(
        store: store,
        sampler: () async => _snapshot(voltageV: null),
      );
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      recorder.dispose();
    });

    test('sampler 抛异常 → 跳过本拍，不抛', () async {
      final store = InMemoryChargeHistoryStore();
      final recorder = ChargeHistoryRecorder(
        store: store,
        sampler: () async => throw StateError('boom'),
      );
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      recorder.dispose();
    });
  });

  group('1s 采样定时器', () {
    test('start 后按初始延迟 + 1s 周期采样并落库；stop 停表', () {
      fakeAsync((async) {
        final clock = _Clock();
        final store = InMemoryChargeHistoryStore();
        final recorder = ChargeHistoryRecorder(
          store: store,
          clock: clock.now,
          initialDelay: Duration.zero,
          interval: const Duration(seconds: 1),
          session: 3,
          sampler: () async => _snapshot(),
        );

        recorder.start();
        expect(recorder.isRecording, isTrue);

        clock.advance(1000);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        // 初始 tick + 1s 周期 tick。
        expect(recorder.insertedCount, 2);

        recorder.stop();
        async.flushMicrotasks();
        expect(recorder.isRecording, isFalse);

        final countAtStop = recorder.insertedCount;
        clock.advance(3000);
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(recorder.insertedCount, countAtStop);

        recorder.dispose();
        async.flushMicrotasks();

        List<ChargeRecord> rows = <ChargeRecord>[];
        store.load().then((value) => rows = value);
        async.flushMicrotasks();
        expect(rows.length, 2);
      });
    });
  });
}

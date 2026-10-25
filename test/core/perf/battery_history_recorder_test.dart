// fake_async 是 flutter_test 的传递依赖（未直接列入 pubspec，故忽略该 lint）。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/battery_history.dart';
import 'package:gstore/core/perf/battery_history_recorder.dart';
import 'package:gstore/core/perf/battery_history_store.dart';
import 'package:gstore/core/perf/battery_source.dart';
import 'package:gstore/core/perf/privileged_shell.dart';

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

    test('状态 == 2（CHARGING）→ 仍落库（放宽：充电行也记录）', () async {
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(
        store: store,
        sampler: () async => _sample(status: kBatteryStatusCharging),
      );
      expect(await recorder.sampleOnce(), isTrue);
      final rows = await store.load();
      expect(rows.length, 1);
      expect(rows.single.status, kBatteryStatusCharging);
      expect(recorder.lastSkipReason, 'stored');
      recorder.dispose();
    });

    test('状态 == 5（FULL）→ 仍落库（放宽：满电行也记录）', () async {
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(
        store: store,
        sampler: () async => _sample(status: kBatteryStatusFull),
      );
      expect(await recorder.sampleOnce(), isTrue);
      final rows = await store.load();
      expect(rows.length, 1);
      expect(rows.single.status, kBatteryStatusFull);
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
      expect(recorder.lastSkipReason, 'screen_off');
      recorder.dispose();
    });

    test('温度缺失（其余完整）→ 仍落库（温度可选，缺省 -1）', () async {
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(
        store: store,
        sampler: () async => _sample(temperatureC: null),
      );
      expect(await recorder.sampleOnce(), isTrue);
      final row = (await store.load()).single;
      expect(row.temperature, -1); // Scene DDL 缺省
      expect(recorder.lastSkipReason, 'stored');
      recorder.dispose();
    });

    test('缺电流 / 电压但容量存在 → 落库（power pair 或 level 二选一）', () async {
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(
        store: store,
        sampler: () async => _sample(currentMa: null, voltageV: null),
      );
      expect(await recorder.sampleOnce(), isTrue);
      final row = (await store.load()).single;
      expect(row.current, -1);
      expect(row.voltage, 0);
      expect(row.capacity, 61);
      recorder.dispose();
    });

    test('缺容量但有电流 + 电压 → 落库（capacity 缺省 0）', () async {
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(
        store: store,
        sampler: () async => _sample(capacityPercent: null),
      );
      expect(await recorder.sampleOnce(), isTrue);
      final row = (await store.load()).single;
      expect(row.capacity, 0);
      expect(row.current, -850);
      expect(row.voltage, 4.2);
      recorder.dispose();
    });

    test('电流 / 电压 / 容量全缺 → 不落库（incomplete）', () async {
      final store = InMemoryBatteryHistoryStore();
      final recorder = BatteryHistoryRecorder(
        store: store,
        sampler: () async => _sample(
          currentMa: null,
          voltageV: null,
          capacityPercent: null,
        ),
      );
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      expect(recorder.lastSkipReason, 'incomplete');
      recorder.dispose();
    });

    test('非有限值（NaN / Infinity）/ 非正电压 → 不落库', () async {
      final store = InMemoryBatteryHistoryStore();
      for (final sampler in <BatteryHistorySampler>[
        () async => _sample(voltageV: 0), // Scene `if (dP > 0)`：非正电压丢弃
        () async => _sample(voltageV: double.nan),
        () async => _sample(currentMa: double.nan),
        () async => _sample(temperatureC: double.nan),
        () async => _sample(capacityPercent: double.infinity),
      ]) {
        final recorder =
            BatteryHistoryRecorder(store: store, sampler: sampler);
        expect(await recorder.sampleOnce(), isFalse);
        recorder.dispose();
      }
      expect(await store.load(), isEmpty);
    });

    test('sampler 返回 null → 跳过（no_reading，不抛、不落库）', () async {
      final store = InMemoryBatteryHistoryStore();
      final recorder =
          BatteryHistoryRecorder(store: store, sampler: () async => null);
      expect(await recorder.sampleOnce(), isFalse);
      expect(await store.load(), isEmpty);
      expect(recorder.lastSkipReason, 'no_reading');
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
      expect(recorder.lastSkipReason, 'no_reading');
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

    test('门控不通过 → null（不完整 / 熄屏）', () {
      expect(
        buildBatteryHistoryRecord(
          _sample(currentMa: null, voltageV: null, capacityPercent: null),
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

    test('充电 / 满电 → 门控通过（交由聚合侧排除）', () {
      expect(
        buildBatteryHistoryRecord(
          _sample(status: kBatteryStatusCharging),
          time: 1,
          session: 1,
        ),
        isNotNull,
      );
      expect(
        buildBatteryHistoryRecord(
          _sample(status: kBatteryStatusFull),
          time: 1,
          session: 1,
        ),
        isNotNull,
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

    test('start 重复调用幂等：只起一个定时器（不重复落库）', () {
      fakeAsync((async) {
        final clock = _Clock();
        final store = InMemoryBatteryHistoryStore();
        final recorder = BatteryHistoryRecorder(
          store: store,
          clock: clock.now,
          initialDelay: Duration.zero,
          interval: const Duration(seconds: 3),
          session: 1,
          sampler: () async => _sample(),
        );

        recorder.start();
        recorder.start(); // 幂等：no-op，不得起第二个定时器
        clock.advance(1000);
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        // 单定时器：初始 tick + 1 个周期 tick = 2；若重复起表则为 4。
        expect(recorder.insertedCount, 2);

        recorder.stop();
        recorder.stop(); // 幂等：no-op
        async.flushMicrotasks();
        expect(recorder.isRecording, isFalse);

        recorder.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('默认采样器：探测缓存 + 无 per-tick dumpsys', () {
    tearDown(BatteryHistoryRecorder.resetTestSeams);

    BatteryReading reading({bool? interactive}) => BatteryReading(
          present: true,
          capacityPercent: 50,
          currentMa: -500,
          voltageV: 4.0,
          statusCode: kBatteryStatusDischarging,
          interactive: interactive,
        );

    test('interactive=true → 不探测屏幕；前台 15s 缓存；无 dumpsys battery',
        () async {
      var now = DateTime.fromMillisecondsSinceEpoch(0);
      final commands = <String>[];
      BatteryHistoryRecorder.configureForTest(
        clock: () => now,
        shellRunner: (command) async {
          commands.add(command);
          // ok=false → 前台包名空串，且不触碰 PerfModule.foreground（FFI）。
          return const PrivilegedResult(ok: false, output: '');
        },
      );

      Future<BatteryHistorySample?> sample() =>
          BatteryHistoryRecorder.sampleForTest(
            readBattery: () async => reading(interactive: true),
          );

      final first = await sample();
      expect(first, isNotNull);
      expect(first!.screenOn, isTrue);
      // 只有前台探测；屏幕由 interactive 提供，不跑 dumpsys power。
      expect(commands, <String>[BatteryHistoryRecorder.foregroundCommand]);
      expect(
        commands.where((c) => c.contains('dumpsys battery')),
        isEmpty,
      );

      // 10s 后（前台 TTL 15s 内）→ 缓存命中，无新命令。
      now = now.add(const Duration(seconds: 10));
      await sample();
      expect(commands, hasLength(1));

      // 再过 6s（累计 16s）→ 前台缓存过期，仅重跑前台探测。
      now = now.add(const Duration(seconds: 6));
      await sample();
      expect(commands, hasLength(2));
      expect(commands.last, BatteryHistoryRecorder.foregroundCommand);
    });

    test('interactive=null → dumpsys power 探测缓存 30s', () async {
      var now = DateTime.fromMillisecondsSinceEpoch(0);
      final commands = <String>[];
      BatteryHistoryRecorder.configureForTest(
        clock: () => now,
        shellRunner: (command) async {
          commands.add(command);
          return const PrivilegedResult(ok: false, output: '');
        },
      );

      Future<BatteryHistorySample?> sample() =>
          BatteryHistoryRecorder.sampleForTest(
            readBattery: () async => reading(interactive: null),
          );

      await sample();
      // 屏幕 + 前台各一次。
      expect(commands, <String>[
        BatteryHistoryRecorder.screenCommand,
        BatteryHistoryRecorder.foregroundCommand,
      ]);

      // 10s 内：两者都在缓存内。
      now = now.add(const Duration(seconds: 10));
      await sample();
      expect(commands, hasLength(2));

      // 16s：仅前台过期。
      now = now.add(const Duration(seconds: 6));
      await sample();
      expect(commands, hasLength(3));
      expect(commands.last, BatteryHistoryRecorder.foregroundCommand);

      // 31s：屏幕（30s）与前台都过期。
      now = now.add(const Duration(seconds: 15));
      await sample();
      expect(commands, hasLength(5));
      expect(commands[3], BatteryHistoryRecorder.screenCommand);
      expect(
        commands.where((c) => c.contains('dumpsys battery')),
        isEmpty,
      );
    });
  });

  group('默认单例', () {
    test('batteryHistoryRecorder 使用 SharedPrefs store 且初始未录制', () {
      expect(batteryHistoryRecorder.isRecording, isFalse);
      expect(batteryHistoryRecorder.isDisposed, isFalse);
    });
  });
}

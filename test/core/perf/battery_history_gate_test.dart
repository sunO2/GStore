// 电池历史采样器门控（默认 OFF）：仅当 `perf.history.enabled == true` 时启动，
// 关闭 / 未设置 / 读取失败时**不启动、不构造单例**（因而不触碰 Rust PerfModule）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/battery_history_gate.dart';
import 'package:gstore/core/perf/battery_history_recorder.dart';
import 'package:gstore/core/perf/battery_history_store.dart';

/// 记录 start/stop 调用的假记录器：覆盖 `start` / `stop` / `isRecording`，
/// 不起真实定时器（门控单测无需时间推进）。
class _FakeRecorder extends BatteryHistoryRecorder {
  _FakeRecorder() : super(store: InMemoryBatteryHistoryStore());

  int startCalls = 0;
  int stopCalls = 0;
  bool recording = false;

  @override
  bool get isRecording => recording;

  @override
  void start({int? session}) {
    startCalls++;
    recording = true;
  }

  @override
  void stop() {
    stopCalls++;
    recording = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('startBatteryHistoryRecorderIfEnabled（默认 OFF 门控）', () {
    test('未设置（null）→ 不启动，且不取记录器（不触碰 perf 模块）', () async {
      var getterCalls = 0;
      final started = await startBatteryHistoryRecorderIfEnabled(
        readEnabled: () async => null,
        recorder: () {
          getterCalls++;
          return _FakeRecorder();
        },
      );
      expect(started, isFalse);
      expect(getterCalls, 0, reason: '关闭时不得构造单例 / 触碰 Rust PerfModule');
    });

    test('false → 不启动采样器', () async {
      final recorder = _FakeRecorder();
      final started = await startBatteryHistoryRecorderIfEnabled(
        readEnabled: () async => false,
        recorder: () => recorder,
      );
      expect(started, isFalse);
      expect(recorder.startCalls, 0);
      expect(recorder.isRecording, isFalse);
    });

    test('true → 启动采样器并记录启动日志', () async {
      final recorder = _FakeRecorder();
      final logs = <String>[];
      final started = await startBatteryHistoryRecorderIfEnabled(
        readEnabled: () async => true,
        recorder: () => recorder,
        log: logs.add,
      );
      expect(started, isTrue);
      expect(recorder.startCalls, 1);
      expect(recorder.isRecording, isTrue);
      expect(logs.single, contains('电池历史采样器已启动'));
    });

    test('读取配置失败 → 按关闭处理（绝不抛出）', () async {
      final recorder = _FakeRecorder();
      final started = await startBatteryHistoryRecorderIfEnabled(
        readEnabled: () async => throw StateError('config unavailable'),
        recorder: () => recorder,
      );
      expect(started, isFalse);
      expect(recorder.startCalls, 0);
    });

    test('start 抛异常 → 返回 false（best-effort，不抛出）', () async {
      final started = await startBatteryHistoryRecorderIfEnabled(
        readEnabled: () async => true,
        recorder: () => throw StateError('start boom'),
      );
      expect(started, isFalse);
    });

    test('生产单例初始未录制（未启用时 main 不启动）', () {
      expect(batteryHistoryRecorder.isRecording, isFalse);
    });
  });

  group('main.dart 接线', () {
    test('经门控启动：不再有无条件 _startBatteryHistoryRecorder(); 调用', () {
      final source = File('lib/main.dart').readAsStringSync();
      expect(
        source.contains('startBatteryHistoryRecorderIfEnabled'),
        isTrue,
        reason: '启动必须经门控 helper 读取 perf.history.enabled',
      );
      expect(
        RegExp(r'^\s*_startBatteryHistoryRecorder\(\);', multiLine: true)
            .hasMatch(source),
        isFalse,
        reason: '不得保留无条件启动调用',
      );
    });
  });
}

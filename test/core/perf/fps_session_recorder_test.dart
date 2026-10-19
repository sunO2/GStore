// fake_async 是 flutter_test 的传递依赖（未直接列入 pubspec，故忽略该 lint）。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/fps_session.dart';
import 'package:gstore/core/perf/fps_session_recorder.dart';
import 'package:gstore/core/perf/fps_session_store.dart';

/// 可推进时钟（与 fakeAsync 的定时器同步由测试手工维护）。
class _Clock {
  int ms = 1000;
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(ms);
  void advance(int deltaMs) => ms += deltaMs;
}

void main() {
  test('采样统计 avg/min/max 并落盘（60,60,30）', () {
    fakeAsync((async) {
      final clock = _Clock();
      final store = InMemoryFpsSessionStore();
      final sequence = <double>[60, 60, 30];
      var index = 0;
      final recorder = FpsSessionRecorder(
        store: store,
        clock: clock.now,
        sampler: () async => index < sequence.length ? sequence[index++] : null,
        maxDuration: null,
      );

      recorder.start(label: '测试');
      expect(recorder.isRecording, isTrue);

      for (var i = 0; i < 3; i++) {
        clock.advance(1000);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
      }
      expect(recorder.sampleCount, 3);
      expect(recorder.currentFps, 30);
      expect(recorder.elapsed, const Duration(seconds: 3));

      FpsSession? saved;
      recorder.stop().then((value) => saved = value);
      async.flushMicrotasks();

      expect(saved, isNotNull);
      expect(saved!.avg, closeTo(50, 1e-9));
      expect(saved!.min, 30);
      expect(saved!.max, 60);
      expect(saved!.fps, 30);
      expect(saved!.sampleCount, 3);
      expect(saved!.label, '测试');
      expect(recorder.isRecording, isFalse);

      List<FpsSession> persisted = <FpsSession>[];
      store.load().then((list) => persisted = list);
      async.flushMicrotasks();
      expect(persisted.length, 1);
      expect(persisted.first.id, saved!.id);

      recorder.dispose();
    });
  });

  test('跳过非法样本（null / NaN / Infinity / 负值）', () {
    fakeAsync((async) {
      final clock = _Clock();
      final store = InMemoryFpsSessionStore();
      final sequence = <double?>[60, null, -1, double.nan, 30, double.infinity];
      var index = 0;
      final recorder = FpsSessionRecorder(
        store: store,
        clock: clock.now,
        sampler: () async =>
            index < sequence.length ? sequence[index++] : null,
        maxDuration: null,
      );

      recorder.start();
      for (var i = 0; i < sequence.length; i++) {
        clock.advance(1000);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
      }

      expect(recorder.sampleCount, 2);
      expect(recorder.samples, <double>[60, 30]);
      expect(recorder.currentFps, 30);
      recorder.dispose();
    });
  });

  test('采样异常被跳过，不中断录制', () {
    fakeAsync((async) {
      final clock = _Clock();
      var calls = 0;
      final recorder = FpsSessionRecorder(
        store: InMemoryFpsSessionStore(),
        clock: clock.now,
        sampler: () async {
          calls++;
          if (calls == 1) throw StateError('boom');
          return 55;
        },
        maxDuration: null,
      );

      recorder.start();
      clock.advance(1000);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(recorder.sampleCount, 0);

      clock.advance(1000);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(recorder.sampleCount, 1);
      expect(recorder.currentFps, 55);

      recorder.cancel();
      recorder.dispose();
    });
  });

  test('cancel 丢弃当前会话且不落盘；未录制时 stop 返回 null', () {
    fakeAsync((async) {
      final clock = _Clock();
      final store = InMemoryFpsSessionStore();
      final recorder = FpsSessionRecorder(
        store: store,
        clock: clock.now,
        sampler: () async => 60,
        maxDuration: null,
      );

      recorder.start();
      clock.advance(1000);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(recorder.sampleCount, 1);

      recorder.cancel();
      expect(recorder.isRecording, isFalse);
      expect(recorder.sampleCount, 0);

      List<FpsSession> persisted = <FpsSession>[];
      store.load().then((list) => persisted = list);
      async.flushMicrotasks();
      expect(persisted, isEmpty);

      FpsSession? result;
      recorder.stop().then((value) => result = value);
      async.flushMicrotasks();
      expect(result, isNull);

      recorder.dispose();
    });
  });

  test('start 幂等：重复调用不重置累计', () {
    fakeAsync((async) {
      final clock = _Clock();
      final recorder = FpsSessionRecorder(
        store: InMemoryFpsSessionStore(),
        clock: clock.now,
        sampler: () async => 60,
        maxDuration: null,
      );

      recorder.start();
      clock.advance(1000);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(recorder.sampleCount, 1);

      // 重复 start：no-op，不重置样本，计时器仍唯一。
      recorder.start();
      expect(recorder.sampleCount, 1);

      clock.advance(1000);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(recorder.sampleCount, 2);

      recorder.dispose();
    });
  });

  test('超过 maxDuration 自动停止并落盘', () {
    fakeAsync((async) {
      final clock = _Clock();
      final store = InMemoryFpsSessionStore();
      final recorder = FpsSessionRecorder(
        store: store,
        clock: clock.now,
        sampler: () async => 60,
        maxDuration: const Duration(seconds: 3),
      );

      recorder.start();
      for (var i = 0; i < 3; i++) {
        clock.advance(1000);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
      }

      expect(recorder.isRecording, isFalse);

      List<FpsSession> persisted = <FpsSession>[];
      store.load().then((list) => persisted = list);
      async.flushMicrotasks();
      expect(persisted.length, 1);
      expect(persisted.first.sampleCount, 3);

      // 自动停止后计时器已取消，继续推进不会新增样本。
      clock.advance(5000);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(recorder.isRecording, isFalse);

      recorder.dispose();
    });
  });

  test('dispose 取消定时器，之后不再采样', () {
    fakeAsync((async) {
      final clock = _Clock();
      var calls = 0;
      final recorder = FpsSessionRecorder(
        store: InMemoryFpsSessionStore(),
        clock: clock.now,
        sampler: () async {
          calls++;
          return 60;
        },
        maxDuration: null,
      );

      recorder.start();
      clock.advance(1000);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(calls, 1);

      recorder.dispose();
      clock.advance(5000);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(calls, 1);
    });
  });
}

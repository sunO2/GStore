// 性能页「后台采样」开关联动电池历史采样器：
// 开启 → start() 并持久化 perf.history.enabled=true；
// 关闭 → stop() 并持久化 false；重复开启幂等。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/battery_history_recorder.dart';
import 'package:gstore/core/perf/battery_history_store.dart';
import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/perf_history_store.dart';
import 'package:gstore/core/perf/perf_target_store.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/logic.dart';

/// 就绪网关：`perf.start` 返回 `running=true`，`perf.stop` 返回 `running=false`，
/// 其余方法返回空 `data` 信封（不触碰 FFI）。
class _ReadyGateway implements PerfModuleGateway {
  final StreamController<PerfRawEvent> _events =
      StreamController<PerfRawEvent>.broadcast();

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    final Map<String, dynamic> data = switch (method) {
      'perf.start' => <String, dynamic>{'running': true, 'interval_ms': 2000},
      'perf.stop' => <String, dynamic>{'running': false, 'was_running': true},
      _ => <String, dynamic>{},
    };
    return Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );
  }

  @override
  Stream<PerfRawEvent> get events => _events.stream;
}

/// 内存历史存储：绕过真实文件 I/O。
class _FakeHistoryStore extends PerfHistoryStore {
  @override
  Future<PerfHistorySnapshot> load() async => const PerfHistorySnapshot();

  @override
  Future<void> save(PerfHistorySnapshot snapshot) async {}
}

/// 记录 start/stop 调用的假记录器（覆盖 start/stop/isRecording，避免真实定时器）。
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

ProviderContainer _container({
  required _FakeRecorder recorder,
  required List<bool> writes,
}) {
  return ProviderContainer(
    overrides: <Override>[
      perfModuleProvider.overrideWithValue(PerfModule(gateway: _ReadyGateway())),
      perfFrameMonitorProvider.overrideWithValue(FrameMonitor()),
      perfAvailabilityStreamProvider.overrideWithValue(
        Stream<PerfAvailability>.value(PerfAvailability.ready),
      ),
      perfHistoryStoreProvider.overrideWithValue(_FakeHistoryStore()),
      perfTargetStoreProvider.overrideWithValue(InMemoryPerfTargetStore()),
      perfBatteryHistoryRecorderProvider.overrideWithValue(recorder),
      perfHistoryEnabledWriterProvider.overrideWithValue((bool value) async {
        writes.add(value);
        return true;
      }),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('开启采样 → 启动电池历史采样器并持久化 true', () async {
    final recorder = _FakeRecorder();
    final writes = <bool>[];
    final container = _container(recorder: recorder, writes: writes);
    addTearDown(container.dispose);

    await container.read(perfMonitorProvider.notifier).toggleSampling(true);

    expect(recorder.isRecording, isTrue);
    expect(recorder.startCalls, 1);
    expect(writes, <bool>[true]);
  });

  test('关闭采样 → 停止采样器并持久化 false', () async {
    final recorder = _FakeRecorder();
    final writes = <bool>[];
    final container = _container(recorder: recorder, writes: writes);
    addTearDown(container.dispose);

    final notifier = container.read(perfMonitorProvider.notifier);
    await notifier.toggleSampling(true);
    await notifier.toggleSampling(false);

    expect(recorder.isRecording, isFalse);
    expect(recorder.stopCalls, 1);
    expect(writes, <bool>[true, false]);
  });

  test('重复开启幂等：仍在录制，不产生异常', () async {
    final recorder = _FakeRecorder();
    final writes = <bool>[];
    final container = _container(recorder: recorder, writes: writes);
    addTearDown(container.dispose);

    final notifier = container.read(perfMonitorProvider.notifier);
    await notifier.toggleSampling(true);
    await notifier.toggleSampling(true);

    expect(recorder.isRecording, isTrue);
    expect(writes, <bool>[true, true]);
  });

  test('未开启时采样器保持未录制（默认 OFF）', () async {
    final recorder = _FakeRecorder();
    final container = _container(recorder: recorder, writes: <bool>[]);
    addTearDown(container.dispose);

    // 仅构建 provider（打开性能页）不启动采样器。
    container.read(perfMonitorProvider);
    await Future<void>.delayed(Duration.zero);

    expect(recorder.isRecording, isFalse);
    expect(recorder.startCalls, 0);
  });
}

// fake_async 是 flutter_test 的传递依赖（未直接列入 pubspec，故忽略该 lint）。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/perf_auto_export_service.dart';
import 'package:gstore/core/perf/perf_auto_export_settings.dart';
import 'package:gstore/core/perf/perf_report_store.dart';

/// 内存报告存储：绕过真实文件 I/O，可开关失败注入。
class _MemoryReportStore extends PerfReportStore {
  _MemoryReportStore() : super(baselineStore: InMemoryBaselineStore());

  final List<SavedPerfReport> reports = <SavedPerfReport>[];
  bool failSave = false;
  bool failList = false;

  @override
  Future<SavedPerfReport> saveReport({
    required PerfReportFormat format,
    required String content,
    required DateTime timestamp,
  }) async {
    if (failSave) throw StateError('save boom');
    final saved = SavedPerfReport(
      path:
          '/mem/perf_${timestamp.millisecondsSinceEpoch}.${format.extension}',
      format: format,
      timestamp: timestamp,
    );
    reports.add(saved);
    return saved;
  }

  @override
  Future<List<SavedPerfReport>> listReports() async {
    if (failList) throw StateError('list boom');
    return List<SavedPerfReport>.of(reports)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  @override
  Future<String?> readReport(String path) async => 'content';

  @override
  Future<bool> deleteReport(String path) async {
    reports.removeWhere((report) => report.path == path);
    return true;
  }
}

/// 递增时钟：每次调用前进 1 秒（保证同一 test 内时间戳唯一）。
DateTime Function() _steppingClock() {
  var tick = 0;
  return () => DateTime.fromMillisecondsSinceEpoch(1000 + (tick++) * 1000);
}

PerfAutoExportService _service(
  _MemoryReportStore store, {
  required PerfAutoExportSettings Function() settings,
  DateTime Function()? clock,
}) =>
    PerfAutoExportService(
      store: store,
      buildContent: (_, __) async => 'content',
      settings: settings,
      clock: clock ?? _steppingClock(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('未启用：start 不建定时器，exportNow 落 0 份', () async {
    final store = _MemoryReportStore();
    final service = _service(
      store,
      settings: () => PerfAutoExportSettings.defaults,
    );

    service.start();
    expect(service.isRunning, isFalse);
    expect(await service.exportNow(), 0);
    expect(store.reports, isEmpty);
    service.dispose();
  });

  test('start 后按 intervalMinutes 周期落盘（fakeAsync 推进）', () {
    fakeAsync((async) {
      final store = _MemoryReportStore();
      final service = _service(
        store,
        settings: () => const PerfAutoExportSettings(
          enabled: true,
          intervalMinutes: 2,
        ),
      );

      service.start();
      expect(service.isRunning, isTrue);

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(store.reports, isEmpty, reason: '未到 2 分钟不落盘');

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(store.reports.length, 1);

      async.elapse(const Duration(minutes: 2));
      async.flushMicrotasks();
      expect(store.reports.length, 2);

      service.dispose();
      expect(service.isRunning, isFalse);
    });
  });

  test('间隔下限钳制：intervalMinutes=0 实际按 1 分钟', () {
    fakeAsync((async) {
      final store = _MemoryReportStore();
      final service = _service(
        store,
        settings: () => const PerfAutoExportSettings(
          enabled: true,
          intervalMinutes: 0,
        ),
      );

      service.start();
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(store.reports.length, 1);
      service.dispose();
    });
  });

  test('exportNow 裁剪到 maxKeep（删除最旧）', () async {
    final store = _MemoryReportStore();
    final service = _service(
      store,
      settings: () => const PerfAutoExportSettings(enabled: true, maxKeep: 3),
    );

    for (var i = 0; i < 6; i++) {
      await service.exportNow();
    }

    expect(store.reports.length, 3);
    final remaining = (await store.listReports())
        .map((report) => report.timestamp.millisecondsSinceEpoch)
        .toList();
    // 时钟步进 1s：保留最新三份（4000 / 5000 / 6000）。
    expect(remaining, <int>[6000, 5000, 4000]);
    service.dispose();
  });

  test('format=both 一次落 2 份（json + csv）', () async {
    final store = _MemoryReportStore();
    final service = _service(
      store,
      settings: () => const PerfAutoExportSettings(
        enabled: true,
        format: PerfAutoExportFormat.both,
      ),
      clock: () => DateTime.fromMillisecondsSinceEpoch(5000),
    );

    expect(await service.exportNow(), 2);
    final formats =
        (await store.listReports()).map((report) => report.format).toSet();
    expect(
      formats,
      <PerfReportFormat>{PerfReportFormat.json, PerfReportFormat.csv},
    );
    service.dispose();
  });

  test('保存 / 列出失败均静默（绝不抛），返回已落盘份数', () async {
    final store = _MemoryReportStore()..failSave = true;
    final service = _service(
      store,
      settings: () => const PerfAutoExportSettings(enabled: true),
    );

    expect(await service.exportNow(), 0, reason: '落盘失败 → 0');

    store.failSave = false;
    store.failList = true;
    expect(
      await service.exportNow(),
      1,
      reason: '落盘成功但裁剪列出失败 → 仍返回 1',
    );
    service.dispose();
  });

  test('dispose 后 exportNow / start 均为空操作', () async {
    final store = _MemoryReportStore();
    final service = _service(
      store,
      settings: () => const PerfAutoExportSettings(enabled: true),
    );

    service.dispose();
    expect(await service.exportNow(), 0);
    service.start();
    expect(service.isRunning, isFalse);
    expect(store.reports, isEmpty);
  });
}

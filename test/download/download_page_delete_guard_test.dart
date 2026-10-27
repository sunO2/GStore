/// Regression tests for the download-page delete/clear actions.
///
/// BUG A (reported): "下载重试 / 下载完成删除 — 更新都不及时，状态更新不对".
///
/// `download_page_providers.dart` used to gate the whole action on the legacy
/// `download` write marker OUTSIDE the `try` (`deleteDownload`,
/// `deleteDownloadsByAppId`, `clearCompleted`, `clearAll`). Once the core owns
/// the `download` domain (armed after any real download), `assertAllowed`
/// throws `LegacyWriteBlocked` *before* the `try`, so the core-backed
/// delete/clear never runs and the list never updates.
///
/// The guard belongs ONLY on the Dart-Floor fallback write (used when the core
/// `IDownloadService` is unavailable). These tests fail on the pre-fix code:
/// with the marker armed + the core service available, the delete/clear actions
/// threw before performing any `service.remove(...)`.
library;

import 'dart:async';
import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/manager/download_repository.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/model/download_task_database.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';
import 'package:gstore/page/download/download_page_providers.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// sqlite3 为 sqflite_common_ffi 传递依赖，仅用其 `open` 覆写动态库加载路径。
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart';

/// Core service double: `listTasks` reads the live in-memory rows and `remove`
/// records the id AND drops the row, so a post-action `loadTasks()` reflects the
/// deletion (exactly how the core-backed list behaves).
///
/// `watchAll()` returns a non-completing broadcast stream and counts how many
/// times it was called (= one core watch poll thread each), so tests can prove
/// the panel keeps a SINGLE list-level subscription and rebuilds it on retry.
/// `watch(id)` is still counted to prove the panel no longer subscribes per task.
class _RecordingDownloadService implements IDownloadService {
  _RecordingDownloadService(this._tasks);

  final List<DownloadTask> _tasks;
  final List<int> removed = <int>[];
  final List<int> cancelled = <int>[];
  final List<int> retried = <int>[];
  int watchAllCalls = 0;
  final Map<int, int> watchCalls = <int, int>{};
  final Map<int, StreamController<DownloadTask>> _watchers =
      <int, StreamController<DownloadTask>>{};
  StreamController<DownloadTask>? _watchAllController;

  void dispose() {
    for (final controller in _watchers.values) {
      controller.close();
    }
    _watchers.clear();
    _watchAllController?.close();
    _watchAllController = null;
  }

  @override
  Future<List<DownloadTask>> listTasks() async => List<DownloadTask>.of(_tasks);

  @override
  Future<void> remove(int id) async {
    removed.add(id);
    _tasks.removeWhere((t) => t.id == id);
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }

  @override
  Future<void> retry(int id) async {
    retried.add(id);
    _replace(id, (t) => t.copyWith(status: DownloadStatusEnum.downloading));
  }

  @override
  Future<void> restart(int id) async {
    _replace(id, (t) => t.copyWith(status: DownloadStatusEnum.downloading));
  }

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  void _replace(int id, DownloadTask Function(DownloadTask) update) {
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index >= 0) _tasks[index] = update(_tasks[index]);
  }

  @override
  Stream<DownloadTask> watch(int id) {
    watchCalls[id] = (watchCalls[id] ?? 0) + 1;
    return _watchers
        .putIfAbsent(id, () => StreamController<DownloadTask>.broadcast())
        .stream;
  }

  @override
  Stream<DownloadTask> watchAll() {
    watchAllCalls++;
    return (_watchAllController ??= StreamController<DownloadTask>.broadcast())
        .stream;
  }

  @override
  Future<DownloadTask?> getTask(int id) async =>
      _tasks.where((t) => t.id == id).firstOrNull;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadTask _task(
  int? id, {
  String appId = 'com.example.app',
  String fileName = 'app.apk',
  DownloadStatusEnum status = DownloadStatusEnum.paused,
}) {
  return DownloadTask(
    id: id,
    appId: appId,
    appName: '示例',
    version: '1.0.0',
    fileName: fileName,
    url: 'https://example.test/$fileName',
    filePath: '/tmp/does-not-exist-$id-$fileName',
    total: 100,
    received: status == DownloadStatusEnum.completed ? 100 : 0,
    status: status,
    speedBps: 0,
    etaSec: null,
    error: null,
    segments: null,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
  );
}

List<int?> _visibleIds(ProviderContainer container) => container
    .read(downloadManagerProvider)
    .groups
    .expand((group) => group)
    .map((t) => t.id)
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Linux 仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库；
    // 与 migration_test / live_progress_test 一致。
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    await ModuleManager.instance.clear();
    LegacyWriteGuard.resetForTest();
  });

  tearDown(() async {
    await closeDownloadTaskDatabase();
    try {
      final path = p.join(
          await databaseFactoryFfi.getDatabasesPath(), 'download_task.db');
      await databaseFactoryFfi.deleteDatabase(path);
    } catch (_) {
      // 文件可能不存在，忽略
    }
    await ModuleManager.instance.clear();
    LegacyWriteGuard.resetForTest();
  });

  group('armed marker + core service available: the action must run on the core',
      () {
    test('deleteDownload calls service.remove and refreshes the list',
        () async {
      final tasks = <DownloadTask>[_task(1), _task(2, fileName: 'b.apk')];
      final service = _RecordingDownloadService(tasks);
      ModuleManager.instance.bind<IDownloadService>(service);
      // Armed marker: the core owns the `download` domain.
      final probed = <String>[];
      LegacyWriteGuard.probeOverride = (domain) async {
        probed.add(domain);
        return true;
      };

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(downloadManagerProvider.notifier);
      await notifier.load();
      expect(_visibleIds(container), containsAll(<int>[1, 2]));

      await notifier.deleteDownload(tasks.first);

      expect(service.removed, <int>[1],
          reason: 'the core-backed delete must call service.remove');
      expect(probed, isEmpty,
          reason: 'the core path must NOT probe the legacy write marker');
      expect(_visibleIds(container), <int>[2],
          reason: 'the refreshed list must no longer show the deleted task');
    });

    test('clearCompleted calls service.remove for completed/failed tasks',
        () async {
      final tasks = <DownloadTask>[
        _task(1, status: DownloadStatusEnum.completed),
        _task(2, fileName: 'b.apk', status: DownloadStatusEnum.failed),
        _task(3, fileName: 'c.apk', status: DownloadStatusEnum.downloading),
      ];
      final service = _RecordingDownloadService(tasks);
      ModuleManager.instance.bind<IDownloadService>(service);
      LegacyWriteGuard.probeOverride = (domain) async => true;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(downloadManagerProvider.notifier);
      await notifier.load();

      await notifier.clearCompleted();

      expect(service.removed, containsAll(<int>[1, 2]),
          reason: 'completed and failed rows must be removed through the core');
      expect(service.removed, isNot(contains(3)),
          reason: 'an active download must survive clearCompleted');
      expect(_visibleIds(container), <int>[3]);
    });

    testWidgets('clearAll calls service.remove for every task after confirm',
        (tester) async {
      final tasks = <DownloadTask>[
        _task(1, status: DownloadStatusEnum.completed),
        _task(2, fileName: 'b.apk'),
      ];
      final service = _RecordingDownloadService(tasks);
      ModuleManager.instance.bind<IDownloadService>(service);
      LegacyWriteGuard.probeOverride = (domain) async => true;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(downloadManagerProvider.notifier);
      await notifier.load();

      await tester.pumpWidget(MaterialApp(
        navigatorKey: appNavigatorKey,
        home: const Scaffold(body: SizedBox()),
      ));

      // clearAll 删除文件走真实 dart:io：widget 测试的 fake-async 时钟不会推进
      // 真实 I/O，所以整个 clearAll 必须在 runAsync（真实异步区）里跑；弹层仍
      // 由 fake 区 pump/tap 驱动。
      late Future<void> future;
      await tester.runAsync(() async {
        future = notifier.clearAll();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.widgetWithText(FilledButton, '确认清空'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '确认清空'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => future);

      expect(service.removed, containsAll(<int>[1, 2]),
          reason: 'clearAll must remove every core row after the confirm');
      expect(_visibleIds(container), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('armed marker + NO core service: the Dart-Floor fallback stays guarded',
      () {
    test('deleteDownload does not delete the Floor row (guard blocks it)',
        () async {
      // Seed a real Floor row while the marker is still disarmed.
      LegacyWriteGuard.probeOverride = (domain) async => false;
      final saved = await DownloadRepository().save(_task(null));
      final id = saved!.id!;

      // Now arm the marker and leave the core service unbound.
      LegacyWriteGuard.probeOverride = (domain) async => true;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(downloadManagerProvider.notifier);
      await notifier.load();
      expect(_visibleIds(container), <int>[id]);

      await notifier.deleteDownload(saved);

      final stillThere = await DownloadRepository().getById(id);
      expect(stillThere, isNotNull,
          reason: 'the genuine Dart write path must stay guarded: a blocked '
              'fallback delete must leave the Floor row intact');
    });

    test('clearCompleted does not delete Floor rows (guard blocks it)',
        () async {
      LegacyWriteGuard.probeOverride = (domain) async => false;
      await DownloadRepository()
          .save(_task(null, status: DownloadStatusEnum.completed));
      final before = await DownloadRepository().all();
      expect(before, hasLength(1));

      LegacyWriteGuard.probeOverride = (domain) async => true;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(downloadManagerProvider.notifier);
      await notifier.load();

      await notifier.clearCompleted();

      final after = await DownloadRepository().all();
      expect(after, hasLength(1),
          reason: 'a blocked fallback clear must not remove the Floor rows');
    });
  });

  group('retry revives a terminal task: the watch must be re-subscribed', () {
    test('retryDownload rebuilds the single list-level watch', () async {
      final tasks = <DownloadTask>[
        _task(1, status: DownloadStatusEnum.failed),
      ];
      final service = _RecordingDownloadService(tasks);
      addTearDown(service.dispose);
      ModuleManager.instance.bind<IDownloadService>(service);
      LegacyWriteGuard.probeOverride = (domain) async => true;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(downloadManagerProvider.notifier);
      await notifier.load();
      expect(service.watchAllCalls, 1,
          reason: 'the initial load subscribes the list-level watch once');
      expect(service.watchCalls, isEmpty,
          reason: 'the panel must NOT subscribe per task');

      await notifier.retryDownload(tasks.first);

      expect(service.retried, <int>[1]);
      expect(service.watchAllCalls, 2,
          reason: 'a retried terminal task needs a FRESH subscription: the '
              'core watch emits a terminal row once per subscription and would '
              'otherwise never report the task again. The single list-level '
              'subscription is rebuilt, resetting the terminal latch.');
      expect(service.watchCalls, isEmpty,
          reason: 'the rebuild must stay list-level, never per task');
      expect(_visibleIds(container), <int>[1]);
    });

    test('restartDownload rebuilds the single list-level watch', () async {
      final tasks = <DownloadTask>[
        _task(1, status: DownloadStatusEnum.completed),
      ];
      final service = _RecordingDownloadService(tasks);
      addTearDown(service.dispose);
      ModuleManager.instance.bind<IDownloadService>(service);
      LegacyWriteGuard.probeOverride = (domain) async => true;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(downloadManagerProvider.notifier);
      await notifier.load();
      expect(service.watchAllCalls, 1);

      await notifier.restartDownload(tasks.first);

      expect(service.watchAllCalls, 2);
      expect(service.watchCalls, isEmpty);
    });

    test('retryAllFailed reloads and rebuilds the watch exactly once', () async {
      final tasks = <DownloadTask>[
        _task(1, status: DownloadStatusEnum.failed),
        _task(2, fileName: 'b.apk', status: DownloadStatusEnum.failed),
        _task(3, fileName: 'c.apk', status: DownloadStatusEnum.downloading),
      ];
      final service = _RecordingDownloadService(tasks);
      addTearDown(service.dispose);
      ModuleManager.instance.bind<IDownloadService>(service);
      LegacyWriteGuard.probeOverride = (domain) async => true;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(downloadManagerProvider.notifier);
      await notifier.load();

      notifier.retryAllFailed();
      await pumpEventQueue();

      expect(service.retried, containsAll(<int>[1, 2]));
      // initial load = 1, one rebuild after the batch = 2 (NOT one per failed id).
      expect(service.watchAllCalls, 2,
          reason: 'a batch retry rebuilds the single watch once, not per task');
      expect(service.watchCalls, isEmpty,
          reason: 'a non-failed task must not be re-subscribed, and nothing is '
              'subscribed per task');
      // The refreshed list shows the revived tasks as downloading.
      expect(
        container
            .read(downloadManagerProvider)
            .groups
            .expand((group) => group)
            .where((t) => t.status == DownloadStatusEnum.downloading)
            .map((t) => t.id),
        containsAll(<int>[1, 2, 3]),
      );
    });
  });
}

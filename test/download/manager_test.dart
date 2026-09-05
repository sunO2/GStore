import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart'
    show CancelToken, DioException, DioExceptionType, RequestOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/core/download_engine.dart';
import 'package:gstore/core/download/core/download_event.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/manager/download_manager.dart';
import 'package:gstore/core/download/manager/download_repository.dart';
import 'package:gstore/core/download/model/download_task.dart';

/// 可脚本化的假引擎：可录制并发峰值、失败一次后成功、并在 token 取消时抛取消异常。
///
/// 成功路径会向 [DownloadRequest.savePath] 写入等长的、带 ZIP 魔数（0x50 0x4b）
/// 的合法载荷，这样 DownloadManager 的 `_isValidFile` 校验才能通过。
class _ScriptedEngine implements DownloadEngine {
  _ScriptedEngine({this.failFirst = false, this.pendingTimer = Duration.zero});

  /// 是否首次 execute 就报 DownloadFailed（用于失败+重试用例）。
  final bool failFirst;
  bool _alreadyFailed = false;

  final Duration pendingTimer;

  int executeCount = 0;
  int completedCount = 0;
  int _active = 0;
  int maxActive = 0;

  @override
  Stream<DownloadEvent> execute(
    DownloadRequest request, {
    CancelToken? cancelToken,
  }) {
    executeCount++;
    _active++;
    if (_active > maxActive) {
      maxActive = _active;
    }
    final controller = StreamController<DownloadEvent>();
    unawaited(_run(request, cancelToken, controller));
    return controller.stream;
  }

  Future<void> _run(
    DownloadRequest request,
    CancelToken? cancelToken,
    StreamController<DownloadEvent> controller,
  ) async {
    try {
      if (cancelToken?.isCancelled ?? false) {
        throw _cancelError(request);
      }
      if (failFirst && !_alreadyFailed) {
        _alreadyFailed = true;
        controller.add(DownloadFailed('scripted failure'));
        return;
      }

      final total = request.fileSize ?? 1024;
      // DownloadManager._isValidFile 要求 .apk：存在、非空、PK 魔数、长度>=total
      final file = File(request.savePath!);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        List<int>.generate(
          total,
          (i) => i == 0 ? 0x50 : (i == 1 ? 0x4b : ((i * 13 + 5) & 0xff)),
        ),
        flush: true,
      );

      const progresses = 200;
      for (var i = 1; i <= progresses; i++) {
        if (pendingTimer > Duration.zero) {
          await Future<void>.delayed(pendingTimer);
        }
        if (cancelToken?.isCancelled ?? false) {
          throw _cancelError(request);
        }
        controller.add(DownloadProgress((total * i) ~/ progresses, total));
      }
      controller.add(DownloadCompleted());
      completedCount++;
    } catch (e) {
      controller.addError(e);
    } finally {
      _active--;
      await controller.close();
    }
  }
}

DioException _cancelError(DownloadRequest request) => DioException(
      requestOptions: RequestOptions(path: request.url),
      type: DioExceptionType.cancel,
    );

/// 模拟 pingan MCD 代理 bug 的假引擎：只发一条 `DownloadProgress(received, total:1)`
/// 然后直接完成——用于验证 DownloadManager 不得让引擎错报的 total=1
/// 覆盖调用方传入的 downloadSize。
class _BogusTotalEngine implements DownloadEngine {
  int executeCount = 0;

  @override
  Stream<DownloadEvent> execute(
    DownloadRequest request, {
    CancelToken? cancelToken,
  }) {
    executeCount++;
    final controller = StreamController<DownloadEvent>();
    unawaited(_run(request, controller));
    return controller.stream;
  }

  Future<void> _run(
    DownloadRequest request,
    StreamController<DownloadEvent> controller,
  ) async {
    final total = request.fileSize ?? 1024;
    // DownloadManager._isValidFile 要求 .apk：存在、非空、PK 魔数、长度>=total
    final file = File(request.savePath!);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      List<int>.generate(
        total,
        (i) => i == 0 ? 0x50 : (i == 1 ? 0x4b : ((i * 13 + 5) & 0xff)),
      ),
      flush: true,
    );
    controller.add(DownloadProgress(100, 1));
    controller.add(DownloadCompleted());
    await controller.close();
  }
}

/// 内存版 DownloadRepository：DownloadManager 构造参数是具体类型
/// （`DownloadRepository`），无法直接注入接口假实现；但其方法均非 final，
/// 因此直接在测试内子类化并覆写，避免触碰 lib/。真实 Floor+sqflite 的
/// 持久化行为由 test/download/migration_test.dart 覆盖。
class _MemoryRepository extends DownloadRepository {
  final Map<int, DownloadTask> _byId = {};
  final Map<String, DownloadTask> _byKey = {};
  final Map<int, StreamController<DownloadTask>> _watchers = {};
  int _nextId = 1;

  static String _key(DownloadTask t) => '${t.appId}|${t.version}|${t.fileName}';

  @override
  Future<DownloadTask?> getByKey(
      String appId, String version, String fileName) async =>
      _byKey['$appId|$version|$fileName'];

  @override
  Future<DownloadTask?> getById(int id) async => _byId[id];

  @override
  Future<DownloadTask?> save(DownloadTask task) async {
    var t = task;
    if (t.id == null) {
      t = t.copyWith(id: _nextId++);
    }
    _byId[t.id!] = t;
    _byKey[_key(t)] = t;
    _watchers[t.id!]?.add(t);
    return t;
  }

  @override
  Future<List<DownloadTask>> all() async => _byId.values.toList();

  @override
  Future<List<DownloadTask>> active() async =>
      _byId.values.where((t) => t.isActive).toList();

  @override
  Stream<DownloadTask> watch(int id) => _watchers
      .putIfAbsent(id, () => StreamController<DownloadTask>.broadcast())
      .stream;

  @override
  void disposeId(int id) {
    _watchers.remove(id)?.close();
  }
}

DownloadTask _task({
  int? id,
  required String appId,
  required String filePath,
  int total = 1000,
  int received = 0,
  DownloadStatusEnum status = DownloadStatusEnum.queued,
}) {
  return DownloadTask(
    id: id,
    appId: appId,
    appName: 'App',
    version: '1.0',
    fileName: 'a.apk',
    url: 'https://example.com/a.apk',
    filePath: filePath,
    total: total,
    received: received,
    status: status,
    speedBps: 0,
    etaSec: null,
    error: null,
    segments: null,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
  );
}

/// 轮询直到 [repo] 中 id 任务满足 [pred]，或超时抛错。
Future<DownloadTask> _waitFor(
  DownloadManager manager,
  _MemoryRepository repo,
  int id,
  bool Function(DownloadTask) pred, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final t = await repo.getById(id);
    if (t != null && pred(t)) {
      return t;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  final t = await repo.getById(id);
  throw StateError('task $id 未在 $timeout 内达到预期状态: $t');
}

void main() {
  group('DownloadManager（脚本化引擎 + 内存仓库）', () {
    late Directory tmpDir;
    late Future<String> Function(String name) filePathFor;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('gstore_mgr_test_');
      filePathFor = (name) async => '${tmpDir.path}/$name.apk';
    });

    tearDown(() {
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('最大并发 maxConcurrent=1：3 个任务至多 1 个引擎执行', () async {
      final repo = _MemoryRepository();
      final engine = _ScriptedEngine(pendingTimer: const Duration(milliseconds: 2));
      final manager = DownloadManager(
        engine: engine,
        repository: repo,
        maxConcurrent: 1,
      );

      final saved = <DownloadTask>[];
      for (var i = 0; i < 3; i++) {
        saved.add(await manager.download(
          'com.c$i',
          'App$i',
          '1.0',
          'https://example.com/c$i.apk',
          'a.apk',
          downloadSize: 200,
          saveFileName: await filePathFor('c$i'),
        ));
      }

      // 等待全部执行完毕（引擎 execute 计数达到 3 且都 completed）
      for (final t in saved) {
        await _waitFor(manager, repo, t.id!, (task) => task.isCompleted);
      }
      expect(engine.executeCount, 3);
      expect(engine.maxActive, 1,
          reason: 'maxConcurrent=1 时引擎不得有并发执行');
    });

    test('失败后 retry 可转为 completed（失败一次后成功）', () async {
      final repo = _MemoryRepository();
      final engine = _ScriptedEngine(failFirst: true);
      final manager = DownloadManager(engine: engine, repository: repo);

      final initial = await manager.download(
        'com.retry',
        'RetryApp',
        '1.0',
        'https://example.com/r.apk',
        'a.apk',
        downloadSize: 400,
        saveFileName: await filePathFor('retry'),
      );

      final failed = await _waitFor(
          manager, repo, initial.id!, (t) => t.status == DownloadStatusEnum.failed);
      expect(failed.error, contains('scripted failure'));

      await manager.retry(failed.id!);

      final done = await _waitFor(
          manager, repo, failed.id!, (t) => t.isCompleted);
      expect(done.received, done.total);
      expect(engine.executeCount, 2);
    });

    test('重复下载保护：已完成但文件缺失 → 不早退，触发重新下载', () async {
      final repo = _MemoryRepository();
      final engine = _ScriptedEngine();
      final manager = DownloadManager(engine: engine, repository: repo);

      final missingPath = '${tmpDir.path}/missing_guard.apk';
      expect(File(missingPath).existsSync(), isFalse);

      // 预置一条 status=completed 但 filePath 不存在的任务
      await repo.save(_task(
        appId: 'com.guard',
        filePath: missingPath,
        total: 300,
        received: 300,
        status: DownloadStatusEnum.completed,
      ));

      final result = await manager.download(
        'com.guard',
        'GuardApp',
        '1.0',
        'https://example.com/g.apk',
        'a.apk',
        downloadSize: 300,
        saveFileName: missingPath,
      );

      // 若错误早退，则 execute 不会被调用；正确行为是重新下载。
      final done = await _waitFor(
          manager, repo, result.id!, (t) => t.isCompleted,
          timeout: const Duration(seconds: 10));
      expect(engine.executeCount, 1,
          reason: '文件缺失时不得因 completed 状态早退，必须重新下载');
      expect(File(missingPath).existsSync(), isTrue);
      expect(done.status, DownloadStatusEnum.completed);
    });

    test('cancel 在途下载 → 状态变为 cancelled', () async {
      final repo = _MemoryRepository();
      // 每 2ms 报一次进度，任务约 400ms 完成，给 cancel 留出窗口。
      final engine = _ScriptedEngine(pendingTimer: const Duration(milliseconds: 2));
      final manager = DownloadManager(engine: engine, repository: repo, maxConcurrent: 1);

      final initial = await manager.download(
        'com.cancel',
        'CancelApp',
        '1.0',
        'https://example.com/cx.apk',
        'a.apk',
        downloadSize: 1000,
        saveFileName: await filePathFor('cancel'),
      );

      // 等进入 downloading 后才 cancel（确保 CancelToken 已注册）。
      await _waitFor(
          manager, repo, initial.id!, (t) => t.status == DownloadStatusEnum.downloading);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await manager.cancel(initial.id!);

      final cancelled = await _waitFor(
          manager, repo, initial.id!, (t) => t.status == DownloadStatusEnum.cancelled);
      expect(cancelled.status, DownloadStatusEnum.cancelled);
    });

    test('引擎错报 total=1 不得覆盖 downloadSize：最终 total 保持 100000', () async {
      final repo = _MemoryRepository();
      final engine = _BogusTotalEngine();
      final manager = DownloadManager(engine: engine, repository: repo);

      final initial = await manager.download(
        'com.bogus',
        'BogusApp',
        '1.0',
        'https://example.com/bogus.apk',
        'a.apk',
        downloadSize: 100000,
        saveFileName: await filePathFor('bogus'),
      );
      expect(initial.total, 100000, reason: '初始 total 应来自 downloadSize');

      final done = await _waitFor(
          manager, repo, initial.id!, (t) => t.isCompleted);
      expect(done.total, 100000,
          reason: '引擎 progress 的 total=1 不得覆盖调用方提供的 downloadSize');
      expect(done.received, done.total);
    });

    group('installAfterDownload 完成路径门控', () {
      test('默认 installAfterDownload=true：下载完成后回调安装', () async {
        final repo = _MemoryRepository();
        final engine = _ScriptedEngine();
        final installedPaths = <String>[];
        final manager = DownloadManager(
          engine: engine,
          repository: repo,
          onApkReady: (p) => installedPaths.add(p),
        );

        final initial = await manager.download(
          'com.install',
          'InstallApp',
          '1.0',
          'https://example.com/ins.apk',
          'a.apk',
          downloadSize: 200,
          saveFileName: await filePathFor('install'),
        );

        await _waitFor(manager, repo, initial.id!, (t) => t.isCompleted);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(installedPaths.length, 1,
            reason: '默认 installAfterDownload=true 应触发 onApkReady');
        expect(installedPaths.single, isNotEmpty);
        expect(File(installedPaths.single).existsSync(), isTrue,
            reason: '回调应携带真实下载完成的 APK 路径');
      });

      test('installAfterDownload=false：下载完成但不回调安装', () async {
        final repo = _MemoryRepository();
        final engine = _ScriptedEngine();
        final installedPaths = <String>[];
        final manager = DownloadManager(
          engine: engine,
          repository: repo,
          onApkReady: (p) => installedPaths.add(p),
        );

        final initial = await manager.download(
          'com.noinstall',
          'NoInstallApp',
          '1.0',
          'https://example.com/noins.apk',
          'a.apk',
          downloadSize: 200,
          saveFileName: await filePathFor('noinstall'),
          installAfterDownload: false,
        );

        await _waitFor(manager, repo, initial.id!, (t) => t.isCompleted);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(installedPaths, isEmpty,
            reason: 'installAfterDownload=false 不得触发 onApkReady');
      });

      test('排队任务保持各自 installAfterDownload 参数', () async {
        final repo = _MemoryRepository();
        final engine =
            _ScriptedEngine(pendingTimer: const Duration(milliseconds: 2));
        final installedPaths = <String>[];
        final manager = DownloadManager(
          engine: engine,
          repository: repo,
          maxConcurrent: 1,
          onApkReady: (p) => installedPaths.add(p),
        );

        // 第一个任务：默认 true，立即启动并占用唯一并发槽。
        final first = await manager.download(
          'com.qa',
          'QueueA',
          '1.0',
          'https://example.com/qa.apk',
          'a.apk',
          downloadSize: 200,
          saveFileName: await filePathFor('qa'),
        );
        // 第二个任务：显式 false，进入排队。
        final second = await manager.download(
          'com.qb',
          'QueueB',
          '1.0',
          'https://example.com/qb.apk',
          'a.apk',
          downloadSize: 200,
          saveFileName: await filePathFor('qb'),
          installAfterDownload: false,
        );

        for (final t in [first, second]) {
          await _waitFor(manager, repo, t.id!, (task) => task.isCompleted);
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engine.maxActive, 1,
            reason: 'maxConcurrent=1 时第二个任务必须排队');
        expect(installedPaths.length, 1,
            reason: '只有默认 true 的第一个任务触发安装，排队中的 false 任务完成也不触发');
        expect(installedPaths.single, first.filePath);
      });
    });
  });
}
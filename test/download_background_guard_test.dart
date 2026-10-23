// TEMPORARY evidence probe (deleted after the run). Proves the background
// download save path swallows a LegacyWriteBlocked instead of leaking it to
// the zone handler.
import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/core/download_engine.dart';
import 'package:gstore/core/download/core/download_event.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/manager/download_manager.dart';
import 'package:gstore/core/download/manager/download_repository.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';

class _FakeRepo extends DownloadRepository {
  int saves = 0;

  @override
  Future<DownloadTask?> save(DownloadTask task) async {
    saves++;
    if (saves > 1) throw LegacyWriteBlocked('download');
    return task;
  }

  @override
  Future<DownloadTask?> getById(int id) async => DownloadTask(
        id: id,
        appId: 'com.example',
        appName: 'Example',
        version: '1.0',
        fileName: 'example.apk',
        url: 'https://example.invalid/example.apk',
        filePath: '/tmp/gstore_probe/example.apk',
        total: 10,
        received: 0,
        status: DownloadStatusEnum.paused,
        speedBps: 0,
        etaSec: null,
        error: null,
        segments: null,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  @override
  Future<List<DownloadTask>> all() async => const <DownloadTask>[];

  @override
  void disposeId(int id) {}
}

class _EmptyEngine extends DownloadEngine {
  @override
  Stream<DownloadEvent> execute(
    DownloadRequest request, {
    CancelToken? cancelToken,
  }) =>
      const Stream<DownloadEvent>.empty();
}

void main() {
  test('blocked marker in a background save is logged, not unhandled',
      () async {
    final errors = <Object>[];
    final repo = _FakeRepo();
    await runZonedGuarded(() async {
      final manager = DownloadManager(
        engine: _EmptyEngine(),
        repository: repo,
      );
      await manager.resume(1);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }, (error, stackTrace) => errors.add(error));

    expect(errors, isEmpty,
        reason: 'a rejected background future must not reach the zone');
    expect(repo.saves, greaterThan(1),
        reason: 'the background run did attempt the guarded save');
  });
}

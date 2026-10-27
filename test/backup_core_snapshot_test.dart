import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/service/core_snapshot_backup.dart';

class _FakeCoreSnapshotBackend implements CoreSnapshotBackend {
  _FakeCoreSnapshotBackend({this.version = 4});

  final int exportBytes = 42;
  final int version;
  final List<String> exportedPaths = <String>[];
  final List<String> restoredPaths = <String>[];
  Object? restoreError;

  @override
  Future<BigInt> exportSnapshot({required String path}) async {
    exportedPaths.add(path);
    return BigInt.from(exportBytes);
  }

  @override
  Future<int> importSnapshot({required String path}) async {
    restoredPaths.add(path);
    final error = restoreError;
    if (error != null) throw error;
    return version;
  }
}

void main() {
  late _FakeCoreSnapshotBackend backend;

  setUp(() {
    backend = _FakeCoreSnapshotBackend();
    CoreSnapshotBackup.debugBackend = backend;
    CoreSnapshotBackup.debugSnapshotPath = () async => '/tmp/default-snapshot.db';
  });

  tearDown(() {
    CoreSnapshotBackup.debugBackend = null;
    CoreSnapshotBackup.debugSnapshotPath = null;
  });

  test('exportCoreSnapshot delegates the explicit path to the FRB backend', () async {
    final result = await BackupService.instance.exportCoreSnapshot(
      path: '/tmp/explicit.db',
    );

    expect(backend.exportedPaths, <String>['/tmp/explicit.db']);
    expect(result.path, '/tmp/explicit.db');
    expect(result.bytes, 42);
    expect(result.secretsExcluded, isTrue);
    expect(result.toJson()['secrets_excluded'], isTrue);
  });

  test('exportCoreSnapshot derives a default path when none is supplied', () async {
    final result = await BackupService.instance.exportCoreSnapshot();

    expect(backend.exportedPaths, <String>['/tmp/default-snapshot.db']);
    expect(result.path, '/tmp/default-snapshot.db');
    expect(result.secretsExcluded, isTrue);
  });

  test('restoreCoreSnapshot returns the restored schema version', () async {
    backend = _FakeCoreSnapshotBackend(version: 4);
    CoreSnapshotBackup.debugBackend = backend;

    final result = await BackupService.instance.restoreCoreSnapshot(
      '/tmp/restore.db',
    );

    expect(backend.restoredPaths, <String>['/tmp/restore.db']);
    expect(result.schemaVersion, 4);
    expect(result.secretsExcluded, isTrue);
    expect(result.toJson()['secrets_excluded'], isTrue);
  });

  test('restoreCoreSnapshot propagates a typed backend failure', () async {
    backend = _FakeCoreSnapshotBackend()
      ..restoreError = Exception('CORE_E_SNAPSHOT_NEWER: snapshot v9 > v4');
    CoreSnapshotBackup.debugBackend = backend;

    await expectLater(
      BackupService.instance.restoreCoreSnapshot('/tmp/newer.db'),
      throwsA(
        predicate<Object>(
          (Object error) => error.toString().contains('CORE_E_SNAPSHOT_NEWER'),
        ),
      ),
    );
  });
}

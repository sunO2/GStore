import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/rust/CoreApiFacade.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Narrow seam over the two FRB `CoreApi` snapshot calls.
///
/// Tests inject a fake so the BackupService wrapper can be exercised without a
/// native library; production uses [FrbCoreSnapshotBackend].
abstract class CoreSnapshotBackend {
  Future<BigInt> exportSnapshot({required String path});

  Future<int> importSnapshot({required String path});
}

/// Production backend over the memoised [CoreApiFacade] handle.
class FrbCoreSnapshotBackend implements CoreSnapshotBackend {
  rust.CoreApi? _api;

  Future<rust.CoreApi> _ensureApi() async {
    final existing = _api;
    if (existing != null) return existing;
    final support = await getApplicationSupportDirectory();
    final root = '${support.path}/gstore_core';
    return _api = await CoreApiFacade.init(
      dataDir: '$root/data',
      filesDir: '$root/files',
      cacheDir: '$root/cache',
    );
  }

  @override
  Future<BigInt> exportSnapshot({required String path}) async =>
      (await _ensureApi()).exportSnapshot(path: path);

  @override
  Future<int> importSnapshot({required String path}) async =>
      (await _ensureApi()).importSnapshot(path: path);
}

/// Result of exporting the core database through the FRB snapshot API.
class CoreSnapshotExport {
  const CoreSnapshotExport({
    required this.path,
    required this.bytes,
    required this.secretsExcluded,
  });

  final String path;
  final int bytes;

  /// Snapshot exports never include the host secret store.
  final bool secretsExcluded;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'bytes': bytes,
        'secrets_excluded': secretsExcluded,
      };
}

/// Result of restoring the core database from a snapshot.
class CoreSnapshotRestore {
  const CoreSnapshotRestore({
    required this.schemaVersion,
    required this.secretsExcluded,
  });

  final int schemaVersion;

  /// Snapshot restores never carry the host secret store.
  final bool secretsExcluded;

  Map<String, Object?> toJson() => <String, Object?>{
        'schema_version': schemaVersion,
        'secrets_excluded': secretsExcluded,
      };
}

/// Core-database snapshot export/restore over the FRB bridge.
class CoreSnapshotBackup {
  CoreSnapshotBackup._();

  @visibleForTesting
  static CoreSnapshotBackend? debugBackend;

  @visibleForTesting
  static Future<String> Function()? debugSnapshotPath;

  static CoreSnapshotBackend get _backend =>
      debugBackend ?? FrbCoreSnapshotBackend();

  static Future<String> _defaultSnapshotPath() async {
    final override = debugSnapshotPath;
    if (override != null) return override();
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/gstore_core/files/backups');
    await dir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return '${dir.path}/core-snapshot-$stamp.db';
  }

  static Future<CoreSnapshotExport> export({String? path}) async {
    final target = path ?? await _defaultSnapshotPath();
    final size = await _backend.exportSnapshot(path: target);
    return CoreSnapshotExport(
      path: target,
      bytes: size.toInt(),
      secretsExcluded: true,
    );
  }

  static Future<CoreSnapshotRestore> restore(String path) async {
    final version = await _backend.importSnapshot(path: path);
    return CoreSnapshotRestore(
      schemaVersion: version,
      secretsExcluded: true,
    );
  }
}

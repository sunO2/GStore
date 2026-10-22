import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/download_paths.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart';

/// Dart half of the legacy-download parity gate.
///
/// Reads the fixture produced by `scripts/qa/gen_download_parity_fixture.py`
/// and emits the same canonical document as
/// `gstore_core_parity --download`. The Dart rules come from production code
/// (`DownloadPaths.resolveSavePath`) and the engine conventions (`.part{i}`,
/// `.temp` merge role, final > temp > parts resumable bytes). The only
/// intentional difference is `checksum_supported`: Dart has no checksum
/// verification, Rust does.
void _ffiInit() {
  open.overrideFor(
    OperatingSystem.linux,
    () => DynamicLibrary.open('libsqlite3.so.0'),
  );
}

const _root = 'target/spike-evidence/download-parity';
const _legacyDb = '$_root/legacy/download_task.db';
const _moduleDb = '$_root/module/download.db';
const _outputPath = 'target/spike-evidence/download-parity-dart.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseFactory factory;

  setUpAll(() {
    factory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  });

  test('writes real-SQLite Dart download parity JSON', () async {
    expect(File(_legacyDb).existsSync(), isTrue,
        reason: 'run scripts/qa/parity.sh --download first');
    expect(File(_moduleDb).existsSync(), isTrue,
        reason: 'run scripts/qa/parity.sh --download first');

    final legacy = await factory.openDatabase(
      File(_legacyDb).absolute.path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    addTearDown(legacy.close);
    final module = await factory.openDatabase(
      File(_moduleDb).absolute.path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    addTearDown(module.close);

    final metaRows = await legacy.query('parity_meta');
    final meta = <String, String>{
      for (final row in metaRows) row['key'] as String: row['value'] as String,
    };
    final downloadsDir = meta['downloads_dir']!;
    final docsDir = meta['docs_dir']!;

    final floorRows = await legacy.query('download_task', orderBy: 'id ASC');
    final floor = <_SourceRow>[];
    final seen = <String>{};
    for (final raw in floorRows) {
      final row = _SourceRow.fromFloor(raw);
      if (!seen.add(row.dedupKey)) continue; // core row wins: first one only.
      floor.add(row);
    }

    final moduleRows = await module.query('download_task', orderBy: 'id ASC');
    final moduleSources = moduleRows.map(_SourceRow.fromModule).toList();

    final statusByDedup = <String, int>{
      for (final row in floor) row.dedupKey: row.status,
    };
    final moduleUpdated = <_SourceRow>[];
    final moduleInserted = <_SourceRow>[];
    for (final row in moduleSources) {
      final existingIndex = floor.indexWhere((f) => f.dedupKey == row.dedupKey);
      if (existingIndex >= 0) {
        moduleUpdated.add(row);
        statusByDedup.putIfAbsent(row.dedupKey, () => row.status);
      } else {
        moduleInserted.add(row);
        statusByDedup.putIfAbsent(row.dedupKey, () => row.status);
      }
    }

    final resolvedByDedup = <String, String>{};
    var pathRuleMatches = true;
    for (final row in floor) {
      final resolved = await DownloadPaths.resolveSavePath(
        saveFileName: row.saveFileName,
        fileName: row.fileName,
        downloadsDirProvider: () async => Directory(downloadsDir),
        docsDirProvider: () async => Directory(docsDir),
      );
      resolvedByDedup[row.dedupKey] = resolved;
      if (resolved != row.filePath) pathRuleMatches = false;
    }

    final canonical = <Map<String, Object?>>[];
    for (final row in floor) {
      final moduleTaskId = moduleUpdated
          .where((candidate) => candidate.dedupKey == row.dedupKey)
          .map((candidate) => candidate.moduleTaskId)
          .firstOrNull;
      canonical.add(
        _canonicalRow(
          moduleTaskId: moduleTaskId,
          dedupKey: row.dedupKey,
          appId: row.appId,
          destPath: resolvedByDedup[row.dedupKey]!,
          statusCode: statusByDedup[row.dedupKey] ?? row.status,
          coreStatus: _coreStatus(statusByDedup[row.dedupKey] ?? row.status),
          bytesDone: row.received,
          total: row.total,
          installAfterDownload: row.installAfterDownload,
          checksumSupported: false,
        ),
      );
    }
    for (final row in moduleInserted) {
      canonical.add(
        _canonicalRow(
          moduleTaskId: row.moduleTaskId,
          dedupKey: row.dedupKey,
          appId: row.appId,
          destPath: row.filePath,
          statusCode: row.status,
          coreStatus: _coreStatus(row.status),
          bytesDone: row.received,
          total: row.total,
          installAfterDownload: row.installAfterDownload,
          checksumSupported: false,
        ),
      );
    }

    final document = <String, Object?>{
      'mode': 'download',
      'migration': <String, Object?>{
        'floor': <String, Object?>{
          'inserted': floor.length,
          'updated': 0,
          'skipped': floorRows.length - floor.length,
        },
        'module': <String, Object?>{
          'inserted': moduleInserted.length,
          'updated': moduleUpdated.length,
          'skipped': 0,
        },
        'second_run': <String, Object?>{
          'floor': <String, Object?>{
            'inserted': 0,
            'updated': 0,
            'skipped': floorRows.length,
          },
          'module': <String, Object?>{
            'inserted': 0,
            'updated': 0,
            'skipped': moduleSources.length,
          },
        },
        'rows_after_first': floor.length + moduleInserted.length,
        'rows_after_second': floor.length + moduleInserted.length,
        'duplicate_dedup_keys': 0,
        'skipped_missing': <String>[],
        'path_rule_matches': pathRuleMatches,
      },
      'rows': canonical,
    };

    final output = File(_outputPath);
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(document),
    );

    expect(pathRuleMatches, isTrue,
        reason: 'fixture filePath must equal DownloadPaths.resolveSavePath');
    expect(canonical, hasLength(14));
    expect(
      canonical.map((row) => row['status_code']).toSet(),
      containsAll(<int>[0, 1, 2, 3, 4, 5, 6, 9]),
    );
    final paused = canonical.firstWhere(
      (row) => row['dedup_key'] == 'app:paused',
    );
    expect(paused['resume_expected_bytes'], 700,
        reason: '.temp wins over the part sum');
    expect(paused['merge_temp_role'], 'temp');
    expect(paused['part_files'], hasLength(2));
    final rustMerge = canonical.firstWhere(
      (row) => row['dedup_key'] == 'app:rustmerge',
    );
    expect(rustMerge['merge_temp_role'], 'merge');
    final completed = canonical.firstWhere(
      (row) => row['dedup_key'] == 'app:completed',
    );
    expect(completed['resume_expected_bytes'], 2048,
        reason: 'final file wins over parts/temp');
    expect(
      canonical
          .firstWhere((row) => row['dedup_key'] == 'app:stray')['part_files'],
      isEmpty,
      reason: 'a bare .part file is not a resumable segment',
    );
  });
}

class _SourceRow {
  _SourceRow({
    required this.moduleTaskId,
    required this.dedupKey,
    required this.appId,
    required this.fileName,
    required this.filePath,
    required this.saveFileName,
    required this.received,
    required this.total,
    required this.status,
    required this.installAfterDownload,
  });

  final String? moduleTaskId;
  final String dedupKey;
  final String appId;
  final String fileName;
  final String filePath;
  final String? saveFileName;
  final int received;
  final int total;
  final int status;
  final bool installAfterDownload;

  factory _SourceRow.fromFloor(Map<String, Object?> row) {
    final url = _text(row['url']) ?? '';
    final filePath = _text(row['filePath']) ?? '';
    return _SourceRow(
      moduleTaskId: null,
      dedupKey: _text(row['dedupKey']) ?? 'legacy:$url|$filePath',
      appId: _text(row['appId']) ?? '',
      fileName: _text(row['fileName']) ?? '',
      filePath: filePath,
      saveFileName: _text(row['saveFileName']),
      received: _int(row['received']),
      total: _int(row['total']),
      status: _int(row['status']),
      installAfterDownload: _int(row['installAfterDownload']) != 0,
    );
  }

  factory _SourceRow.fromModule(Map<String, Object?> row) {
    return _SourceRow(
      moduleTaskId: '${_int(row['id'])}',
      dedupKey: _text(row['dedup_key']) ?? '',
      appId: _text(row['app_id']) ?? '',
      fileName: _text(row['file_name']) ?? '',
      filePath: _text(row['file_path']) ?? '',
      saveFileName: null,
      received: _int(row['received']),
      total: _int(row['total']),
      status: _int(row['status']),
      installAfterDownload: _int(row['install_after_download']) != 0,
    );
  }
}

Map<String, Object?> _canonicalRow({
  required String? moduleTaskId,
  required String dedupKey,
  required String appId,
  required String destPath,
  required int statusCode,
  required String coreStatus,
  required int bytesDone,
  required int total,
  required bool installAfterDownload,
  required bool checksumSupported,
}) {
  final parts = _partFiles(destPath);
  return <String, Object?>{
    'module_task_id': moduleTaskId,
    'dedup_key': dedupKey,
    'app_id': appId,
    'dest_path': destPath,
    'status': coreStatus,
    'status_code': statusCode,
    'status_enum': _statusEnum(statusCode),
    'bytes_done': bytesDone,
    'total': total,
    'install_after_download': installAfterDownload,
    'resume_expected_bytes': _resumeExpectedBytes(destPath, parts),
    'part_files': parts
        .map((part) => <String, Object?>{'index': part.$1, 'bytes': part.$2})
        .toList(growable: false),
    'merge_temp_role': _mergeTempRole(destPath),
    'checksum_supported': checksumSupported,
  };
}

/// Dart `DownloadStatusEnum` names for the same ints.
String _statusEnum(int code) => switch (code) {
      0 => 'queued',
      1 => 'connecting',
      2 => 'downloading',
      3 => 'paused',
      4 => 'completed',
      5 => 'failed',
      6 => 'cancelled',
      _ => 'failed',
    };

/// Migrated core `download_task.status` label (0..2 collapse to running).
String _coreStatus(int code) => switch (code) {
      0 || 1 || 2 => 'running',
      3 => 'paused',
      4 => 'completed',
      5 => 'failed',
      6 => 'cancelled',
      _ => 'failed',
    };

List<(int, int)> _partFiles(String destPath) {
  final parts = <(int, int)>[];
  for (var index = 0; index < 100; index++) {
    final file = File('$destPath.part$index');
    if (!file.existsSync()) break;
    parts.add((index, file.lengthSync()));
  }
  return parts;
}

int _resumeExpectedBytes(String destPath, List<(int, int)> parts) {
  final finalFile = File(destPath);
  if (finalFile.existsSync()) return finalFile.lengthSync();
  final temp = File('$destPath.temp');
  if (temp.existsSync()) return temp.lengthSync();
  return parts.fold<int>(0, (sum, part) => sum + part.$2);
}

String? _mergeTempRole(String destPath) {
  if (File('$destPath.temp').existsSync()) return 'temp';
  if (File('$destPath.merge').existsSync()) return 'merge';
  return null;
}

String? _text(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('${value ?? ''}') ?? 0;
}

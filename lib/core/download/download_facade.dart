/// Flag-free facade over the Rust `DownloadApi`.
///
/// Tests install a fake [DownloadBackend] through the constructor, so no
/// native library is required. This file deliberately does not wire into
/// `RustDownloadService` / install paths yet.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/rust/CoreApiFacade.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Injectable transport seam over `DownloadApi`.
abstract class DownloadBackend {
  Future<int> start(rust.DownloadStartRequest request);

  Future<List<rust.DownloadTaskDto>> list();

  Future<rust.DownloadTaskDto?> get(String moduleTaskId);

  Future<void> pause(String moduleTaskId);

  Future<void> resume(String moduleTaskId);

  Future<void> cancel(String moduleTaskId);

  Future<void> retry(String moduleTaskId);

  Future<void> restart(String moduleTaskId);

  Future<void> remove(String moduleTaskId);

  Stream<rust.DownloadTaskDto> watchAll();
}

/// Optional capability: one-shot import of legacy download databases.
///
/// Kept separate from [DownloadBackend] so existing fakes do not have to grow a
/// method that only the production FRB backend implements.
abstract class DownloadLegacyImport {
  Future<void> importLegacyOnce({String? floorDbPath, String? moduleDbPath});
}

/// Optional capability: three-way download resync against the core mirror.
///
/// Kept separate from [DownloadBackend] (like [DownloadLegacyImport]) so
/// existing fakes do not have to grow a method only the FRB backend implements.
abstract class DownloadResync {
  /// Runs the Floor ↔ module ↔ core parity check.
  ///
  /// Dry-run (`apply: false`) is read-only; `apply: true` snapshots and mirrors.
  /// [floorDbPath] defaults to the Dart Floor database on the FRB backend.
  Future<rust.ResyncReportDto> resyncDownloads({
    bool apply = false,
    String? floorDbPath,
  });
}

/// Production FRB backend. The `DownloadApi` handle is created lazily.
class FrbDownloadBackend
    implements DownloadBackend, DownloadLegacyImport, DownloadResync {
  FrbDownloadBackend({this.dataDir, this.filesDir, this.cacheDir});

  final String? dataDir;
  final String? filesDir;
  final String? cacheDir;

  rust.DownloadApi? _api;
  Future<rust.DownloadApi>? _pending;

  /// Process-wide memo: the legacy import runs at most once per process.
  static Future<void>? _legacyImport;

  /// Test seam: lets a suite exercise the import again with different paths.
  @visibleForTesting
  static void resetLegacyImportForTest() {
    _legacyImport = null;
  }

  @override
  Future<void> importLegacyOnce({String? floorDbPath, String? moduleDbPath}) {
    return _legacyImport ??= _importLegacyOnce(
      floorDbPath: floorDbPath,
      moduleDbPath: moduleDbPath,
    );
  }

  Future<void> _importLegacyOnce({
    String? floorDbPath,
    String? moduleDbPath,
  }) async {
    try {
      final floor = await _resolveFloorDbPath(floorDbPath);
      final module = moduleDbPath ??
          '${(await getApplicationDocumentsDirectory()).path}'
              '/gstore_mods/download/download.db';
      _logLegacyMissing('floor', floor);
      _logLegacyMissing('module', module);
      final api = await _ensureApi();
      final report = await api.importLegacy(
        floorDbPath: floor,
        moduleDbPath: module,
      );
      debugPrint(
        'download legacy import: '
        'floor=${report.floor?.inserted ?? 0} inserted/'
        '${report.floor?.updated ?? 0} updated/'
        '${report.floor?.skipped ?? 0} skipped, '
        'module=${report.module?.inserted ?? 0} inserted/'
        '${report.module?.updated ?? 0} updated/'
        '${report.module?.skipped ?? 0} skipped, '
        'missing=${report.skippedMissing}',
      );
    } catch (error) {
      // Never block a download because the one-shot import failed.
      debugPrint('download legacy import failed (non-fatal): $error');
    }
  }

  /// Resolves the legacy Floor database: the caller's override, else the Dart
  /// `sqflite` default. Shared by the one-shot import and the resync so both
  /// always read the same file.
  static Future<String> _resolveFloorDbPath(String? override) async =>
      override ?? '${await getDatabasesPath()}/download_task.db';

  void _logLegacyMissing(String label, String path) {
    try {
      if (!File(path).existsSync()) {
        debugPrint(
          'download legacy import: $label db missing at $path (skipped)',
        );
      }
    } catch (error) {
      debugPrint('download legacy import: cannot stat $label db: $error');
    }
  }

  /// Runs the three-way resync through the Rust core.
  ///
  /// `CoreApi` owns `resync_downloads`; `CoreApiFacade` memoises the handle so
  /// this reuses the bootstrap writer instead of opening a second core
  /// connection. The Rust `apply` argument is required, so it is always
  /// forwarded explicitly. A `null` [floorDbPath] resolves to the same Dart
  /// Floor database used by [importLegacyOnce].
  @override
  Future<rust.ResyncReportDto> resyncDownloads({
    bool apply = false,
    String? floorDbPath,
  }) async {
    final floor = await _resolveFloorDbPath(floorDbPath);
    final dirs = await _resolveDirs();
    final api = await CoreApiFacade.init(
      dataDir: dirs.$1,
      filesDir: dirs.$2,
      cacheDir: dirs.$3,
    );
    return api.resyncDownloads(apply: apply, floorDbPath: floor);
  }

  Future<rust.DownloadApi> _ensureApi() {
    final existing = _api;
    if (existing != null) return Future.value(existing);
    return _pending ??= _create();
  }

  Future<rust.DownloadApi> _create() async {
    try {
      await RustBridge.ensureInitialized();
      final dirs = await _resolveDirs();
      final api = await rust.DownloadApi.init(
        dataDir: dirs.$1,
        filesDir: dirs.$2,
        cacheDir: dirs.$3,
      );
      _api = api;
      return api;
    } finally {
      _pending = null;
    }
  }

  Future<(String, String, String)> _resolveDirs() async {
    if (dataDir != null && filesDir != null && cacheDir != null) {
      return (dataDir!, filesDir!, cacheDir!);
    }
    final support = await getApplicationSupportDirectory();
    final root = '${support.path}/gstore_core';
    return ('$root/data', '$root/files', '$root/cache');
  }

  @override
  Future<int> start(rust.DownloadStartRequest request) async {
    final api = await _ensureApi();
    return (await api.start(request: request)).toInt();
  }

  @override
  Future<List<rust.DownloadTaskDto>> list() async {
    final api = await _ensureApi();
    return api.list();
  }

  @override
  Future<rust.DownloadTaskDto?> get(String moduleTaskId) async {
    final api = await _ensureApi();
    return api.get_(moduleTaskId: moduleTaskId);
  }

  @override
  Future<void> pause(String moduleTaskId) async {
    final api = await _ensureApi();
    await api.pause(moduleTaskId: moduleTaskId);
  }

  @override
  Future<void> resume(String moduleTaskId) async {
    final api = await _ensureApi();
    await api.resume(moduleTaskId: moduleTaskId);
  }

  @override
  Future<void> cancel(String moduleTaskId) async {
    final api = await _ensureApi();
    await api.cancel(moduleTaskId: moduleTaskId);
  }

  @override
  Future<void> retry(String moduleTaskId) async {
    final api = await _ensureApi();
    await api.retry(moduleTaskId: moduleTaskId);
  }

  @override
  Future<void> restart(String moduleTaskId) async {
    final api = await _ensureApi();
    await api.restart(moduleTaskId: moduleTaskId);
  }

  @override
  Future<void> remove(String moduleTaskId) async {
    final api = await _ensureApi();
    await api.remove(moduleTaskId: moduleTaskId);
  }

  @override
  Stream<rust.DownloadTaskDto> watchAll() async* {
    final api = await _ensureApi();
    yield* api.watchAll();
  }
}

const List<String> _coreStatuses = <String>[
  'queued',
  'connecting',
  'running',
  'downloading',
  'paused',
  'completed',
  'failed',
  'cancelled',
  'removed',
];

DownloadStatusEnum _statusFromCore(String status) {
  switch (status) {
    case 'queued':
      return DownloadStatusEnum.queued;
    case 'connecting':
      return DownloadStatusEnum.connecting;
    case 'running':
    case 'downloading':
      return DownloadStatusEnum.downloading;
    case 'completed':
      return DownloadStatusEnum.completed;
    case 'failed':
      return DownloadStatusEnum.failed;
    case 'cancelled':
    case 'removed':
      return DownloadStatusEnum.cancelled;
    case 'paused':
    case 'needs_restart':
    default:
      return DownloadStatusEnum.paused;
  }
}

int _epochMs(int raw) => raw < 1000000000000 ? raw * 1000 : raw;

List<SegmentInfo>? _segmentsFromJson(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <SegmentInfo>[];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(SegmentInfo.fromMap)
        .toList(growable: false);
  } catch (_) {
    return const <SegmentInfo>[];
  }
}

Map<String, String> _headersFromJson(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <String, String>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const <String, String>{};
    return decoded.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
  } catch (_) {
    return const <String, String>{};
  }
}

/// Maps one core `download_task` projection to the Dart model.
DownloadTask toDownloadTask(rust.DownloadTaskDto dto) {
  final status = dto.status;
  final mapped = _statusFromCore(status);
  final String? error;
  if (status == 'needs_restart' || !_coreStatuses.contains(status)) {
    final rawError = dto.error;
    error = rawError == null || rawError.isEmpty ? status : rawError;
  } else {
    error = dto.error;
  }
  final id = int.tryParse(dto.moduleTaskId ?? '') ?? dto.id.toInt();
  return DownloadTask(
    id: id,
    appId: dto.appId ?? '',
    appName: dto.appName ?? '',
    version: dto.version ?? '',
    fileName: dto.fileName ?? '',
    url: dto.url ?? '',
    filePath: dto.destPath ?? '',
    total: dto.total.toInt(),
    received: dto.bytesDone.toInt(),
    status: mapped,
    speedBps: dto.speedBps.toInt(),
    etaSec: dto.etaSec?.toInt(),
    error: error,
    segments: _segmentsFromJson(dto.segmentsJson),
    headers: _headersFromJson(dto.headersJson),
    installAfterDownload: dto.installAfterDownload,
    lastStartedAt: _epochMs(dto.lastStartedAt?.toInt() ?? 0),
    createdAt:
        DateTime.fromMillisecondsSinceEpoch(_epochMs(dto.createdAt.toInt())),
    updatedAt:
        DateTime.fromMillisecondsSinceEpoch(_epochMs(dto.updatedAt.toInt())),
  );
}

/// Pass-through facade used by Wave 3 Todo 6 wiring and tests.
class DownloadFacade {
  DownloadFacade({
    DownloadBackend? backend,
    DownloadBackend Function()? backendFactory,
  })  : _backend = backend,
        _backendFactory = backendFactory ?? FrbDownloadBackend.new;

  static DownloadFacade instance = DownloadFacade();

  @visibleForTesting
  static DownloadBackend? backendOverride;

  final DownloadBackend? _backend;
  final DownloadBackend Function() _backendFactory;
  DownloadBackend? _resolved;

  DownloadBackend get _target =>
      backendOverride ?? _backend ?? (_resolved ??= _backendFactory());

  /// Runs the one-shot legacy import when the backend supports it.
  ///
  /// Fake/test backends simply have no legacy data to import, so this is a
  /// no-op for them and cannot break the flag routing tests.
  Future<void> importLegacyOnce(
      {String? floorDbPath, String? moduleDbPath}) async {
    final target = _target;
    if (target is DownloadLegacyImport) {
      final legacy = target as DownloadLegacyImport;
      await legacy.importLegacyOnce(
        floorDbPath: floorDbPath,
        moduleDbPath: moduleDbPath,
      );
    }
  }

  /// Runs the three-way download resync when the backend supports it.
  ///
  /// Unlike [importLegacyOnce], a backend without [DownloadResync] throws
  /// [UnsupportedError] instead of silently doing nothing: `apply: true` is a
  /// mutation that writes a snapshot and mirrors rows, so a silent no-op would
  /// be indistinguishable from a successful resync.
  Future<rust.ResyncReportDto> resyncDownloads({
    bool apply = false,
    String? floorDbPath,
  }) async {
    final target = _target;
    if (target is DownloadResync) {
      final resync = target as DownloadResync;
      return resync.resyncDownloads(apply: apply, floorDbPath: floorDbPath);
    }
    throw UnsupportedError('backend does not support download resync');
  }

  Future<int> start(rust.DownloadStartRequest request) =>
      _target.start(request);

  Future<List<rust.DownloadTaskDto>> list() => _target.list();

  Future<rust.DownloadTaskDto?> get(String moduleTaskId) =>
      _target.get(moduleTaskId);

  Future<void> pause(String moduleTaskId) => _target.pause(moduleTaskId);

  Future<void> resume(String moduleTaskId) => _target.resume(moduleTaskId);

  Future<void> cancel(String moduleTaskId) => _target.cancel(moduleTaskId);

  Future<void> retry(String moduleTaskId) => _target.retry(moduleTaskId);

  Future<void> restart(String moduleTaskId) => _target.restart(moduleTaskId);

  Future<void> remove(String moduleTaskId) => _target.remove(moduleTaskId);

  Stream<rust.DownloadTaskDto> watchAll() => _target.watchAll();
}

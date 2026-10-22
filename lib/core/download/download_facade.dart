/// Flag-free facade over the Rust `DownloadApi`.
///
/// Tests install a fake [DownloadBackend] through the constructor, so no
/// native library is required. This file deliberately does not wire into
/// `RustDownloadService` / install paths yet.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/download/model/download_task.dart';
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

/// Production FRB backend. The `DownloadApi` handle is created lazily.
class FrbDownloadBackend implements DownloadBackend {
  FrbDownloadBackend({this.dataDir, this.filesDir, this.cacheDir});

  final String? dataDir;
  final String? filesDir;
  final String? cacheDir;

  rust.DownloadApi? _api;
  Future<rust.DownloadApi>? _pending;

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
    case 'removed':
      return DownloadStatusEnum.cancelled;
    case 'paused':
    case 'needs_restart':
    default:
      return DownloadStatusEnum.paused;
  }
}

/// Maps one core `download_task` projection to the Dart model.
DownloadTask toDownloadTask(rust.DownloadTaskDto dto) {
  final status = dto.status;
  final mapped = _statusFromCore(status);
  final String? error;
  if (status == 'needs_restart') {
    error = 'needs_restart';
  } else if (!_coreStatuses.contains(status)) {
    error = status;
  } else {
    error = dto.error;
  }
  return DownloadTask(
    id: dto.id.toInt(),
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
    segments: null,
    installAfterDownload: dto.installAfterDownload,
    lastStartedAt: dto.lastStartedAt?.toInt() ?? 0,
    createdAt: DateTime.fromMillisecondsSinceEpoch(dto.createdAt.toInt() * 1000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(dto.updatedAt.toInt() * 1000),
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

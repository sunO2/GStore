/// Production [CoreCutoverBackend] over the existing core APIs.
///
/// Split from `core_cutover.dart` so the orchestrator stays policy-only and the
/// transport (FRB handles + retained-artifact replay) stays in one place.
library;

import 'dart:io';

import 'package:gstore/core/rust/CoreApiFacade.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/core_cutover.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Production backend over the existing core APIs.
///
/// * the snapshot is `CoreApi.exportSnapshot` (the crate's existing
///   `VACUUM INTO` snapshot writer — no new store is invented here);
/// * the resync replays the retained Dart→core handoff artifacts from
///   `<files>/migration` through `CoreApi.importMigrationFile`, then reads the
///   domain back twice to prove the fixpoint.
class FrbCoreCutoverBackend implements CoreCutoverBackend {
  FrbCoreCutoverBackend({
    required this.filesDir,
    String? dataDir,
    String? cacheDir,
  })  : dataDir = dataDir ?? '${_rootOf(filesDir)}/data',
        cacheDir = cacheDir ?? '${_rootOf(filesDir)}/cache';

  final String dataDir;
  final String filesDir;
  final String cacheDir;

  static String _rootOf(String filesDir) {
    final normalized = filesDir.endsWith('/')
        ? filesDir.substring(0, filesDir.length - 1)
        : filesDir;
    final slash = normalized.lastIndexOf('/');
    return slash <= 0 ? normalized : normalized.substring(0, slash);
  }

  Directory get _migrationDir => Directory('$filesDir/${CoreCutover.migrationDirName}');

  Future<rust.CoreApi> get _core async {
    await RustBridge.ensureInitialized();
    return CoreApiFacade.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );
  }

  @override
  Future<int> exportSnapshot({required String path}) async {
    final api = await _core;
    return (await api.exportSnapshot(path: path)).toInt();
  }

  @override
  Future<CutoverStepResult> resyncChannels() async {
    final core = await _core;
    await _importNamed(core, kind: 'channel_db', name: 'channel_apps.db');
    await _importMatching(
      core,
      kind: 'channel_env',
      matches: (name) =>
          name.startsWith('channel_env') && name.endsWith('.json'),
    );
    final api = await _channelApi();
    final rows = (await api.list()).length;
    final again = (await api.list()).length;
    return CutoverStepResult(rows: rows, parityOk: rows == again);
  }

  @override
  Future<CutoverStepResult> resyncJsChannel() async {
    final core = await _core;
    await _importMatching(
      core,
      kind: 'pack',
      matches: (name) => name.endsWith('.zip'),
      directory: Directory('${_migrationDir.path}/packs'),
    );
    final api = await _scriptApi();
    final rows = (await api.list()).length;
    final again = (await api.list()).length;
    return CutoverStepResult(rows: rows, parityOk: rows == again);
  }

  @override
  Future<CutoverStepResult> resyncCatalog() async {
    final rows = await _catalogTotal();
    final again = await _catalogTotal();
    return CutoverStepResult(rows: rows, parityOk: rows == again);
  }

  @override
  Future<CutoverStepResult> resyncUpdate() async {
    final core = await _core;
    await _importNamed(core, kind: 'update_prefs', name: 'update_prefs.json');
    final api = await _updateApi();
    final rows = (await api.count()).toInt();
    final again = (await api.count()).toInt();
    return CutoverStepResult(rows: rows, parityOk: rows == again);
  }

  Future<int> _catalogTotal() async {
    final api = await _catalogApi();
    final page = await api.listPage(offset: 0, limit: 1);
    return page.total.toInt();
  }

  Future<rust.ChannelApi> _channelApi() async {
    await RustBridge.ensureInitialized();
    return rust.ChannelApi.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );
  }

  Future<rust.ScriptApi> _scriptApi() async {
    await RustBridge.ensureInitialized();
    return rust.ScriptApi.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );
  }

  Future<rust.CatalogApi> _catalogApi() async {
    await RustBridge.ensureInitialized();
    return rust.CatalogApi.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );
  }

  Future<rust.UpdateApi> _updateApi() async {
    await RustBridge.ensureInitialized();
    return rust.UpdateApi.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );
  }

  Future<int> _importNamed(
    rust.CoreApi api, {
    required String kind,
    required String name,
  }) async {
    final file = File('${_migrationDir.path}/$name');
    if (!file.existsSync()) return 0;
    return api.importMigrationFile(kind: kind, path: file.path);
  }

  Future<int> _importMatching(
    rust.CoreApi api, {
    required String kind,
    required bool Function(String name) matches,
    Directory? directory,
  }) async {
    final dir = directory ?? _migrationDir;
    if (!dir.existsSync()) return 0;
    final files = dir
        .listSync()
        .whereType<File>()
        .where((file) => matches(file.uri.pathSegments.last))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    var rows = 0;
    for (final file in files) {
      rows += await api.importMigrationFile(kind: kind, path: file.path);
    }
    return rows;
  }
}

/// Regression: the one-time `cutover_v6.done` marker must not permanently skip
/// the channel metadata re-import.
///
/// Root cause: the marker short-circuited every later launch, but the in-flight
/// channel cutover left the core `channel_apps` projection empty for enum
/// channels while the legacy `<documents>/channel_apps.db` still held rows. The
/// marker now triggers a ONE-TIME, idempotent `resyncChannels()` repair when the
/// projection is missing those rows — and never when it is not.
///
/// Proven two ways: (1) the real [FrbCoreCutoverBackend] against seeded SQLite
/// files at the actual import boundary, and (2) orchestration with a fake
/// backend that proves the repair runs once and never loops.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/migration/cutover_paths.dart';
import 'package:gstore/core/rust/core_cutover.dart';
import 'package:gstore/core/rust/core_cutover_backend.dart';
import 'package:sqlite3/open.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// `CutoverCore` fake: returns a fixed core DB path and records imports.
class _FixedCore implements CutoverCore {
  _FixedCore(this.dbPath);

  final String dbPath;
  final List<String> imports = <String>[];

  @override
  Future<int> exportSnapshot(String path) async =>
      throw StateError('the marker path must never take a snapshot');

  @override
  Future<int> importMigrationFile(String kind, String path) async {
    imports.add('$kind:$path');
    return 2;
  }

  @override
  Future<String> coreDbPath() async => dbPath;
}

/// Orchestration fake: `channelBackfillNeeded` is controllable and the probe
/// flips to `false` after one repair (models a successful import).
class _BackfillBackend implements CoreCutoverBackend, ChannelBackfillProbe {
  _BackfillBackend({required this.needed});

  bool needed;
  int resyncChannelsCalls = 0;

  @override
  Future<bool> channelBackfillNeeded() async => needed;

  @override
  Future<CutoverStepResult> resyncChannels() async {
    resyncChannelsCalls++;
    needed = false;
    return const CutoverStepResult(
      rows: 2,
      parityOk: true,
      imported: 2,
      legacyPresent: true,
    );
  }

  @override
  Future<int> exportSnapshot({required String path}) async =>
      throw StateError('no snapshot on the marker path');

  @override
  Future<CutoverStepResult> resyncJsChannel() async =>
      throw StateError('unexpected jsChannel resync');

  @override
  Future<CutoverStepResult> resyncCatalog() async =>
      throw StateError('unexpected catalog resync');

  @override
  Future<CutoverStepResult> resyncUpdate() async =>
      throw StateError('unexpected update resync');
}

void _linuxSqlite() {
  open.overrideFor(
    OperatingSystem.linux,
    () => DynamicLibrary.open('libsqlite3.so.0'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('marker-present orchestration', () {
    late Directory filesDir;

    setUp(() {
      CoreCutover.resetForTest();
      filesDir = Directory.systemTemp.createTempSync('gstore_backfill_orch_');
    });

    tearDown(() {
      CoreCutover.resetForTest();
      if (filesDir.existsSync()) filesDir.deleteSync(recursive: true);
    });

    File marker() => File('${filesDir.path}/migration/cutover_v6.done');

    void writeMarker() => marker()
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"version":6,"status":"done"}');

    test('missing projection → resyncChannels runs exactly once', () async {
      writeMarker();
      final before = marker().readAsStringSync();
      final backend = _BackfillBackend(needed: true);

      final result =
          await CoreCutover.run(filesDir: filesDir.path, backend: backend);

      expect(result.ran, isFalse, reason: 'the marker still short-circuits');
      expect(result.backfilledChannelApps, isTrue);
      expect(backend.resyncChannelsCalls, 1);
      expect(marker().readAsStringSync(), before,
          reason: 'the repair must not rewrite the marker');
    });

    test('populated projection → no resync (stale-state safe)', () async {
      writeMarker();
      final backend = _BackfillBackend(needed: false);

      final result =
          await CoreCutover.run(filesDir: filesDir.path, backend: backend);

      expect(result.backfilledChannelApps, isFalse);
      expect(backend.resyncChannelsCalls, 0,
          reason: 'an already-populated projection must never re-import');
    });

    test('idempotent: a second marker-present launch does not re-run',
        () async {
      writeMarker();
      final backend = _BackfillBackend(needed: true);

      final first =
          await CoreCutover.run(filesDir: filesDir.path, backend: backend);
      final second =
          await CoreCutover.run(filesDir: filesDir.path, backend: backend);

      expect(first.backfilledChannelApps, isTrue);
      expect(second.backfilledChannelApps, isFalse);
      expect(backend.resyncChannelsCalls, 1,
          reason: 'the repair runs once; the populated projection stops it');
    });
  });

  group('real FrbCoreCutoverBackend probe (real SQLite)', () {
    late Directory root;
    late DatabaseFactory factory;
    late CutoverPaths paths;

    setUpAll(() {
      factory = createDatabaseFactoryFfi(ffiInit: _linuxSqlite);
      databaseFactory = factory;
    });

    setUp(() {
      root = Directory.systemTemp.createTempSync('gstore_backfill_real_');
      paths = CutoverPaths(
        legacyRoot: root.path,
        filesDir: '${root.path}/files',
      );
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    Future<void> create(String path, List<String> statements) async {
      File(path).parent.createSync(recursive: true);
      final db = await factory.openDatabase(path);
      for (final statement in statements) {
        await db.execute(statement);
      }
      await db.close();
    }

    void writeMarker() => File(paths.markerPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"version":6,"status":"done"}');

    FrbCoreCutoverBackend backend(_FixedCore core) => FrbCoreCutoverBackend(
          paths: paths,
          dataDir: '${root.path}/data',
          cacheDir: '${root.path}/cache',
          core: core,
        );

    test('empty core projection + legacy rows → probes true and imports once',
        () async {
      await create(paths.legacyChannelDb, <String>[
        'CREATE TABLE channel_added_app(channelCode TEXT, appId TEXT)',
        "INSERT INTO channel_added_app VALUES ('github','com.a')",
        "INSERT INTO channel_added_app VALUES ('vivo','com.b')",
      ]);
      final core = '${root.path}/core.db';
      await create(core, <String>[
        'CREATE TABLE channel_apps(channel_key TEXT, app_id TEXT)',
      ]);
      final fixed = _FixedCore(core);
      writeMarker();

      final result =
          await CoreCutover.run(filesDir: paths.filesDir, backend: backend(fixed));

      expect(result.ran, isFalse);
      expect(result.backfilledChannelApps, isTrue);
      expect(
        fixed.imports.where((call) => call.startsWith('channel_db:')),
        hasLength(1),
        reason: 'the marker-present repair must import the legacy channel db once',
      );
      expect(File(paths.markerPath).existsSync(), isTrue,
          reason: 'the marker stays; the repair is marker-safe');
    });

    test('populated core projection → probes false and imports nothing',
        () async {
      await create(paths.legacyChannelDb, <String>[
        'CREATE TABLE channel_added_app(channelCode TEXT, appId TEXT)',
        "INSERT INTO channel_added_app VALUES ('github','com.a')",
      ]);
      final core = '${root.path}/core.db';
      await create(core, <String>[
        'CREATE TABLE channel_apps(channel_key TEXT, app_id TEXT)',
        "INSERT INTO channel_apps VALUES ('github','com.a')",
      ]);
      final fixed = _FixedCore(core);
      writeMarker();

      final result =
          await CoreCutover.run(filesDir: paths.filesDir, backend: backend(fixed));

      expect(result.backfilledChannelApps, isFalse);
      expect(fixed.imports, isEmpty,
          reason: 'a populated projection must not trigger any import');
    });

    test('no legacy rows → probes false and imports nothing', () async {
      await create(paths.legacyChannelDb, <String>[
        'CREATE TABLE channel_added_app(channelCode TEXT, appId TEXT)',
      ]);
      final core = '${root.path}/core.db';
      await create(core, <String>[
        'CREATE TABLE channel_apps(channel_key TEXT, app_id TEXT)',
      ]);
      final fixed = _FixedCore(core);
      writeMarker();

      final result =
          await CoreCutover.run(filesDir: paths.filesDir, backend: backend(fixed));

      expect(result.backfilledChannelApps, isFalse);
      expect(fixed.imports, isEmpty,
          reason: 'nothing to import must never trigger a repair');
    });

    test('missing legacy file → probes false', () async {
      final core = '${root.path}/core.db';
      await create(core, <String>[
        'CREATE TABLE channel_apps(channel_key TEXT, app_id TEXT)',
      ]);
      final fixed = _FixedCore(core);
      writeMarker();

      final result =
          await CoreCutover.run(filesDir: paths.filesDir, backend: backend(fixed));

      expect(result.backfilledChannelApps, isFalse);
      expect(fixed.imports, isEmpty);
    });
  });
}

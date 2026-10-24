/// Durable one-time Wave 6 closeout: `cutover_v6.done` gates exactly one
/// pre-closeout snapshot and one ordered resync (`channels` → `jsChannel` →
/// `catalog` → `update`), then writes the marker atomically.
///
/// Every claim is proven against the real filesystem (file counts, not a spy)
/// so a "success" that created nothing cannot pass. The `real native core`
/// group additionally seeds the real legacy SQLite stores and runs
/// [FrbCoreCutoverBackend] against the host native library.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/migration/cutover_parity.dart';
import 'package:gstore/core/migration/cutover_paths.dart';
import 'package:gstore/core/rust/CoreApiFacade.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/core_cutover.dart';
import 'package:gstore/core/rust/core_cutover_backend.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A syntactically valid 512-byte SQLite header/pages file.
void _writeValidSnapshot(String path) {
  final bytes = List<int>.filled(512, 0);
  const header = 'SQLite format 3\u0000';
  for (var i = 0; i < header.length; i++) {
    bytes[i] = header.codeUnitAt(i);
  }
  bytes[16] = 0x02;
  bytes[17] = 0x00;
  bytes[18] = 1;
  bytes[19] = 1;
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

/// Recording backend: the call order is the contract under test.
class _RecordingBackend implements CoreCutoverBackend {
  _RecordingBackend({
    this.failOn,
    this.parityOk = true,
    this.snapshotError,
  });

  final CutoverDomain? failOn;
  final bool parityOk;
  final Object? snapshotError;

  final List<String> calls = <String>[];

  @override
  Future<int> exportSnapshot({required String path}) async {
    calls.add('snapshot:$path');
    final error = snapshotError;
    if (error != null) throw error;
    _writeValidSnapshot(path);
    return 512;
  }

  Future<CutoverStepResult> _step(CutoverDomain domain, int rows) async {
    calls.add('resync:${domain.name}');
    if (failOn == domain) throw StateError('forced ${domain.name} failure');
    return CutoverStepResult(rows: rows, parityOk: parityOk, imported: rows);
  }

  @override
  Future<CutoverStepResult> resyncChannels() =>
      _step(CutoverDomain.channels, 3);

  @override
  Future<CutoverStepResult> resyncJsChannel() =>
      _step(CutoverDomain.jsChannel, 2);

  @override
  Future<CutoverStepResult> resyncCatalog() => _step(CutoverDomain.catalog, 9);

  @override
  Future<CutoverStepResult> resyncUpdate() => _step(CutoverDomain.update, 4);

  List<String> get resyncOrder => <String>[
        for (final call in calls)
          if (call.startsWith('resync:')) call.substring('resync:'.length),
      ];

  int get snapshotCount =>
      calls.where((call) => call.startsWith('snapshot:')).length;
}

/// Legacy data exists but the import silently writes zero rows.
class _EmptyImportBackend implements CoreCutoverBackend {
  final List<String> calls = <String>[];

  @override
  Future<int> exportSnapshot({required String path}) async {
    _writeValidSnapshot(path);
    return 512;
  }

  @override
  Future<CutoverStepResult> resyncChannels() async {
    calls.add('channels');
    return const CutoverStepResult(
      rows: 2,
      parityOk: true,
      imported: 0,
      legacyPresent: true,
    );
  }

  @override
  Future<CutoverStepResult> resyncJsChannel() async {
    calls.add('jsChannel');
    return const CutoverStepResult(rows: 0, parityOk: true);
  }

  @override
  Future<CutoverStepResult> resyncCatalog() async {
    calls.add('catalog');
    return const CutoverStepResult(rows: 0, parityOk: true);
  }

  @override
  Future<CutoverStepResult> resyncUpdate() async {
    calls.add('update');
    return const CutoverStepResult(rows: 0, parityOk: true);
  }
}

/// A fresh install: no legacy artifacts, so zero imported rows is allowed.
class _FreshBackend implements CoreCutoverBackend {
  @override
  Future<int> exportSnapshot({required String path}) async {
    _writeValidSnapshot(path);
    return 512;
  }

  @override
  Future<CutoverStepResult> resyncChannels() async =>
      const CutoverStepResult(rows: 0, parityOk: true);

  @override
  Future<CutoverStepResult> resyncJsChannel() async =>
      const CutoverStepResult(rows: 0, parityOk: true);

  @override
  Future<CutoverStepResult> resyncCatalog() async =>
      const CutoverStepResult(rows: 0, parityOk: true);

  @override
  Future<CutoverStepResult> resyncUpdate() async =>
      const CutoverStepResult(rows: 0, parityOk: true);
}

/// Core fake that deliberately reports zero rows for every import.
class _ZeroImportCore implements CutoverCore {
  _ZeroImportCore(this.dbPath);

  final String dbPath;

  @override
  Future<int> exportSnapshot(String path) async {
    _writeValidSnapshot(path);
    return 512;
  }

  @override
  Future<int> importMigrationFile(String kind, String path) async => 0;

  @override
  Future<String> coreDbPath() async => dbPath;
}

/// Files matching `<dir>/migration/backups/pre-closeout-*.db`.
List<File> _snapshots(Directory filesDir) {
  final backups = Directory('${filesDir.path}/migration/backups');
  if (!backups.existsSync()) return const <File>[];
  return backups
      .listSync()
      .whereType<File>()
      .where((file) =>
          file.uri.pathSegments.last.startsWith('pre-closeout-') &&
          file.uri.pathSegments.last.endsWith('.db'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

File _marker(Directory filesDir) =>
    File('${filesDir.path}/migration/cutover_v6.done');

void _linuxSqlite() {
  open.overrideFor(
    OperatingSystem.linux,
    () => DynamicLibrary.open('libsqlite3.so.0'),
  );
}

void main() {
  late Directory filesDir;

  setUp(() {
    CoreCutover.resetForTest();
    filesDir = Directory.systemTemp.createTempSync('gstore_cutover_');
  });

  tearDown(() {
    CoreCutover.resetForTest();
    if (filesDir.existsSync()) filesDir.deleteSync(recursive: true);
  });

  test('the path contract pins the shipping legacy locations', () {
    const paths = CutoverPaths(legacyRoot: '/L', filesDir: '/F');
    expect(paths.legacyChannelDb, '/L/channel_apps.db');
    expect(paths.legacyAddedAppsDb, '/L/added_apps.db');
    expect(paths.legacyCatalogDb, '/L/gstore/apps.db');
    expect(paths.legacyPacksDir, '/L/channels');
    expect(paths.migrationDir, '/F/migration');
    expect(paths.updatePrefsDocument, '/F/migration/update_prefs.json');
    expect(paths.markerPath, '/F/migration/cutover_v6.done');
  });

  test('first launch snapshots once, resyncs in order, writes the marker',
      () async {
    final backend = _RecordingBackend();

    final result = await CoreCutover.run(
      filesDir: filesDir.path,
      backend: backend,
      nowMillis: () => 1700000000123,
    );

    expect(result.ran, isTrue);
    expect(result.resynced, <CutoverDomain>[
      CutoverDomain.channels,
      CutoverDomain.jsChannel,
      CutoverDomain.catalog,
      CutoverDomain.update,
    ]);
    expect(backend.resyncOrder, <String>[
      'channels',
      'jsChannel',
      'catalog',
      'update',
    ]);
    expect(result.imported, <CutoverDomain, int>{
      CutoverDomain.channels: 3,
      CutoverDomain.jsChannel: 2,
      CutoverDomain.catalog: 9,
      CutoverDomain.update: 4,
    });

    final snapshots = _snapshots(filesDir);
    expect(snapshots, hasLength(1),
        reason: 'first launch must create exactly one pre-closeout snapshot');
    expect(snapshots.single.path, result.snapshotPath);
    expect(snapshots.single.path,
        endsWith('/migration/backups/pre-closeout-1700000000123.db'));

    expect(_marker(filesDir).existsSync(), isTrue);
    final payload = jsonDecode(_marker(filesDir).readAsStringSync())
        as Map<String, dynamic>;
    expect(payload['imported'], <String, dynamic>{
      'channels': 3,
      'jsChannel': 2,
      'catalog': 9,
      'update': 4,
    });

    final leftovers = Directory('${filesDir.path}/migration')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.uri.pathSegments.last.contains('.tmp'))
        .toList();
    expect(leftovers, isEmpty,
        reason: 'the atomic write must rename, not leak');
  });

  test('second launch is a strict no-op: no snapshot, no resync', () async {
    await CoreCutover.run(
      filesDir: filesDir.path,
      backend: _RecordingBackend(),
      nowMillis: () => 1700000000123,
    );

    final second = _RecordingBackend();
    final result = await CoreCutover.run(
      filesDir: filesDir.path,
      backend: second,
      nowMillis: () => 1800000000000,
    );

    expect(result.ran, isFalse);
    expect(result.resynced, isEmpty);
    expect(second.calls, isEmpty,
        reason: 'the marker must short-circuit before any snapshot/resync');
    expect(_snapshots(filesDir), hasLength(1),
        reason: 'a later launch must never take another snapshot');
  });

  test('a stale marker created out-of-band short-circuits', () async {
    _marker(filesDir)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"version":6,"status":"done"}');

    final backend = _RecordingBackend();
    final result = await CoreCutover.run(
      filesDir: filesDir.path,
      backend: backend,
    );

    expect(result.ran, isFalse);
    expect(backend.calls, isEmpty);
    expect(_snapshots(filesDir), isEmpty);
  });

  test('a resync failure leaves NO marker and retries cleanly', () async {
    final failing = _RecordingBackend(failOn: CutoverDomain.catalog);

    await expectLater(
      CoreCutover.run(
        filesDir: filesDir.path,
        backend: failing,
        nowMillis: () => 1700000000123,
      ),
      throwsA(isA<StateError>()),
    );

    expect(_marker(filesDir).existsSync(), isFalse,
        reason: 'a failed resync must not write the done marker');
    expect(failing.resyncOrder, <String>['channels', 'jsChannel', 'catalog'],
        reason: 'the failure stops the ordered run at catalog');
    expect(_snapshots(filesDir), hasLength(1),
        reason: 'the pre-closeout snapshot was taken before the resync');

    final retry = _RecordingBackend();
    final result = await CoreCutover.run(
      filesDir: filesDir.path,
      backend: retry,
      nowMillis: () => 1900000000000,
    );

    expect(result.ran, isTrue);
    expect(retry.resyncOrder, <String>[
      'channels',
      'jsChannel',
      'catalog',
      'update',
    ]);
    expect(retry.snapshotCount, 0,
        reason: 'a retry must reuse the existing pre-closeout snapshot');
    expect(_snapshots(filesDir), hasLength(1),
        reason: 'exactly one pre-closeout snapshot exists across retries');
    expect(_marker(filesDir).existsSync(), isTrue);
  });

  test('a parity failure leaves NO marker', () async {
    final backend = _RecordingBackend(parityOk: false);

    await expectLater(
      CoreCutover.run(filesDir: filesDir.path, backend: backend),
      throwsA(isA<CoreCutoverException>()),
    );

    expect(_marker(filesDir).existsSync(), isFalse);
    expect(_snapshots(filesDir), hasLength(1));
  });

  test('a snapshot failure leaves NO marker', () async {
    final backend = _RecordingBackend(snapshotError: StateError('disk full'));

    await expectLater(
      CoreCutover.run(filesDir: filesDir.path, backend: backend),
      throwsA(isA<CoreCutoverException>()),
    );

    expect(backend.resyncOrder, isEmpty,
        reason: 'no resync may run when the snapshot failed');
    expect(_marker(filesDir).existsSync(), isFalse);
  });

  test('legacy data present but 0 rows imported fails closed (no marker)',
      () async {
    final backend = _EmptyImportBackend();

    await expectLater(
      CoreCutover.run(
        filesDir: filesDir.path,
        backend: backend,
        nowMillis: () => 1700000000123,
      ),
      throwsA(
        predicate(
          (Object e) =>
              e is CoreCutoverException &&
              e.code == CoreCutoverException.emptyImport,
          'CoreCutoverException(emptyImport)',
        ),
      ),
    );

    expect(backend.calls, <String>['channels'],
        reason: 'the empty import must stop the run immediately');
    expect(_marker(filesDir).existsSync(), isFalse,
        reason: 'an empty resync must never certify the cutover');
  });

  test('a genuinely fresh install completes with zero imported rows', () async {
    final backend = _FreshBackend();

    final result = await CoreCutover.run(
      filesDir: filesDir.path,
      backend: backend,
      nowMillis: () => 1700000000123,
    );

    expect(result.ran, isTrue);
    expect(result.imported.values, everyElement(0));
    expect(_marker(filesDir).existsSync(), isTrue,
        reason: 'no legacy data at all is not a failure');
  });

  test('a partial pre-closeout snapshot is rejected, never reused', () async {
    final backups = Directory('${filesDir.path}/migration/backups')
      ..createSync(recursive: true);
    final partial = File('${backups.path}/pre-closeout-1700000000000.db')
      ..writeAsBytesSync(const <int>[0x53, 0x51, 0x4c, 0x69, 0x74, 0x65]);

    final backend = _RecordingBackend();
    final result = await CoreCutover.run(
      filesDir: filesDir.path,
      backend: backend,
      nowMillis: () => 1700000000123,
    );

    expect(backend.snapshotCount, 1,
        reason: 'the partial file must not be reused');
    expect(result.snapshotPath, endsWith('pre-closeout-1700000000123.db'));
    expect(partial.existsSync(), isFalse,
        reason: 'the rejected partial snapshot is removed');
    expect(_snapshots(filesDir), hasLength(1));
    expect(_marker(filesDir).existsSync(), isTrue);
  });

  test('a valid existing snapshot is reused without a second one', () async {
    final backups = Directory('${filesDir.path}/migration/backups')
      ..createSync(recursive: true);
    final valid = '${backups.path}/pre-closeout-1700000000000.db';
    _writeValidSnapshot(valid);

    final backend = _RecordingBackend();
    final result = await CoreCutover.run(
      filesDir: filesDir.path,
      backend: backend,
      nowMillis: () => 1700000000123,
    );

    expect(backend.snapshotCount, 0);
    expect(result.snapshotPath, valid);
    expect(_snapshots(filesDir), hasLength(1));
  });

  group('row-level parity (real SQLite)', () {
    late Directory root;
    late DatabaseFactory factory;

    setUpAll(() {
      factory = createDatabaseFactoryFfi(ffiInit: _linuxSqlite);
      databaseFactory = factory;
    });

    setUp(() async {
      root = Directory.systemTemp.createTempSync('gstore_cutover_parity_');
    });

    tearDown(() async {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    Future<void> create(
      String path,
      List<String> statements,
    ) async {
      final db = await factory.openDatabase(path);
      for (final statement in statements) {
        await db.execute(statement);
      }
      await db.close();
    }

    test('channels parity fails when one imported row is dropped', () async {
      final legacy = '${root.path}/channel_apps.db';
      final core = '${root.path}/core.db';
      await create(legacy, <String>[
        'CREATE TABLE channel_added_app(channelCode TEXT, appId TEXT)',
        "INSERT INTO channel_added_app VALUES ('github','com.a')",
        "INSERT INTO channel_added_app VALUES ('github','com.b')",
      ]);
      await create(core, <String>[
        'CREATE TABLE channel_apps(channel_key TEXT, app_id TEXT)',
        "INSERT INTO channel_apps VALUES ('github','com.a')",
        "INSERT INTO channel_apps VALUES ('github','com.b')",
      ]);

      const parity = CutoverParity();
      expect(await parity.channels(legacy, core), isTrue);

      final writer = await factory.openDatabase(core);
      await writer.delete('channel_apps',
          where: 'app_id = ?', whereArgs: <Object?>['com.b']);
      await writer.close();

      expect(await parity.channels(legacy, core), isFalse,
          reason: 'a dropped imported row must fail parity');
    });

    test('catalog parity fails when an added app or tag is dropped', () async {
      final added = '${root.path}/added_apps.db';
      final core = '${root.path}/core.db';
      await create(added, <String>[
        'CREATE TABLE added_apps(channelId TEXT, appId TEXT)',
        'CREATE TABLE added_app_tags(channelId TEXT, appId TEXT, tag TEXT)',
        "INSERT INTO added_apps VALUES ('github','com.a')",
        "INSERT INTO added_app_tags VALUES ('github','com.a','tag1')",
      ]);
      await create(core, <String>[
        'CREATE TABLE added_apps(channel_id TEXT, app_id TEXT)',
        'CREATE TABLE added_app_tags(channel_id TEXT, app_id TEXT, tag TEXT)',
        "INSERT INTO added_apps VALUES ('github','com.a')",
        "INSERT INTO added_app_tags VALUES ('github','com.a','tag1')",
      ]);

      const parity = CutoverParity();
      expect(
        await parity.catalog(
          addedAppsPath: added,
          catalogPath: '${root.path}/missing-apps.db',
          corePath: core,
        ),
        isTrue,
      );

      final writer = await factory.openDatabase(core);
      await writer.delete('added_app_tags');
      await writer.close();

      expect(
        await parity.catalog(
          addedAppsPath: added,
          catalogPath: '${root.path}/missing-apps.db',
          corePath: core,
        ),
        isFalse,
        reason: 'a dropped imported tag must fail parity',
      );
    });

    test('update-prefs parity fails when a value is dropped', () async {
      final core = '${root.path}/core.db';
      await create(core, <String>[
        'CREATE TABLE update_prefs(key TEXT, value TEXT)',
      ]);
      const parity = CutoverParity();
      const expected = <String, String>{'update_last_checked_at': '42'};

      expect(await parity.updatePrefs(expected, core), isFalse);

      final writer = await factory.openDatabase(core);
      await writer.insert(
        'update_prefs',
        <String, Object?>{'key': 'update_last_checked_at', 'value': '42'},
      );
      await writer.close();

      expect(await parity.updatePrefs(expected, core), isTrue);
    });

    test('real backend fails closed when present legacy data imports 0 rows',
        () async {
      final legacy = '${root.path}/channel_apps.db';
      await create(legacy, <String>[
        'CREATE TABLE channel_added_app(channelCode TEXT, appId TEXT)',
        "INSERT INTO channel_added_app VALUES ('github','com.a')",
      ]);
      final core = '${root.path}/core.db';
      await create(core, <String>[
        'CREATE TABLE channel_apps(channel_key TEXT, app_id TEXT)',
      ]);

      final paths = CutoverPaths(
        legacyRoot: root.path,
        filesDir: '${root.path}/files',
      );
      final backend = FrbCoreCutoverBackend(
        paths: paths,
        dataDir: '${root.path}/data',
        cacheDir: '${root.path}/cache',
        core: _ZeroImportCore(core),
      );

      await expectLater(
        CoreCutover.run(
          filesDir: paths.filesDir,
          backend: backend,
          nowMillis: () => 1700000000123,
        ),
        throwsA(
          predicate(
            (Object e) =>
                e is CoreCutoverException &&
                e.code == CoreCutoverException.emptyImport,
            'CoreCutoverException(emptyImport)',
          ),
        ),
      );
      expect(File(paths.markerPath).existsSync(), isFalse);
    });
  });

  group('real native core', () {
    final nativeLibDir =
        Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'];
    final nativeAvailable = nativeLibDir != null &&
        Directory(nativeLibDir).existsSync() &&
        Directory(nativeLibDir).listSync().any((entity) =>
            entity.path.split('/').last.startsWith('libgstore_host'));

    late Directory root;
    late CutoverPaths paths;
    late DatabaseFactory factory;
    bool rootReady = false;

    setUpAll(() async {
      RustBridge.debugForceUnavailable = false;
      factory = createDatabaseFactoryFfi(ffiInit: _linuxSqlite);
      databaseFactory = factory;
      SharedPreferences.setMockInitialValues(<String, Object>{
        'update_last_checked_at': 1700000000000,
        'update_results_v1': '[{"appId":"com.a","latestVersion":"2.0"}]',
        'update_check_logs_v1': '[{"text":"checked"}]',
        'update_preferred_apk': '{"github:com.a":"app-2.0.apk"}',
      });
    });

    tearDownAll(() {
      CoreApiFacade.resetForTest();
      RustBridge.debugForceUnavailable = true;
      if (rootReady && root.existsSync()) root.deleteSync(recursive: true);
    });

    setUp(() async {
      root = Directory.systemTemp.createTempSync('gstore_cutover_native_');
      rootReady = true;
      paths = CutoverPaths(
        legacyRoot: '${root.path}/documents',
        filesDir: '${root.path}/support/gstore_core/files',
      );
      Directory(paths.legacyRoot).createSync(recursive: true);
      Directory(paths.filesDir).createSync(recursive: true);
    });

    tearDown(() async {
      CoreCutover.resetForTest();
      CoreApiFacade.resetForTest();
      if (rootReady && root.existsSync()) root.deleteSync(recursive: true);
    });

    Future<void> seedDatabase(String path, List<String> statements) async {
      File(path).parent.createSync(recursive: true);
      final db = await factory.openDatabase(path);
      for (final statement in statements) {
        await db.execute(statement);
      }
      await db.close();
    }

    void seedPack(String path, String entryJs) {
      final archive = Archive()
        ..addFile(ArchiveFile('entry.js', entryJs.length, entryJs.codeUnits));
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(ZipEncoder().encode(archive)!);
    }

    test(
      'imports the real legacy stores and proves non-zero counts + rows',
      () async {
        await seedDatabase(paths.legacyChannelDb, <String>[
          'CREATE TABLE channel_added_app('
              'appId TEXT NOT NULL, name TEXT NOT NULL, user TEXT NOT NULL, '
              'repositories TEXT NOT NULL, apprepo TEXT, icon TEXT NOT NULL, '
              'description TEXT NOT NULL, category TEXT, addTime INTEGER NOT NULL, '
              'channelCode TEXT NOT NULL, extra TEXT, sourceId TEXT, '
              'PRIMARY KEY(channelCode, appId))',
          "INSERT INTO channel_added_app VALUES "
              "('com.a','A','u','r',NULL,'i','d',NULL,10,'github',NULL,NULL),"
              "('com.b','B','u','r',NULL,'i','d',NULL,20,'vivo',NULL,NULL)",
          'PRAGMA user_version = 5',
        ]);
        await seedDatabase(paths.legacyAddedAppsDb, <String>[
          'CREATE TABLE added_apps('
              'id INTEGER PRIMARY KEY AUTOINCREMENT, channelId TEXT NOT NULL, '
              'appId TEXT NOT NULL, addTime INTEGER NOT NULL, '
              'sortOrder INTEGER NOT NULL, isEnabled INTEGER NOT NULL, '
              'UNIQUE(channelId, appId))',
          'CREATE TABLE added_app_tags('
              'channelId TEXT NOT NULL, appId TEXT NOT NULL, tag TEXT NOT NULL, '
              'addTime INTEGER NOT NULL, PRIMARY KEY(channelId, appId, tag))',
          "INSERT INTO added_apps VALUES (1,'github','com.a',10,0,1),"
              "(2,'vivo','com.b',20,1,1)",
          "INSERT INTO added_app_tags VALUES ('github','com.a','tag1',10),"
              "('github','com.a','tag2',11)",
          'PRAGMA user_version = 5',
        ]);
        await seedDatabase(paths.legacyCatalogDb, <String>[
          'CREATE TABLE apps(appId TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, '
              'user TEXT, repositories TEXT, icon TEXT, des TEXT, category TEXT)',
          'CREATE TABLE category(id TEXT NOT NULL PRIMARY KEY, '
              'description TEXT NOT NULL, icon TEXT NOT NULL)',
          'CREATE TABLE config(version TEXT NOT NULL)',
          "INSERT INTO apps VALUES ('com.a','A','u','r','i','d','c'),"
              "('com.b','B','u','r','i','d','c')",
          "INSERT INTO category VALUES ('c','Cat','i')",
          "INSERT INTO config VALUES ('v1')",
        ]);
        seedPack(
          '${paths.legacyPacksDir}/demo.zip',
          'function main(){return {ok:true}};',
        );

        final backend = FrbCoreCutoverBackend(
          paths: paths,
          dataDir: '${root.path}/support/gstore_core/data',
          cacheDir: '${root.path}/support/gstore_core/cache',
        );
        final result = await CoreCutover.run(
          filesDir: paths.filesDir,
          backend: backend,
          nowMillis: () => 1700000000123,
        );

        expect(result.ran, isTrue);
        expect(result.imported[CutoverDomain.channels], 2);
        expect(result.imported[CutoverDomain.jsChannel], 1);
        expect(result.imported[CutoverDomain.catalog], 6,
            reason: '2 added apps + 2 tags + 2 catalog apps');
        expect(result.imported[CutoverDomain.update], 4);

        final marker = File(paths.markerPath);
        expect(marker.existsSync(), isTrue);
        final payload =
            jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>;
        expect(payload['imported'], <String, dynamic>{
          'channels': 2,
          'jsChannel': 1,
          'catalog': 6,
          'update': 4,
        });

        const parity = CutoverParity();
        final coreDb = '${root.path}/support/gstore_core/data/gstore_core.db';
        expect(await parity.channels(paths.legacyChannelDb, coreDb), isTrue);
        expect(
          await parity.catalog(
            addedAppsPath: paths.legacyAddedAppsDb,
            catalogPath: paths.legacyCatalogDb,
            corePath: coreDb,
          ),
          isTrue,
        );
        expect(
          await parity.updatePrefs(
            <String, String>{
              'update_last_checked_at': '1700000000000',
              'update_results_v1': '[{"appId":"com.a","latestVersion":"2.0"}]',
              'update_check_logs_v1': '[{"text":"checked"}]',
              'update_preferred_apk': '{"github:com.a":"app-2.0.apk"}',
            },
            coreDb,
          ),
          isTrue,
        );

        final writer = await factory.openDatabase(coreDb);
        final channelRows = await writer.rawQuery(
          "SELECT app_id FROM channel_apps WHERE channel_key='github'",
        );
        final addedRows = await writer.rawQuery(
          "SELECT app_id FROM added_apps WHERE channel_id='vivo'",
        );
        final catalogRows = await writer.rawQuery(
          "SELECT appId FROM apps WHERE appId='com.a'",
        );
        final prefRows = await writer.rawQuery(
          "SELECT value FROM update_prefs WHERE key='update_last_checked_at'",
        );
        await writer.close();
        expect(channelRows.single['app_id'], 'com.a');
        expect(addedRows.single['app_id'], 'com.b');
        expect(catalogRows.single['appId'], 'com.a');
        expect(prefRows.single['value'], '1700000000000');

        final second = await CoreCutover.run(
          filesDir: paths.filesDir,
          backend: backend,
          nowMillis: () => 1800000000000,
        );
        expect(second.ran, isFalse, reason: 'the marker is one-time');
      },
      skip: nativeAvailable
          ? null
          : 'set FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR and build '
              'rust/gstore_host to run the real cutover',
    );
  });
}

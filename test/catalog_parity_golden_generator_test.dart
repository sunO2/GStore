import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/channel/impl/LocalDbChannel.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart';

/// Golden generator for the Rust catalog/added-apps parity test.
///
/// The golden is produced by the LEGACY Dart readers over the committed input
/// databases. The Rust test (`rust/gstore_core/tests/catalog_parity_golden.rs`)
/// imports the very same databases through the production Rust migrations and
/// compares its real output row-for-row against this golden.
///
/// Regenerate after changing the seed (writes the two `.db` fixtures + the
/// golden JSON):
///
///   GSTORE_WRITE_PARITY_GOLDEN=1 \
///     flutter test test/catalog_parity_golden_generator_test.dart
///
/// In the default mode it only re-derives the legacy output and fails if it
/// drifts from the committed golden (stale-fixture guard).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixtures = Directory(p.join(
    Directory.current.path,
    'rust',
    'gstore_core',
    'tests',
    'fixtures',
  ));
  final catalogFixture = File(p.join(fixtures.path, 'catalog_parity_catalog.db'));
  final addedFixture = File(p.join(fixtures.path, 'catalog_parity_added.db'));
  final goldenFile =
      File(p.join(fixtures.path, 'catalog_parity_golden.json'));
  final writeMode = Platform.environment['GSTORE_WRITE_PARITY_GOLDEN'] == '1';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    sqflite.databaseFactory = createDatabaseFactoryFfi(
      ffiInit: () => open.overrideFor(OperatingSystem.linux,
          () => DynamicLibrary.open('libsqlite3.so.0')),
    );
    // Warm the FFI isolate once so Floor's own `databaseFactoryFfi` (which it
    // selects directly on desktop) reuses the already-loaded library.
    final warm = await sqflite.databaseFactory.openDatabase(':memory:');
    await warm.close();
  });

  test('legacy_golden_matches_committed_fixtures', () async {
    if (writeMode) {
      await fixtures.create(recursive: true);
      await _createCatalogDb(catalogFixture);
      await _createAddedDb(addedFixture);
    }
    expect(catalogFixture.existsSync(), isTrue,
        reason: 'run with GSTORE_WRITE_PARITY_GOLDEN=1 to create fixtures');
    expect(addedFixture.existsSync(), isTrue);

    final snapshot = <String, Object?>{
      'input': <String, Object?>{
        'catalog_db': _inputFile(catalogFixture),
        'added_db': _inputFile(addedFixture),
        'catalog_seed_sql': _catalogSeedSql,
        'added_seed_sql': _addedSeedSql,
      },
      ...await _legacySnapshot(catalogFixture, addedFixture),
    };

    if (writeMode) {
      goldenFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(snapshot)}\n',
      );
    }

    expect(goldenFile.existsSync(), isTrue,
        reason: 'run with GSTORE_WRITE_PARITY_GOLDEN=1 to create the golden');
    final golden = jsonDecode(goldenFile.readAsStringSync());
    expect(snapshot, equals(golden),
        reason: 'legacy output drifted from the committed golden');

    // A golden of empty tables would make the Rust comparison vacuous.
    final added = snapshot['added'] as Map<String, Object?>;
    final catalog = snapshot['catalog'] as Map<String, Object?>;
    expect(added['apps'], hasLength(4));
    expect((added['tags'] as Map), hasLength(4));
    expect(catalog['list'], hasLength(5));
    expect(catalog['categories'], hasLength(3));
    expect(catalog['byCategory'], hasLength(3));
    expect(catalog['one'], isNotNull);
  });
}

Map<String, Object?> _inputFile(File file) {
  final bytes = file.readAsBytesSync();
  return <String, Object?>{
    'sha256': sha256.convert(bytes).toString(),
    'bytes': bytes.length,
  };
}

Future<Map<String, Object?>> _legacySnapshot(
  File catalogFixture,
  File addedFixture,
) async {
  final tmp = await Directory.systemTemp.createTemp('catalog_parity_golden');
  try {
    final catalogCopy = File(p.join(tmp.path, 'catalog.db'));
    final addedCopy = File(p.join(tmp.path, 'added.db'));
    catalogFixture.copySync(catalogCopy.path);
    addedFixture.copySync(addedCopy.path);

    final catalogDb = await $FloorAppInfoDatabase
        .databaseBuilder(catalogCopy.path)
        .build();
    final addedDb = await AppAddedDatabase.create(dbPath: addedCopy.path);
    try {
      final catalog =
          LegacyCatalogBackend(channel: LocalDbChannel(database: catalogDb));
      final manager = AppAggregatorManager.instance..debugDatabase = addedDb;
      final added = LegacyAddedAppsBackend(manager: manager, database: addedDb);

      final list = await catalog.list();
      final categories = await catalog.categories();
      final byCategory = await catalog.byCategory('Tools');
      final one = await catalog.getApp('com.example.alpha');
      final apps = await added.list();
      final tags = await added.tagsIndex();

      return <String, Object?>{
        'added': <String, Object?>{
          'apps': <Map<String, Object?>>[
            for (final app in apps)
              <String, Object?>{
                'channel': app.channelId,
                'appId': app.appId,
                'addTime': app.addTime,
                'sortOrder': app.sortOrder,
                'isEnabled': app.isEnabled,
              },
          ],
          'tags': tags,
        },
        'catalog': <String, Object?>{
          'list': _appRows(list),
          'categories': <List<String>>[
            for (final category in categories)
              <String>[category.id, category.description, category.icon],
          ],
          'byCategory': _appRows(byCategory),
          'one': one == null ? null : _appRows(<dynamic>[one]).single,
        },
      };
    } finally {
      await catalogDb.close();
      await addedDb.close();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  } catch (error) {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
    rethrow;
  }
}

List<Map<String, Object?>> _appRows(List<dynamic> apps) =>
    <Map<String, Object?>>[
      for (final app in apps)
        <String, Object?>{
          'appId': app.appId,
          'packageName': app.packageName,
          'name': app.name,
          'user': app.user,
          'repositories': app.repositories,
          'icon': app.icon,
          'des': app.des,
          'category': app.category,
        },
    ];

const List<String> _catalogSeedSql = <String>[
  'CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, repositories TEXT, icon TEXT, des TEXT, category TEXT, readme TEXT, extra TEXT)',
  'CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL)',
  'CREATE TABLE config(version TEXT NOT NULL, proxy TEXT)',
  "INSERT INTO apps(appId,name,user,repositories,icon,des,category,readme,extra) VALUES('com.example.alpha','Alpha','example','alpha','icon-a','first app','Tools',NULL,NULL)",
  "INSERT INTO apps(appId,name,user,repositories,icon,des,category,readme,extra) VALUES('com.example.beta','Beta','example','beta','icon-b','second app','Proxy',NULL,NULL)",
  "INSERT INTO apps(appId,name,user,repositories,icon,des,category,readme,extra) VALUES('com.example.gamma','Gamma','example','gamma','icon-c','third app','Tools,Proxy',NULL,NULL)",
  "INSERT INTO apps(appId,name,user,repositories,icon,des,category,readme,extra) VALUES('com.example.delta','三角洲','example','delta','icon-d','中文描述','Tools',NULL,NULL)",
  "INSERT INTO apps(appId,name,user,repositories,icon,des,category,readme,extra) VALUES('com.example.epsilon','Epsilon','example','epsilon','icon-e','no category',NULL,NULL,NULL)",
  "INSERT INTO category(id,description,icon) VALUES('Tools','工具','tool.png')",
  "INSERT INTO category(id,description,icon) VALUES('Proxy','代理','proxy.png')",
  "INSERT INTO category(id,description,icon) VALUES('Media','媒体','media.png')",
  "INSERT INTO config(version,proxy) VALUES('2026.10.24',NULL)",
];

const List<String> _addedSeedSql = <String>[
  'CREATE TABLE added_apps(id INTEGER PRIMARY KEY AUTOINCREMENT, channelId TEXT NOT NULL, appId TEXT NOT NULL, addTime INTEGER NOT NULL, sortOrder INTEGER NOT NULL, isEnabled INTEGER NOT NULL)',
  'CREATE UNIQUE INDEX index_added_apps_channelId_appId ON added_apps(channelId, appId)',
  'CREATE TABLE added_app_tags(channelId TEXT NOT NULL, appId TEXT NOT NULL, tag TEXT NOT NULL, addTime INTEGER NOT NULL, PRIMARY KEY (channelId, appId, tag))',
  "INSERT INTO added_apps(id,channelId,appId,addTime,sortOrder,isEnabled) VALUES(11,'github','owner/alpha',1000,0,1)",
  "INSERT INTO added_apps(id,channelId,appId,addTime,sortOrder,isEnabled) VALUES(12,'github','owner/beta',2000,3,0)",
  "INSERT INTO added_apps(id,channelId,appId,addTime,sortOrder,isEnabled) VALUES(13,'local_db','com.example.gamma',3000,1,1)",
  "INSERT INTO added_apps(id,channelId,appId,addTime,sortOrder,isEnabled) VALUES(14,'fdroid','org.example.delta',4000,2,1)",
  "INSERT INTO added_app_tags(channelId,appId,tag,addTime) VALUES('github','owner/alpha','favorite',1001)",
  "INSERT INTO added_app_tags(channelId,appId,tag,addTime) VALUES('github','owner/alpha','work',1002)",
  "INSERT INTO added_app_tags(channelId,appId,tag,addTime) VALUES('github','owner/beta','archive',2001)",
  "INSERT INTO added_app_tags(channelId,appId,tag,addTime) VALUES('local_db','com.example.gamma','tools',3001)",
  "INSERT INTO added_app_tags(channelId,appId,tag,addTime) VALUES('github','ghost','orphan',5000)",
];

Future<void> _createCatalogDb(File file) async {
  if (file.existsSync()) file.deleteSync();
  final db = await sqflite.databaseFactory.openDatabase(
    file.path,
    options: sqflite.OpenDatabaseOptions(
      version: 1,
      onCreate: (sqflite.Database database, int version) async {
        for (final sql in _catalogSeedSql) {
          await database.execute(sql);
        }
      },
    ),
  );
  await db.close();
}

Future<void> _createAddedDb(File file) async {
  if (file.existsSync()) file.deleteSync();
  final db = await sqflite.databaseFactory.openDatabase(
    file.path,
    options: sqflite.OpenDatabaseOptions(
      version: 5,
      onCreate: (sqflite.Database database, int version) async {
        for (final sql in _addedSeedSql) {
          await database.execute(sql);
        }
      },
    ),
  );
  await db.close();
}

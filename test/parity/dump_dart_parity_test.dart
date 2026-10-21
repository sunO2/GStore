import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/impl/LocalDbChannel.dart';
import 'package:gstore/core/data/metadata_repository.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart';

/// Real-SQLite half of the LocalDb parity harness.
///
/// The seed is generated from `assets/app/db/apps.db` by
/// `scripts/qa/gen_parity_fixture.py` and rebuilt by
/// `scripts/qa/parity.sh --channel` on every run.  This test copies the seed to
/// a scratch path, opens it through the generated Floor database (the same
/// `AppInfoDao` the app uses), and drives the production `LocalDbChannel`:
/// `getAllApps`, `searchApps`, `getAppInfo`, and `getAppDetail`.
///
/// Metadata repository calls are pinned to an instant 404 so the production
/// override path runs deterministically without network access; the Rust side
/// runs `LocalDbDriver` without a metadata port, matching "not in metadata".
// Linux QA hosts ship libsqlite3.so.0 (no unversioned dev symlink); sqflite's
// isolate resolves the override through this top-level function.
void _ffiInit() {
  open.overrideFor(
    OperatingSystem.linux,
    () => DynamicLibrary.open('libsqlite3.so.0'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const seed = 'test/fixtures/parity/localdb.db';
  const outputPath = 'target/spike-evidence/parity-dart.json';
  const seedCopy = 'target/spike-evidence/parity-dart-seed.db';
  const searchQuery = 'clash';
  const appId = 'com.artemchep.keyguard';
  const missingAppId = 'com.example.missing';
  const knownCategory = 'PROXY';
  const unknownCategory = 'NO_SUCH_CATEGORY';

  late sqflite.DatabaseFactory factory;

  setUpAll(() {
    // Linux QA hosts ship libsqlite3.so.0; initialize the shared sqflite FFI
    // isolate with the override before Floor resolves its own global factory.
    SharedPreferences.setMockInitialValues(const {});
    factory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
    sqflite.databaseFactory = factory;
    MetadataRepository.instance.debugClient =
        MockClient((_) async => http.Response('not found', 404));
  });

  test('writes real-SQLite LocalDb parity JSON', () async {
    expect(File(seed).existsSync(), isTrue,
        reason: 'run scripts/qa/parity.sh --channel (or the seed generator)');

    final seedFile = File(seed);
    final copy = File(seedCopy);
    copy.parent.createSync(recursive: true);
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final candidate = File('$seedCopy$suffix');
      if (candidate.existsSync()) candidate.deleteSync();
    }
    copy.writeAsBytesSync(seedFile.readAsBytesSync());

    // Floor's `sqfliteDatabaseFactory` is a separate global that lazily picks
    // `databaseFactoryFfi`; touch our factory first so the shared isolate is
    // created with `_ffiInit` (the channel round-trip test relies on the same).
    await factory.getDatabasesPath();

    final database = await $FloorAppInfoDatabase.databaseBuilder(copy.absolute.path).build();
    addTearDown(database.close);
    final channel = LocalDbChannel(database: database);

    final all = await channel.getAllApps();
    expect(all.success, isTrue, reason: '${all.error}');
    final allApps = all.data!;

    final search = await channel.searchApps(searchQuery);
    expect(search.success, isTrue, reason: '${search.error}');

    final emptySearch = await channel.searchApps('');
    expect(emptySearch.success, isTrue);
    expect(emptySearch.data, isEmpty);

    final byCategory = await channel.searchByCategory(knownCategory);
    expect(byCategory.success, isTrue, reason: '${byCategory.error}');

    final byUnknownCategory = await channel.searchByCategory(unknownCategory);
    expect(byUnknownCategory.success, isTrue);
    expect(byUnknownCategory.data, isEmpty);

    final info = await channel.getAppInfo(appId);
    expect(info.success, isTrue, reason: '${info.error}');

    final missingInfo = await channel.getAppInfo(missingAppId);
    expect(missingInfo.success, isTrue);
    expect(missingInfo.data, isNull);

    final detail = await channel.getAppDetail(appId);
    expect(detail.success, isTrue, reason: '${detail.error}');

    final missingDetail = await channel.getAppDetail(missingAppId);
    expect(missingDetail.success, isFalse);
    expect(missingDetail.data, isNull);

    final document = <String, dynamic>{
      'queries': {
        'search': searchQuery,
        'appId': appId,
        'missingAppId': missingAppId,
        'knownCategory': knownCategory,
        'unknownCategory': unknownCategory,
      },
      'getAllApps': allApps.map(_summaryToJson).toList(growable: false),
      'searchApps': search.data!.map(_summaryToJson).toList(growable: false),
      'searchEmpty': emptySearch.data!.map(_summaryToJson).toList(growable: false),
      'searchByCategory': {
        knownCategory:
            byCategory.data!.map(_summaryToJson).toList(growable: false),
        unknownCategory:
            byUnknownCategory.data!.map(_summaryToJson).toList(growable: false),
      },
      'getAppInfo': info.data == null ? null : _summaryToJson(info.data!),
      'getAppInfoMissing': missingInfo.data == null
          ? null
          : _summaryToJson(missingInfo.data!),
      'getAppDetail': detail.data == null ? null : _detailToJson(detail.data!),
      'getAppDetailMissing': missingDetail.data == null
          ? null
          : _detailToJson(missingDetail.data!),
    };

    final output = File(outputPath);
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(document),
    );

    expect(document['getAllApps'], hasLength(allApps.length));
    expect(allApps, hasLength(greaterThanOrEqualTo(3)));
    expect(document['getAppInfo'], isNotNull);
    expect(document['getAppDetail'], isNotNull);
    expect(document['getAppInfoMissing'], isNull);
    expect(document['getAppDetailMissing'], isNull);
    expect(document['searchApps'], isNotEmpty);
  });
}

Map<String, dynamic> _summaryToJson(AppSummary app) => {
  'appId': app.appId,
  'packageName': app.packageName,
  'name': app.name,
  'user': app.user,
  'repositories': app.repositories,
  'icon': app.icon,
  'des': app.des,
  'readme': app.readme,
  'category': app.category,
  'extra': app.extra,
};

/// Detail parity projection.
///
/// The Dart detail object also carries a UI render payload (`extra`: proxy,
/// repository name, apiData) that has no SQLite column; the Rust `AppDetail`
/// model has no equivalent.  Every value compared here comes from the channel's
/// real SQLite read plus the same readme/section fallbacks on both sides.
Map<String, dynamic> _detailToJson(IDetailInfo detail) => {
  'appId': detail.appId,
  'name': detail.appName,
  'icon': detail.icon,
  'description': detail.description,
  'version': detail.version,
  'developer': detail.developer,
  'packageName': detail.packageName.isEmpty ? null : detail.packageName,
  'projectUrl': detail.projectUrl,
  'sections': detail.sections.map((section) => section.name).toList(growable: false),
  'downloads': const <dynamic>[],
  'readme': detail.readme,
};

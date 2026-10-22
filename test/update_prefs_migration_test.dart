import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/migration/migration_handoff.dart';
import 'package:gstore/core/rust/CoreApiFacade.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';
import 'package:gstore/core/update/update_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dedicated update-prefs migration coverage for Wave 2 Todo 9.
///
/// The native group is a real-FRB test and requires
/// `rust/gstore_host/target/release/libgstore_host.so`; build it with
/// `cargo build --manifest-path rust/gstore_host/Cargo.toml --release`.
class _FakeFlagsBackend implements CoreFlagsBackend {
  _FakeFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsSnapshot flags) async {
    snapshot = flags;
  }
}

const List<String> _fourKeys = <String>[
  'update_last_checked_at',
  'update_results_v1',
  'update_check_logs_v1',
  'update_preferred_apk',
];

const Map<String, String> _nativePrefs = <String, String>{
  'update_last_checked_at': '1700000000000',
  'update_results_v1': '[{"appId":"com.example","latestVersion":"2.0"}]',
  'update_check_logs_v1': '[]',
  'update_preferred_apk': '{"github:com.example":"app-2.0.apk"}',
};

File _channelFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}channel_env.json');

File _prefsFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}update_prefs.json');

Map<String, dynamic> _decode(File file) =>
    jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

bool _sqlite3Available() {
  try {
    return Process.runSync('sqlite3', <String>['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<File> _writeDocument(
  Directory dir,
  String name,
  Map<String, Object?> document,
) async {
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsString(jsonEncode(document));
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bool hasSqlite3 = _sqlite3Available();

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = await Directory.systemTemp.createTemp('gstore_update_prefs_');
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  group('exporter', () {
    test('exports exactly the four UpdateCache keys, normalized to strings',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'update_last_checked_at': 1700000000000,
        'update_results_v1': '[{"appId":"com.example"}]',
        'update_check_logs_v1': '[]',
        'update_preferred_apk': '{"github:com.example":"app.apk"}',
        'unrelated_key': 'must not leak',
      });

      final file = await MigrationHandoff.exportUpdatePrefs(into: dir);
      final json = _decode(file);

      expect(json.keys.toSet(), <String>{'version', 'exported_at', 'prefs'});
      expect(json['version'], MigrationHandoff.documentVersion);
      expect(json['version'], 1);
      expect(json['exported_at'], isA<String>());

      final prefs = json['prefs'] as Map<String, dynamic>;
      expect(prefs.keys.toSet(), _fourKeys.toSet());
      expect(prefs.containsKey('unrelated_key'), isFalse);
      expect(prefs['update_last_checked_at'], '1700000000000');
      expect(prefs['update_results_v1'], '[{"appId":"com.example"}]');
      expect(prefs['update_check_logs_v1'], '[]');
      expect(prefs['update_preferred_apk'],
          '{"github:com.example":"app.apk"}');
      expect(prefs.values.every((Object? value) => value is String), isTrue);
      expect(File('${file.path}.tmp').existsSync(), isFalse,
          reason: 'atomic rename must not leave a .tmp sibling');

      if (Platform.isLinux || Platform.isAndroid) {
        final stat = await file.stat();
        expect(stat.mode & 0x1FF, 0x180, reason: 'expected POSIX 0600');
      }
    });

    test('missing keys are omitted and non-string values are normalized',
        () async {
      final file = await MigrationHandoff.exportUpdatePrefs(
        prefs: <String, Object?>{
          'update_last_checked_at': 42,
          'update_check_logs_v1': true,
        },
        into: dir,
      );
      final prefs = _decode(file)['prefs'] as Map<String, dynamic>;

      expect(prefs.keys.toSet(),
          <String>{'update_last_checked_at', 'update_check_logs_v1'});
      expect(prefs['update_last_checked_at'], '42');
      expect(prefs['update_check_logs_v1'], 'true');
      expect(prefs.containsKey('update_results_v1'), isFalse);
      expect(prefs.containsKey('update_preferred_apk'), isFalse);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });
  });

  group('ordered handoff', () {
    test('runs migrate then channel_env then update_prefs and deletes after '
        'each success', () async {
      final calls = <String>[];
      final result = await MigrationHandoff.start(
        into: dir,
        channelKey: 'js.test',
        env: <String, String>{'KEY': 'VALUE'},
        migratePaths: () async => calls.add('migrate'),
        importDocument: (String kind, String path) async {
          calls.add(kind);
          expect(File(path).existsSync(), isTrue,
              reason: '$kind document must exist before its import');
          if (kind == 'update_prefs') {
            expect(_channelFile(dir).existsSync(), isFalse,
                reason: 'channel_env is deleted only after its own import');
            expect(_prefsFile(dir).existsSync(), isTrue);
          }
          return 1;
        },
      );

      expect(calls, <String>['migrate', 'channel_env', 'update_prefs']);
      expect(result.channelEnvImported, isTrue);
      expect(result.updatePrefsImported, isTrue);
      expect(await _channelFile(dir).exists(), isFalse);
      expect(await _prefsFile(dir).exists(), isFalse);
      expect(File('${_prefsFile(dir).path}.tmp').existsSync(), isFalse);
      expect(File('${_channelFile(dir).path}.tmp').existsSync(), isFalse);
    });

    test('a kill at update_prefs import retains the file and retry reuses it '
        'byte-for-byte without re-exporting', () async {
      // A retained (sentinel) document that differs from SharedPreferences
      // proves the retry path never re-exports over it.
      final sentinel = <String, Object?>{
        'version': 1,
        'exported_at': '2020-01-01T00:00:00.000Z',
        'prefs': <String, String>{
          'update_last_checked_at': 'sentinel-value',
          'update_preferred_apk': '{"github:com.example":"sentinel.apk"}',
        },
      };
      final sentinelFile = await _writeDocument(
        dir,
        MigrationHandoff.updatePrefsFileName,
        sentinel,
      );
      final sentinelBytes = await sentinelFile.readAsBytes();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'update_last_checked_at': 999,
        'update_results_v1': 'must-not-be-exported',
      });

      final firstCalls = <String>[];
      await expectLater(
        MigrationHandoff.start(
          into: dir,
          channelKey: 'js.retry',
          env: <String, String>{'SENTINEL': 'keep'},
          migratePaths: () async => firstCalls.add('migrate'),
          importDocument: (String kind, String path) async {
            firstCalls.add(kind);
            if (kind == 'update_prefs') {
              throw StateError('simulated kill during update_prefs import');
            }
            return 1;
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(firstCalls, <String>['migrate', 'channel_env', 'update_prefs']);
      expect(await _channelFile(dir).exists(), isFalse,
          reason: 'channel_env import succeeded and was deleted');
      expect(await _prefsFile(dir).exists(), isTrue,
          reason: 'a failed import retains its document for retry');
      expect(await _prefsFile(dir).readAsBytes(), sentinelBytes,
          reason: 'the retained document must be untouched');

      final secondCalls = <String>[];
      final secondBytes = <String>[];
      String? secondChannelContent;
      final result = await MigrationHandoff.start(
        into: dir,
        channelKey: 'js.retry',
        env: <String, String>{'SENTINEL': 'overwritten'},
        migratePaths: () async => secondCalls.add('migrate'),
        importDocument: (String kind, String path) async {
          secondCalls.add(kind);
          if (kind == 'channel_env') {
            secondChannelContent = await File(path).readAsString();
          } else if (kind == 'update_prefs') {
            secondBytes.add(await File(path).readAsString());
          }
          return 1;
        },
      );

      expect(secondCalls, <String>['migrate', 'channel_env', 'update_prefs']);
      expect(result.updatePrefsImported, isTrue);
      expect(secondBytes.single, utf8.decode(sentinelBytes),
          reason: 'retry must import the retained bytes verbatim');
      expect(secondBytes.single, isNot(contains('must-not-be-exported')),
          reason: 'retry must not re-export from SharedPreferences');
      expect(secondChannelContent, contains('"overwritten"'),
          reason: 'channel_env was imported successfully before the kill, so '
              'the retry re-exports it; only update_prefs is retained');
      expect(await _channelFile(dir).exists(), isFalse);
      expect(await _prefsFile(dir).exists(), isFalse);
      expect(File('${_prefsFile(dir).path}.tmp').existsSync(), isFalse);
      expect(File('${_channelFile(dir).path}.tmp').existsSync(), isFalse);

      final leftover = await dir
          .list()
          .map((FileSystemEntity entity) => entity.uri.pathSegments.last)
          .toList()
        ..sort();
      print('leftover migration files after retry: $leftover');
      expect(leftover, isEmpty);
    });
  });

  group('flag-on routing', () {
    tearDown(() {
      CoreFlags.resetBackend();
      LegacyWriteGuard.probeOverride = null;
    });

    test('default flags (coreWrites false) keep the Dart prefs authoritative',
        () async {
      String? probed;
      LegacyWriteGuard.probeOverride = (String domain) async {
        probed = domain;
        return true;
      };

      await UpdateCache.savePreferredApk('github', 'com.example', 'app.apk');

      expect(probed, isNull,
          reason: 'the probe must not run while coreWrites is false');
      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString('update_preferred_apk')!) as Map;
      expect(stored['github:com.example'], 'app.apk');
    });

    test('coreWrites on plus an update marker blocks the legacy write and '
        'leaves the stored map unchanged', () async {
      const seeded = '{"github:com.example":"old.apk"}';
      SharedPreferences.setMockInitialValues(<String, Object>{
        'update_preferred_apk': seeded,
      });
      CoreFlags.installBackend(
        _FakeFlagsBackend(const CoreFlagsSnapshot(coreWrites: true)),
      );
      await CoreFlags.refresh();
      String? probed;
      LegacyWriteGuard.probeOverride = (String domain) async {
        probed = domain;
        return true;
      };

      await expectLater(
        UpdateCache.savePreferredApk('github', 'com.example', 'new.apk'),
        throwsA(
          predicate(
            (Object e) =>
                e is LegacyWriteBlocked && e.domain == 'update',
            'LegacyWriteBlocked(update)',
          ),
        ),
      );

      expect(probed, 'update');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('update_preferred_apk'), seeded,
          reason: 'a blocked write must not touch the legacy map');
    });

    test('coreWrites on without the update marker allows the legacy write',
        () async {
      CoreFlags.installBackend(
        _FakeFlagsBackend(const CoreFlagsSnapshot(coreWrites: true)),
      );
      await CoreFlags.refresh();
      String? probed;
      LegacyWriteGuard.probeOverride = (String domain) async {
        probed = domain;
        return false;
      };

      await UpdateCache.savePreferredApk('github', 'com.example', 'new.apk');

      expect(probed, 'update');
      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString('update_preferred_apk')!) as Map;
      expect(stored['github:com.example'], 'new.apk');
    });
  });

  group('real native core', () {
    late Directory root;
    late String dataDir;
    late String filesDir;
    late String cacheDir;
    late CoreApi api;

    setUpAll(() async {
      RustBridge.debugForceUnavailable = false;
      root = await Directory.systemTemp.createTemp('gstore_update_prefs_native_');
      dataDir = '${root.path}/data';
      filesDir = '${root.path}/files';
      cacheDir = '${root.path}/cache';
      for (final path in <String>[dataDir, filesDir, cacheDir]) {
        await Directory(path).create(recursive: true);
      }
      api = await CoreApiFacade.init(
        dataDir: dataDir,
        filesDir: filesDir,
        cacheDir: cacheDir,
      );
      await api.migratePaths();
    });

    tearDownAll(() async {
      api.dispose();
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('imports the four keys idempotently and never arms core_writes',
        () async {
      final doc = await _writeDocument(root, 'update_prefs.json', <String, Object?>{
        'version': 1,
        'exported_at': '2026-01-01T00:00:00.000Z',
        'prefs': _nativePrefs,
      });

      expect(
        await api.importMigrationFile(kind: 'update_prefs', path: doc.path),
        4,
      );
      expect(
        await api.importMigrationFile(kind: 'update_prefs', path: doc.path),
        4,
        reason: 're-import upserts the same four keys',
      );

      for (final domain in <String>['channel', 'update', 'download']) {
        expect(await api.coreWrites(domain: domain), isNull,
            reason: 'migration import must not arm $domain');
      }
    });

    test(
      'snapshot exposes the four exact keys and values',
      () async {
        final doc =
            await _writeDocument(root, 'update_prefs_snapshot.json', <String, Object?>{
          'version': 1,
          'prefs': _nativePrefs,
        });
        await api.importMigrationFile(kind: 'update_prefs', path: doc.path);

        final snapshot = '${root.path}/update_prefs_snapshot.db';
        await api.exportSnapshot(path: snapshot);

        final result = await Process.run('sqlite3', <String>[
          snapshot,
          'select key,value from update_prefs order by key',
        ]);
        expect(result.exitCode, 0,
            reason: 'sqlite3 failed: ${result.stderr}');

        final rows = const LineSplitter()
            .convert(result.stdout as String)
            .where((String line) => line.isNotEmpty)
            .map((String line) {
          final split = line.indexOf('|');
          return <String>[
            line.substring(0, split),
            line.substring(split + 1),
          ];
        }).toList();

        print('sqlite3 update_prefs rows: $rows');
        expect(rows, <List<String>>[
          <String>['update_check_logs_v1', _nativePrefs['update_check_logs_v1']!],
          <String>[
            'update_last_checked_at',
            _nativePrefs['update_last_checked_at']!,
          ],
          <String>[
            'update_preferred_apk',
            _nativePrefs['update_preferred_apk']!,
          ],
          <String>['update_results_v1', _nativePrefs['update_results_v1']!],
        ]);
      },
      skip: hasSqlite3 ? null : 'sqlite3 CLI not installed',
    );

    test('malformed and older documents fail with typed errors', () async {
      final older = await _writeDocument(root, 'update_prefs_v2.json', <String, Object?>{
        'version': 2,
        'prefs': _nativePrefs,
      });
      await expectLater(
        api.importMigrationFile(kind: 'update_prefs', path: older.path),
        throwsA(
          predicate(
            (Object e) =>
                e.toString().contains('CORE_E_MIGRATION_VERSION'),
          ),
        ),
      );

      final shape = await _writeDocument(root, 'update_prefs_no_shape.json',
          <String, Object?>{'version': 1});
      await expectLater(
        api.importMigrationFile(kind: 'update_prefs', path: shape.path),
        throwsA(
          predicate(
            (Object e) =>
                e.toString().contains('CORE_E_MIGRATION_SHAPE'),
          ),
        ),
      );

      final empty = await _writeDocument(root, 'update_prefs_empty.json',
          <String, Object?>{'version': 1, 'prefs': <String, Object?>{}});
      expect(
        await api.importMigrationFile(kind: 'update_prefs', path: empty.path),
        0,
      );

      for (final domain in <String>['channel', 'update', 'download']) {
        expect(await api.coreWrites(domain: domain), isNull,
            reason: 'failed imports must not arm $domain');
      }
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/migration/migration_handoff.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory migration;
  late Directory documents;
  late Directory channels;
  late File oldDb;
  late File alphaZip;
  late File betaZip;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = await Directory.systemTemp.createTemp('gstore_channel_migration_');
    migration = Directory('${root.path}/migration');
    documents = Directory('${root.path}/documents');
    channels = Directory('${documents.path}/channels');
    await migration.create(recursive: true);
    await channels.create(recursive: true);
    oldDb = File('${documents.path}/channel_apps.db');
    await oldDb.writeAsBytes(<int>[1, 2, 3, 4, 5], flush: true);
    alphaZip = File('${channels.path}/alpha.zip');
    betaZip = File('${channels.path}/beta.zip');
    await alphaZip.writeAsBytes(<int>[0x50, 0x4b, 0x03, 0x04, 1], flush: true);
    await betaZip.writeAsBytes(<int>[0x50, 0x4b, 0x03, 0x04, 2], flush: true);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('exports, backs up, imports in strict order, then deletes per file',
      () async {
    final calls = <String>[];
    final envModes = <String, int>{};
    final envBodies = <String, String>{};
    final exportEvents = <String>[];

    final result = await MigrationHandoff.startChannelMigration(
      into: migration,
      channelDatabasePath: oldDb.path,
      channelEnvs: const <ChannelEnvExport>[
        ChannelEnvExport(
          channelKey: 'js.pingan',
          env: <String, String>{
            'USER': 'alice',
            'PASSWORD': 'plain-export-secret',
          },
        ),
        ChannelEnvExport(
          channelKey: 'js.letu',
          env: <String, String>{'TOKEN': 'letu-token'},
        ),
      ],
      fdroidDocument: <String, Object?>{
        'sources': <Object?>[
          <String, Object?>{
            'id': 'official',
            'name': 'Official',
            'repoUrl': 'https://f-droid.org/repo',
          },
        ],
        'last_source_id': 'official',
      },
      packsSourceDir: channels,
      proxyUrl: 'http://127.0.0.1:7890',
      onExport: exportEvents.add,
      migratePaths: () async {
        calls.add('migrate');
        // All artifacts exist before the Rust path migration runs.
        expect(
          File('${migration.path}/channel_env.js_pingan.json').existsSync(),
          isTrue,
        );
        expect(
          File('${migration.path}/channel_env.js_letu.json').existsSync(),
          isTrue,
        );
        expect(
            File('${migration.path}/fdroid_sources.json').existsSync(), isTrue);
        expect(File('${migration.path}/packs/alpha.zip').existsSync(), isTrue);
        expect(File('${migration.path}/packs/beta.zip').existsSync(), isTrue);
        expect(Directory('${migration.path}/backups').existsSync(), isTrue);
        // The old DB is copied, never moved.
        expect(oldDb.existsSync(), isTrue);
      },
      importDocument: (kind, path) async {
        final file = File(path);
        expect(file.existsSync(), isTrue,
            reason: '$kind must exist before import');
        if (kind == 'channel_env') {
          final name = path.split(Platform.pathSeparator).last;
          envModes[name] = file.statSync().mode & 0x1FF;
          envBodies[name] = await file.readAsString();
        }
        calls.add(kind);
        return 1;
      },
    );

    expect(calls, <String>[
      'migrate',
      'channel_db',
      'channel_env',
      'channel_env',
      'fdroid_sources',
      'pack',
      'pack',
    ]);
    expect(exportEvents.length, 6, reason: '2 env + fdroid + 2 packs + backup');
    expect(result.channelDbImported, isTrue);
    expect(result.envImported, 2);
    expect(result.fdroidImported, isTrue);
    expect(result.packsImported, 2);
    expect(result.backupsCreated, 1);
    expect(result.envExported, 2);
    expect(result.fdroidExported, 1);
    expect(result.packsCopied, 2);

    if (Platform.isLinux || Platform.isAndroid) {
      expect(envModes.values, everyElement(0x180),
          reason: 'exported env documents must be POSIX 0600');
    }
    final pingan = jsonDecode(envBodies['channel_env.js_pingan.json']!)
        as Map<String, dynamic>;
    expect(pingan['version'], 1);
    expect(pingan['channel_key'], 'js.pingan');
    expect((pingan['env'] as Map<String, dynamic>)['PASSWORD'],
        'plain-export-secret');

    // Each managed file is deleted only after its own import succeeded.
    expect(File('${migration.path}/channel_env.js_pingan.json').existsSync(),
        isFalse);
    expect(File('${migration.path}/channel_env.js_letu.json').existsSync(),
        isFalse);
    expect(File('${migration.path}/fdroid_sources.json').existsSync(), isFalse);
    expect(File('${migration.path}/packs/alpha.zip').existsSync(), isFalse);
    expect(File('${migration.path}/packs/beta.zip').existsSync(), isFalse);

    // Sources are never moved or deleted.
    expect(oldDb.existsSync(), isTrue);
    expect(alphaZip.existsSync(), isTrue);
    expect(betaZip.existsSync(), isTrue);
    final backups = Directory('${migration.path}/backups')
        .listSync()
        .whereType<File>()
        .toList();
    expect(backups, hasLength(1));
    expect(backups.single.path, contains('channel_apps.db.'));
    expect(backups.single.path, endsWith('.bak'));
  });

  test('failure retains files and retry reuses them without re-export',
      () async {
    final exportEvents = <String>[];
    final firstCalls = <String>[];
    final secondCalls = <String>[];
    final secondBodies = <String, String>{};
    var failFirstEnv = true;

    Future<ChannelMigrationResult> run(
      List<String> calls,
      Future<int> Function(String, String) importDocument,
    ) {
      return MigrationHandoff.startChannelMigration(
        into: migration,
        channelDatabasePath: oldDb.path,
        channelEnvs: const <ChannelEnvExport>[
          ChannelEnvExport(
            channelKey: 'js.pingan',
            env: <String, String>{'SENTINEL': 'keep-this-export'},
          ),
          ChannelEnvExport(
            channelKey: 'js.letu',
            env: <String, String>{'SECOND': 'retained'},
          ),
        ],
        fdroidDocument: <String, Object?>{
          'sources': <Object?>[
            <String, Object?>{
              'id': 'official',
              'name': 'Official',
              'repoUrl': 'https://f-droid.org/repo',
            },
          ],
          'last_source_id': 'official',
        },
        packsSourceDir: channels,
        onExport: exportEvents.add,
        migratePaths: () async {
          calls.add('migrate');
        },
        importDocument: importDocument,
      );
    }

    await expectLater(
      run(firstCalls, (kind, path) async {
        firstCalls.add(kind);
        if (kind == 'channel_env' && failFirstEnv) {
          failFirstEnv = false;
          throw StateError('simulated mid-handoff failure');
        }
        return 1;
      }),
      throwsA(isA<StateError>()),
    );

    final retainedExports = exportEvents.length;
    expect(firstCalls, <String>['migrate', 'channel_db', 'channel_env']);
    expect(retainedExports, 6,
        reason: 'exports happen once before the failure');
    final envPingan = File('${migration.path}/channel_env.js_pingan.json');
    final envLetu = File('${migration.path}/channel_env.js_letu.json');
    final fdroid = File('${migration.path}/fdroid_sources.json');
    final packAlpha = File('${migration.path}/packs/alpha.zip');
    final packBeta = File('${migration.path}/packs/beta.zip');
    for (final file in <File>[
      envPingan,
      envLetu,
      fdroid,
      packAlpha,
      packBeta
    ]) {
      expect(file.existsSync(), isTrue,
          reason: '${file.path} must be retained');
    }
    final retainedBody = await envPingan.readAsString();
    expect(retainedBody, contains('keep-this-export'));

    final result = await run(secondCalls, (kind, path) async {
      secondCalls.add(kind);
      if (kind == 'channel_env' &&
          path.endsWith('channel_env.js_pingan.json')) {
        secondBodies[path] = await File(path).readAsString();
      }
      return 1;
    });

    expect(secondCalls, <String>[
      'migrate',
      'channel_db',
      'channel_env',
      'channel_env',
      'fdroid_sources',
      'pack',
      'pack',
    ]);
    expect(exportEvents.length, retainedExports,
        reason: 'retry must reuse retained files without re-exporting');
    expect(result.envExported, 0);
    expect(result.fdroidExported, 0);
    expect(result.packsCopied, 0);
    expect(result.backupsCreated, 0);
    expect(secondBodies[envPingan.path], retainedBody,
        reason: 'retained env document must be imported verbatim');
    expect(await envPingan.exists(), isFalse);
    expect(await envLetu.exists(), isFalse);
    expect(await fdroid.exists(), isFalse);
    expect(await packAlpha.exists(), isFalse);
    expect(await packBeta.exists(), isFalse);
    expect(oldDb.existsSync(), isTrue);
    expect(alphaZip.existsSync(), isTrue);
  });

  test('missing optional artifacts are skipped without failing', () async {
    await oldDb.delete();
    final calls = <String>[];
    final result = await MigrationHandoff.startChannelMigration(
      into: migration,
      channelDatabasePath: oldDb.path,
      channelEnvs: const <ChannelEnvExport>[],
      fdroidDocument: <String, Object?>{'sources': <Object?>[]},
      packsSourceDir: Directory('${root.path}/no-channels'),
      migratePaths: () async => calls.add('migrate'),
      importDocument: (kind, path) async {
        calls.add(kind);
        return 1;
      },
    );
    expect(calls, <String>['migrate', 'fdroid_sources']);
    expect(result.channelDbImported, isFalse);
    expect(result.envImported, 0);
    expect(result.packsImported, 0);
    expect(result.fdroidImported, isTrue);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/migration/migration_handoff.dart';
import 'package:shared_preferences/shared_preferences.dart';

File _channelFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}channel_env.json');

File _prefsFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}update_prefs.json');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = await Directory.systemTemp.createTemp('gstore_handoff_');
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  test('exportChannelEnv writes versioned JSON and 0600 mode', () async {
    final file = await MigrationHandoff.exportChannelEnv(
      channelKey: 'js.pingan',
      env: <String, String>{'PINGAN_USER': 'alice', 'PINGAN_PASS': 'secret'},
      into: dir,
    );

    expect(await file.exists(), isTrue);
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(json['version'], MigrationHandoff.documentVersion);
    expect(json['version'], 1);
    expect(json['channel_key'], 'js.pingan');
    expect(json['exported_at'], isA<String>());
    expect(
      json['env'],
      <String, dynamic>{'PINGAN_USER': 'alice', 'PINGAN_PASS': 'secret'},
    );

    if (Platform.isLinux || Platform.isAndroid) {
      final stat = await file.stat();
      expect(stat.mode & 0x1FF, 0x180, reason: 'expected POSIX 0600');
    }
  });

  test('exportUpdatePrefs normalizes values to strings', () async {
    final file = await MigrationHandoff.exportUpdatePrefs(
      prefs: <String, Object?>{
        'update_last_checked_at': 1700000000000,
        'update_preferred_apk': '{"github:app":"app.apk"}',
        'some_flag': true,
      },
      into: dir,
    );

    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(json['version'], 1);
    final prefs = json['prefs'] as Map<String, dynamic>;
    expect(prefs['update_last_checked_at'], '1700000000000');
    expect(prefs['update_preferred_apk'], '{"github:app":"app.apk"}');
    expect(prefs['some_flag'], 'true');
    expect(prefs.values.every((v) => v is String), isTrue);
  });

  test('start runs migrate then imports in order and deletes after commit',
      () async {
    final calls = <String>[];
    final result = await MigrationHandoff.start(
      into: dir,
      channelKey: 'js.test',
      env: <String, String>{'KEY': 'VALUE'},
      migratePaths: () async {
        calls.add('migrate');
      },
      importDocument: (kind, path) async {
        calls.add(kind);
        expect(File(path).existsSync(), isTrue,
            reason: '$kind document must exist before import');
        return 1;
      },
    );

    expect(calls, <String>['migrate', 'channel_env', 'update_prefs']);
    expect(result.channelEnvImported, isTrue);
    expect(result.updatePrefsImported, isTrue);
    expect(await _channelFile(dir).exists(), isFalse);
    expect(await _prefsFile(dir).exists(), isFalse);
  });

  test('start retains files after failure and resumes without re-export',
      () async {
    await MigrationHandoff.exportChannelEnv(
      channelKey: 'js.retry',
      env: <String, String>{'SENTINEL': 'keep'},
      into: dir,
    );
    await MigrationHandoff.exportUpdatePrefs(
      prefs: <String, Object?>{'update_last_checked_at': 42},
      into: dir,
    );

    final firstCalls = <String>[];
    await expectLater(
      MigrationHandoff.start(
        into: dir,
        channelKey: 'js.retry',
        env: <String, String>{'SENTINEL': 'overwritten'},
        migratePaths: () async {
          firstCalls.add('migrate');
        },
        importDocument: (kind, path) async {
          firstCalls.add(kind);
          if (kind == 'channel_env') {
            throw StateError('simulated mid-handoff failure');
          }
          return 1;
        },
      ),
      throwsA(isA<StateError>()),
    );

    expect(firstCalls, <String>['migrate', 'channel_env']);
    expect(await _channelFile(dir).exists(), isTrue,
        reason: 'channel_env is retained when its import fails');
    expect(await _prefsFile(dir).exists(), isTrue,
        reason: 'update_prefs is retained because it was never imported');

    final retained =
        jsonDecode(await _channelFile(dir).readAsString()) as Map<String, dynamic>;
    expect((retained['env'] as Map<String, dynamic>)['SENTINEL'], 'keep');

    final secondCalls = <String>[];
    String? importedChannelContent;
    final result = await MigrationHandoff.start(
      into: dir,
      channelKey: 'js.retry',
      env: <String, String>{'SENTINEL': 'overwritten'},
      migratePaths: () async {
        secondCalls.add('migrate');
      },
      importDocument: (kind, path) async {
        secondCalls.add(kind);
        if (kind == 'channel_env') {
          importedChannelContent = await File(path).readAsString();
        }
        return 1;
      },
    );

    expect(secondCalls, <String>['migrate', 'channel_env', 'update_prefs']);
    expect(result.channelEnvImported, isTrue);
    expect(result.updatePrefsImported, isTrue);
    expect(importedChannelContent, contains('"keep"'));
    expect(importedChannelContent, isNot(contains('overwritten')),
        reason: 'a retained document must not be re-exported over');
    expect(await _channelFile(dir).exists(), isFalse);
    expect(await _prefsFile(dir).exists(), isFalse);
  });
}

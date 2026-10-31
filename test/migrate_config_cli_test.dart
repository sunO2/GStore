// Todo 22 acceptance tests: offline `tool/migrate_config.dart` CLI.
//
// This test runs the CLI as a real process (plain Dart VM, no Flutter engine,
// no device, no network) so it also proves the tool does not need the FRB
// `ConfigApi` to run.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _cli = 'tool/migrate_config.dart';
const String _fixture = 'test/fixtures/legacy_cli_export.json';

ProcessResult _run(List<String> args) {
  return Process.runSync(
    'dart',
    <String>['run', _cli, ...args],
    workingDirectory: Directory.current.path,
  );
}

Map<String, Object?> _decodeStdout(ProcessResult result) {
  return jsonDecode(result.stdout.toString()) as Map<String, Object?>;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('task22_cli_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('dry-run prints grouped config + >=12 per-key entries and writes nothing',
      () {
    final outPath = '${tempDir.path}/should_not_exist.json';
    final result = _run(<String>['--dry-run', _fixture, '--out', outPath]);

    expect(result.exitCode, 0, reason: result.stderr.toString());
    final report = _decodeStdout(result);
    expect(report['mode'], 'dry-run');

    final summary = report['summary'] as Map<String, Object?>;
    expect(summary['mappedEntries'], greaterThanOrEqualTo(12));
    expect(summary['failed'], 0);

    final config = report['config'] as Map<String, Object?>;
    expect(config, isNotEmpty);

    final keys = report['keys'] as List<Object?>;
    expect(keys.length, greaterThanOrEqualTo(12));
    for (final entry in keys) {
      final map = entry as Map<String, Object?>;
      expect(map['storageKey'], isA<String>());
      expect(map['wireKey'], isA<String>());
      expect(map['status'], isA<String>());
      // The per-key report never carries a value.
      expect(map.containsKey('value'), isFalse);
    }

    // stale_state: dry-run must not create the requested output file.
    expect(File(outPath).existsSync(), isFalse);
  });

  test('invalid JSON exits 1 with a typed error', () {
    final input = File('${tempDir.path}/invalid.json')
      ..writeAsStringSync('{not json');

    final result = _run(<String>['--dry-run', input.path]);

    expect(result.exitCode, 1);
    final errorEnvelope =
        jsonDecode(result.stderr.toString()) as Map<String, Object?>;
    final error = errorEnvelope['error'] as Map<String, Object?>;
    expect(error['code'], 'invalid_json');
  });

  test('a bad value is reported per key and exits 1 without aborting others',
      () {
    final input = File('${tempDir.path}/bad_values.json')
      ..writeAsStringSync(jsonEncode(<String, Object?>{
        'prefs': <String, Object?>{
          'config_download_max_concurrent': 'not-a-number',
          'config_download_wifi_only': true,
          'config_theme_mode': 2,
        },
      }));

    final result = _run(<String>['--dry-run', input.path]);

    expect(result.exitCode, 1);
    final report = _decodeStdout(result);
    final keys = report['keys'] as List<Object?>;
    final failed = keys
        .cast<Map<String, Object?>>()
        .where((entry) => entry['status'] == 'failed')
        .toList();
    expect(failed, hasLength(1));
    expect(failed.single['wireKey'], 'download.max_concurrent');
    expect(failed.single['code'], 'config_invalid_int');
    // The other present keys still mapped.
    expect(
      keys.cast<Map<String, Object?>>().where(
            (entry) => entry['status'] == 'applied',
          ),
      hasLength(2),
    );
  });

  test('real mode writes grouped JSON via --out', () {
    final outPath = '${tempDir.path}/grouped.json';
    final result = _run(<String>[_fixture, '--out', outPath]);

    expect(result.exitCode, 0, reason: result.stderr.toString());
    final report = _decodeStdout(result);
    expect(report['written'], isTrue);

    final written = File(outPath);
    expect(written.existsSync(), isTrue);
    final grouped = jsonDecode(written.readAsStringSync()) as Map<String, Object?>;
    expect(grouped['download'], isA<Map<String, Object?>>());
    expect(grouped['webdav'], isA<Map<String, Object?>>());
  });
}

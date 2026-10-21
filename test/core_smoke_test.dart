import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/debug/core_smoke.dart';

/// Pure tests for the debug-only core smoke fixture.
///
/// No FFI, no platform channels, no device: the pack builder and the
/// `enabled` gate are plain Dart, so these run anywhere `flutter test` runs.
void main() {
  group('CoreSmoke.buildSmokePackZip', () {
    test('produces a decodable flat pack zip with entry.js and meta.json',
        () {
      final bytes = CoreSmoke.buildSmokePackZip();
      final sw = Stopwatch()..start();

      expect(bytes, isNotEmpty, reason: 'zip bytes must not be empty');
      // ZIP local-file-header magic: the Rust importer rejects non-zips before
      // it ever reads a central directory.
      expect(
        bytes.take(4).toList(),
        <int>[0x50, 0x4b, 0x03, 0x04],
        reason: 'pack must start with the PK\\x03\\x04 magic',
      );

      final archive = ZipDecoder().decodeBytes(bytes);
      final names = archive.files.map((file) => file.name).toList()
        ..sort();
      // Flat legacy layout only: the Rust validator rejects anything outside
      // entry.js / detail.js / meta.json / icons/*.
      expect(names, <String>['entry.js', 'meta.json']);

      final entry = archive.findFile('entry.js');
      expect(entry, isNotNull, reason: 'entry.js is required');
      final entryText = utf8.decode(entry!.content as List<int>);
      expect(entryText.trim(), isNotEmpty,
          reason: 'Rust rejects an empty entry.js');

      final metaFile = archive.findFile('meta.json');
      expect(metaFile, isNotNull, reason: 'meta.json carries the fixture key');
      final meta =
          jsonDecode(utf8.decode(metaFile!.content as List<int>))
              as Map<String, dynamic>;
      expect(meta['key'], 'js_smoke',
          reason: 'the Rust legacy key is js_<zip stem>');
      expect(meta['name'], isA<String>());
      expect(meta['entry'], 'entry.js');
      expect(meta['requiredEnvVars'], <String>['SMOKE'],
          reason: 'must satisfy the Rust requiredEnvVars validator');

      for (final file in archive.files) {
        final size = (file.content as List<int>).length;
        // misleading-success guard: print the real entry names/bytes.
        // ignore: avoid_print
        print('smoke pack entry name=${file.name} bytes=$size');
      }
      // ignore: avoid_print
      print('smoke pack encoded bytes=${bytes.length} '
          'decode_ms=${sw.elapsedMilliseconds}');
    });

    test('is deterministic so a repeated run upserts instead of duplicating',
        () {
      // stale_state: identical bytes -> identical sha256 -> the pack importer
      // reuses the version directory and upserts the same channel_packs row.
      expect(CoreSmoke.buildSmokePackZip(), CoreSmoke.buildSmokePackZip());
    });
  });

  group('CoreSmoke.enabled', () {
    test('is disabled without the GSTORE_CORE_SMOKE define', () {
      // Default `flutter test` environment: no --dart-define, so startup is
      // inert (the call site is also kDebugMode-guarded).
      expect(CoreSmoke.enabled, isFalse);
    });
  });
}

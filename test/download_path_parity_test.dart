import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/download/core_download_builder.dart';
import 'package:gstore/core/download/download_paths.dart';

/// Records every `start` call; returns a fixed task id.
class _RecordingApi implements CoreDownloadApi {
  final List<CoreDownloadRequest> calls = <CoreDownloadRequest>[];
  int nextId = 42;

  @override
  Future<int> start(CoreDownloadRequest request) async {
    calls.add(request);
    return nextId;
  }
}

class _FakeFlagsBackend implements CoreFlagsBackend {
  _FakeFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsPatch patch) async {
    snapshot = CoreFlagsSnapshot(
      channels: patch.channel ?? snapshot.channels,
      catalog: patch.catalog ?? snapshot.catalog,
      update: patch.update ?? snapshot.update,
      download: patch.download ?? snapshot.download,
      install: patch.install ?? snapshot.install,
      jsChannel: patch.jsChannel ?? snapshot.jsChannel,
      coreWrites: snapshot.coreWrites,
    );
  }
}

Future<void> _useDownloadFlag(bool value) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(download: value)),
  );
  await CoreFlags.refresh();
}

List<Map<String, dynamic>> _loadFixture() {
  final file = File('test/fixtures/download_path_cases.json');
  expect(file.existsSync(), isTrue,
      reason: 'missing shared fixture at ${file.path}');
  final decoded = jsonDecode(file.readAsStringSync());
  expect(decoded, isA<List<dynamic>>());
  return (decoded as List<dynamic>).cast<Map<String, dynamic>>();
}

void main() {
  tearDown(CoreFlags.resetBackend);

  group('resolveSavePath parity with Rust fixture', () {
    test('every shared case resolves to the exact expected string', () async {
      final cases = _loadFixture();
      expect(cases, isNotEmpty, reason: 'fixture must contain cases');

      for (final c in cases) {
        final downloadsDir = c['downloads_dir'] as String?;
        final actual = await DownloadPaths.resolveSavePath(
          saveFileName: c['save_file_name'] as String?,
          fileName: c['file_name'] as String,
          downloadsDirProvider: () async =>
              downloadsDir == null ? null : Directory(downloadsDir),
          docsDirProvider: () async => Directory(c['docs_dir'] as String),
        );
        expect(actual, c['expected'], reason: 'case: ${c['name']}');
      }
    });

    test('relative saveFileName is not treated as absolute', () async {
      final dest = await DownloadPaths.resolveSavePath(
        saveFileName: 'relative/name.apk',
        fileName: 'fallback.apk',
        downloadsDirProvider: () async => Directory('/downloads'),
        docsDirProvider: () async => Directory('/docs'),
      );
      expect(dest, '/downloads/fallback.apk');
    });

    test('no providers still consults path_provider (regression guard)',
        () async {
      // In a plain unit-test environment path_provider has no usable
      // implementation, so the default (non-injected) path must fail inside
      // path_provider instead of silently returning a path. This pins down
      // that providers are opt-in and default behaviour is unchanged.
      await expectLater(
        DownloadPaths.resolveSavePath(fileName: 'app.apk'),
        throwsA(anyOf(
          isA<MissingPluginException>(),
          isA<UnsupportedError>(),
        )),
      );
    });
  });

  group('CoreDownloadBuilder parity', () {
    test('absolute saveFileName wins and metadata matches Rust rule', () async {
      final req = await CoreDownloadBuilder.build(
        appId: 'com.example.app',
        appName: 'Example',
        version: '1.2.3',
        fileName: 'server-name.apk',
        url: 'https://example.com/app.apk',
        saveFileName: '/tmp/absolute/app.apk',
        downloadsDir: '/downloads',
        docsDir: '/docs',
        expectedSha256: 'abc123',
        installAfterDownload: true,
      );

      expect(req.destPath, '/tmp/absolute/app.apk');
      expect(req.kind, 'app');
      expect(req.resourceId, 'com.example.app');
      expect(req.resourceVersion, '1.2.3');
      expect(req.dedupKey, 'app:com.example.app:1.2.3:server-name.apk');
      expect(req.expectedSha256, 'abc123');
      expect(req.installAfterDownload, isTrue);
      expect(req.appId, 'com.example.app');
      expect(req.appName, 'Example');
      expect(req.version, '1.2.3');
      expect(req.fileName, 'server-name.apk');
      expect(req.url, 'https://example.com/app.apk');
    });

    test('relative saveFileName falls back to downloads dir', () async {
      final req = await CoreDownloadBuilder.build(
        appId: 'com.example.app',
        appName: 'Example',
        version: '1.2.3',
        fileName: 'fallback.apk',
        url: 'https://example.com/app.apk',
        saveFileName: 'relative/name.apk',
        downloadsDir: '/downloads',
        docsDir: '/docs',
      );

      expect(req.destPath, '/downloads/fallback.apk');
      expect(req.expectedSha256, isNull);
      expect(req.installAfterDownload, isFalse);
    });

    test('absent saveFileName joins downloads dir', () async {
      final req = await CoreDownloadBuilder.build(
        appId: 'a',
        appName: 'A',
        version: '1',
        fileName: 'app.apk',
        url: 'https://example.com/app.apk',
        downloadsDir: '/downloads',
        docsDir: '/docs',
      );

      expect(req.destPath, '/downloads/app.apk');
    });

    test('absent downloads dir falls back to docs dir', () async {
      final req = await CoreDownloadBuilder.build(
        appId: 'a',
        appName: 'A',
        version: '1',
        fileName: 'app.apk',
        url: 'https://example.com/app.apk',
        docsDir: '/docs',
      );

      expect(req.destPath, '/docs/app.apk');
    });
  });

  group('CoreFlags.download gating', () {
    test('flag off: startIfEnabled returns null and never calls the api',
        () async {
      await _useDownloadFlag(false);
      final api = _RecordingApi();
      final req = await CoreDownloadBuilder.build(
        appId: 'a',
        appName: 'A',
        version: '1',
        fileName: 'app.apk',
        url: 'https://example.com/app.apk',
        docsDir: '/docs',
      );

      final id = await CoreDownloadBuilder.startIfEnabled(api, req);

      expect(id, isNull);
      expect(api.calls, isEmpty);
    });

    test('flag on: returns api id and calls exactly once with built request',
        () async {
      await _useDownloadFlag(true);
      final api = _RecordingApi();
      final req = await CoreDownloadBuilder.build(
        appId: 'a',
        appName: 'A',
        version: '1',
        fileName: 'app.apk',
        url: 'https://example.com/app.apk',
        docsDir: '/docs',
      );

      final id = await CoreDownloadBuilder.startIfEnabled(api, req);

      expect(id, 42);
      expect(api.calls, hasLength(1));
      final sent = api.calls.single;
      expect(identical(sent, req), isTrue);
      expect(sent.destPath, '/docs/app.apk');
      expect(sent.dedupKey, 'app:a:1:app.apk');
    });
  });
}

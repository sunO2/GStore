/// Repro/regression for the settings **script-channel import** path on the Rust
/// lane (user report: "js 渠道导入压根不生效").
///
/// The startup load path (`ChannelLoader.loadAndRegister`) is covered by
/// `script_channel_production_test.dart`. This file covers the OTHER production
/// entry point: the Settings → 脚本渠道 → pick a .zip flow, which calls
/// `ChannelLoader.importZip` (lib/core/channel/impl/channel_loader.dart).
///
/// Real-native group (needs the host library):
///
/// ```sh
/// cargo build --release --manifest-path rust/gstore_host/Cargo.toml
/// FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR=$PWD/rust/gstore_host/target/release \
///   flutter test test/js_channel_import_rust_lane_test.dart
/// ```
///
/// Without that env var the native group is skipped, not failed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_channel_service.dart';

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

Future<void> _setFlag({required bool jsChannel, bool channels = false}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(
      CoreFlagsSnapshot(jsChannel: jsChannel, channels: channels),
    ),
  );
  await CoreFlags.refresh();
  expect(CoreFlags.jsChannel, jsChannel);
}

Uint8List _zip(String entry, {String? detail, String? meta}) {
  final bytes = utf8.encode(entry);
  final archive = Archive()
    ..addFile(ArchiveFile('entry.js', bytes.length, bytes));
  if (detail != null) {
    final detailBytes = utf8.encode(detail);
    archive.addFile(ArchiveFile('detail.js', detailBytes.length, detailBytes));
  }
  if (meta != null) {
    final metaBytes = utf8.encode(meta);
    archive.addFile(ArchiveFile('meta.json', metaBytes.length, metaBytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// Deterministic fixture: the returned value is composed from the input, so no
/// harness constant can satisfy the assertion.
const String _vivoScript = '''
const CHANNEL_META = { name: 'vivo 渠道', description: 'import fixture' };
function main(method, params) {
  params = params || {};
  if (method === 'getAllApps') {
    return { ok: true, data: 'imported:' + (params.token || '') };
  }
  return null;
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final nativeLibDir =
      Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'];
  final nativeAvailable = nativeLibDir != null &&
      Directory(nativeLibDir).existsSync() &&
      Directory(nativeLibDir).listSync().any(
          (entity) => entity.path.split('/').last.startsWith('libgstore_host'));
  final skipReason = nativeAvailable
      ? null
      : 'native host library not loadable: build rust/gstore_host and set '
          'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR='
          'rust/gstore_host/target/release/';

  group('settings importZip on the real Rust lane (jsChannel ON)', () {
    late Directory root;

    setUpAll(() {
      RustBridge.debugForceUnavailable = false;
    });

    tearDownAll(() {
      RustBridge.debugForceUnavailable = true;
      ScriptApi.resetBackend();
      ScriptChannelService.resetForTest();
      RustScriptChannelLane.resetForTest();
      CoreFlags.resetBackend();
    });

    setUp(() async {
      root = await Directory.systemTemp.createTemp('gstore_js_import_');
      ScriptChannelService.installForTest(ScriptChannelService(
        coreDirs: () async => (
          '${root.path}/gstore_core/data',
          '${root.path}/gstore_core/files',
          '${root.path}/gstore_core/cache',
        ),
      ));
      RustScriptChannelLane.resetForTest();
      await _setFlag(jsChannel: true);
    });

    tearDown(() async {
      ScriptChannelService.resetForTest();
      RustScriptChannelLane.resetForTest();
      ScriptApi.resetBackend();
      CoreFlags.resetBackend();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'importZip returns a ScriptLaneChannelImport and installs into the Rust lane',
      () async {
        final bytes = _zip(
          _vivoScript,
          meta: '{"name":"vivo 渠道","description":"import fixture"}',
        );

        final result = await ChannelLoader().importZip(
          channelKey: 'js_vivo',
          zipBytes: bytes,
        );

        expect(result, isA<ScriptLaneChannelImport>());
        final pack = (result as ScriptLaneChannelImport).pack;
        expect(pack.key, 'js_vivo');
        expect(pack.name, 'vivo 渠道');

        // The pack is really installed in the Rust store.
        final listed = await ScriptApi.instance.list();
        expect(listed.map((p) => p.key), contains('js_vivo'));

        // The UI-facing lane cache is populated right after the import, so the
        // settings list / discovery grid can see it without a restart.
        expect(RustScriptChannelLane.instance.codes, contains('js_vivo'));

        // And the installed pack is actually usable through the Rust runtime.
        final raw = await ScriptApi.instance.run(
          key: 'js_vivo',
          method: 'getAllApps',
          paramsJson: '{"token":"e2e"}',
        );
        expect(jsonDecode(raw), 'imported:e2e');
      },
      skip: skipReason,
    );

    test(
      'importZip of a pack with a malformed meta.json still surfaces and runs it',
      () async {
        // Regression: a malformed optional meta.json (BOM / trailing comma) is
        // ignored by the Dart decoder and accepted by the legacy-permissive
        // import, but used to make ScriptApi.list() fail wholesale — so the
        // channel imported "successfully" yet never appeared in the lane.
        final bytes = _zip(_vivoScript, meta: '{"name": "vivo",');

        final result = await ChannelLoader().importZip(
          channelKey: 'js_vivo',
          zipBytes: bytes,
        );
        expect(result, isA<ScriptLaneChannelImport>());

        // The lane cache must be populated right after the import (this is what
        // discovery + settings read), and the pack must be runnable.
        final lane = RustScriptChannelLane.instance;
        expect(lane.codes, contains('js_vivo'),
            reason: 'a malformed meta.json must not hide the imported channel');
        final raw = await ScriptApi.instance.run(
          key: 'js_vivo',
          method: 'getAllApps',
          paramsJson: '{"token":"badmeta"}',
        );
        expect(jsonDecode(raw), 'imported:badmeta');
      },
      skip: skipReason,
    );

    test(
      're-importing the same pack is idempotent (no duplicate lane entry)',
      () async {
        final bytes = _zip(_vivoScript, meta: '{"name":"vivo 渠道"}');
        await ChannelLoader().importZip(channelKey: 'js_vivo', zipBytes: bytes);
        await ChannelLoader().importZip(channelKey: 'js_vivo', zipBytes: bytes);

        final lane = RustScriptChannelLane.instance;
        expect(lane.codes.where((c) => c == 'js_vivo'), hasLength(1));
        final listed = await ScriptApi.instance.list();
        expect(listed.where((p) => p.key == 'js_vivo'), hasLength(1));
      },
      skip: skipReason,
    );
  });

  group('importZip lane selection is flag-driven', () {
    setUp(() {
      ScriptChannelService.installForTest(ScriptChannelService(
        coreDirs: () async => ('', '', ''),
        api: ScriptApi(backend: _RecordingScriptApi()),
      ));
      RustScriptChannelLane.resetForTest();
    });

    tearDown(() {
      ScriptChannelService.resetForTest();
      RustScriptChannelLane.resetForTest();
      ScriptApi.resetBackend();
      CoreFlags.resetBackend();
    });

    test('jsChannel OFF + channels ON throws ChannelImportDisabledException',
        () async {
      await _setFlag(jsChannel: false, channels: true);
      await expectLater(
        ChannelLoader().importZip(
          channelKey: 'js_vivo',
          zipBytes: _zip(_vivoScript),
        ),
        throwsA(isA<ChannelImportDisabledException>()),
      );
    });
  });
}

/// Minimal ScriptApi backend so the flag-off group never touches FFI.
class _RecordingScriptApi implements ScriptApiBackend {
  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {}

  @override
  Future<rust_pack.ScriptPackInfo> import_({
    required List<int> packZipBytes,
    String? expectedKey,
  }) async =>
      rust_pack.ScriptPackInfo(
        key: expectedKey ?? 'js_unknown',
        name: 'recorded',
        description: '',
        icon: '',
        hasDetail: false,
      );

  @override
  Future<void> remove({required String key}) async {}

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async =>
      rust_pack.ScriptPackInfo(
        key: key,
        name: 'recorded',
        description: '',
        icon: '',
        hasDetail: false,
      );

  @override
  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  }) async {}

  @override
  Future<Map<String, String>> getEnv({required String key}) async => const {};

  @override
  Future<void> setConfig({
    required String key,
    required Map<String, String> config,
  }) async {}

  @override
  Future<String> run({
    required String key,
    required String method,
    required String paramsJson,
  }) async =>
      'null';

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async =>
      const <rust_pack.ScriptPackInfo>[];

  @override
  Future<String> storedApps({required String key}) async => '[]';

  @override
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {}

  @override
  Future<void> releaseDetail({
    required String key,
    required String appId,
  }) async {}
}

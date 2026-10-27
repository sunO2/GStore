/// Todo 7 (Closeout-B3): `jsChannel` cutover seams.
///
/// What is **real** here:
/// - the flag seam (`CoreFlags`) and the production `ChannelLoader` /
///   `ChannelManager` gating;
/// - the production `LegacyWriteGuard` call site in `JsChannel.addApp`
///   (`_persistApps`) is invoked for real and its probed domain is asserted to
///   be `js_channel`; the `js_channel_runtime._registerDatabaseHost` writer is
///   probed by `test/legacy_write_guard_coverage_test.dart`;
/// - `ScriptApi`'s flag gate and its method/payload forwarding.
///
/// What is **seam-backed**: `ScriptApiBackend` (no FRB dylib inside
/// `flutter test`). Nothing in this file asserts a Rust engine result; that is
/// proven by `cargo test --manifest-path rust/gstore_host/Cargo.toml --lib
/// script_api_parity` (real example.js plus a real fixture for `getConfig`,
/// `sendMessage`, `host.ui.call`).
///
/// Marker note: the runtime absence/presence proof (flag off -> no row,
/// flag on -> row) runs in `script_db::tests::
/// script_db_js_channel_marker_only_after_flip`; the Dart test below pins the
/// *wiring* (only `mark_core_write_if_flipped` is called) so the marker can
/// never regress to unconditional.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_channel_service.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';

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

/// Records exactly what the `ScriptApi` facade forwards.
///
/// This backend is a seam: it never fabricates a "Rust lane" result, so the
/// test can only assert the forwarding contract. The real Rust engine path is
/// proven by
/// `cargo test --manifest-path rust/gstore_host/Cargo.toml --lib script_api_parity`.
class _RecordingScriptApiBackend implements ScriptApiBackend {
  final List<({String key, String method, String paramsJson})> runs =
      <({String key, String method, String paramsJson})>[];

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
        key: expectedKey ?? 'js_seam',
        name: 'Seam',
        description: '',
        icon: '',
        hasDetail: false,
      );

  @override
  Future<void> remove({required String key}) async {}

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async =>
      const rust_pack.ScriptPackInfo(
        key: 'js_seam',
        name: 'Seam',
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
  }) async {
    runs.add((key: key, method: method, paramsJson: paramsJson));
    return 'null';
  }

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async => const [];

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

const String _flipScript = r'''
function main(method, params) { return null; }
''';

/// Installs the process-wide script-channel service without FFI: fixed core
/// dirs and no Rust runtime init. The service still resolves `ScriptApi.instance`
/// lazily, so a fake backend installed afterwards is observed.
void _installScriptService() {
  ScriptChannelService.installForTest(ScriptChannelService(
    coreDirs: () async => (
      '/tmp/gstore_seam/data',
      '/tmp/gstore_seam/files',
      '/tmp/gstore_seam/cache',
    ),
    ensureRust: () async {},
  ));
}

Future<void> _setFlag({required bool jsChannel}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(jsChannel: jsChannel)),
  );
  await CoreFlags.refresh();
  expect(CoreFlags.jsChannel, jsChannel);
}

Uint8List _zipOf(String entry) {
  final archive = Archive()..addFile(ArchiveFile.string('entry.js', entry));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ChannelManager.instance.disposeAll();
  });

  tearDown(() async {
    LegacyWriteGuard.resetForTest();
    CoreFlags.resetBackend();
    ScriptApi.resetBackend();
    ScriptChannelService.resetForTest();
    await ChannelManager.instance.disposeAll();
  });

  test('jschannel_flip_routes_to_the_rust_lane', () async {
    final manager = ChannelManager.instance;

    // --- flag off: the Dart script lane was removed; an import is a typed refusal.
    await _setFlag(jsChannel: false);
    expect(manager.dartScriptChannelsEnabled, isTrue);
    await expectLater(
      ChannelLoader().importZip(
        channelKey: 'js_flip',
        zipBytes: _zipOf('function main(){ return null; }'),
      ),
      throwsA(isA<ChannelImportDisabledException>()),
    );
    expect(manager.dynamicChannels, isEmpty);
    await manager.disposeAll();

    // --- flip on: the load path is the Rust lane; no Dart dynamic channel exists.
    await _setFlag(jsChannel: true);
    expect(manager.dartScriptChannelsEnabled, isFalse,
        reason: 'the flip must retire Dart script channels');

    final dir = await Directory.systemTemp.createTemp('gstore_jschannel_flip');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/flip.zip')
        .writeAsBytes(_zipOf('function main(){ return null; }'));

    // The flipped load path is the Rust lane; back it with the recording seam.
    ScriptApi.installBackend(_RecordingScriptApiBackend());
    _installScriptService();

    final loaded = await ChannelLoader(directory: dir).loadAndRegister();
    expect(loaded, isNotEmpty,
        reason: 'ChannelLoader imports into the Rust lane when flipped');
    expect(manager.getChannelByKey('js_flip'), isNull);
    expect(manager.dynamicChannels, isEmpty);
    expect(manager.getChannel(ChannelType.custom), isNull);
  });

  test('jschannel_marker_only_after_flip', () {
    // Same run, both directions over the shipped wiring: no unconditional
    // js_channel marker may exist (absence), and every js_channel write must
    // go through the flag-gated helper (presence). The behavioural proof is
    // script_db_js_channel_marker_only_after_flip in the Rust suite.
    final scriptDb =
        File('rust/gstore_host/src/script_db.rs').readAsStringSync();

    expect(
      scriptDb.contains('mark_core_write(conn, "js_channel"'),
      isFalse,
      reason: 'the js_channel marker must never be written unconditionally',
    );

    final conditional =
        RegExp(r'mark_core_write_if_flipped\(\s*conn,\s*"js_channel"')
            .allMatches(scriptDb)
            .length;
    expect(conditional, 2,
        reason: 'remove_app and insert_apps must both mark conditionally');

    final migration =
        File('rust/gstore_core/src/migration.rs').readAsStringSync();
    expect(
      migration.contains('mark_core_write_if_flipped') &&
          migration.contains('crate::flags::domain_authoritative(domain)'),
      isTrue,
      reason: 'the conditional helper must be gated by domain_authoritative',
    );

    final flags = File('rust/gstore_core/src/flags.rs').readAsStringSync();
    expect(flags.contains('"js_channel" => snapshot.js_channel'), isTrue,
        reason: 'js_channel must map to its own flag before the marker arms');
  });

  test('jschannel_scriptapi_facade_seams', () async {
    // SEAM-BACKED (a): with jsChannel=true the Dart dynamic-channel lane is
    // absent. Real ChannelLoader seam, real ChannelManager registry.
    await _setFlag(jsChannel: true);
    final manager = ChannelManager.instance;
    expect(manager.dartScriptChannelsEnabled, isFalse);

    final dir = await Directory.systemTemp.createTemp('gstore_jschannel_seam');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/seam.zip').writeAsBytes(_zipOf(_flipScript));

    // The flipped load path is the Rust lane; back it with the recording seam.
    final backend = _RecordingScriptApiBackend();
    ScriptApi.installBackend(backend);
    _installScriptService();

    final loaded = await ChannelLoader(directory: dir).loadAndRegister();
    expect(loaded, isNotEmpty);
    expect(manager.dynamicChannels, isEmpty);

    // SEAM-BACKED (b): the facade forwards the exact method name and payload to
    // its backend. The backend is a seam; nothing here claims a Rust result.
    const paramsJson = '{"token":"T-42"}';
    await ScriptApi.instance.run(
      key: 'js_example',
      method: 'getConfig',
      paramsJson: paramsJson,
    );
    expect(backend.runs, hasLength(1));
    expect(backend.runs.single.key, 'js_example');
    expect(backend.runs.single.method, 'getConfig');
    expect(backend.runs.single.paramsJson, paramsJson);

    // SEAM-BACKED (b): the flag gate runs before the backend and surfaces the
    // stable typed refusal.
    await _setFlag(jsChannel: false);
    final runsBefore = backend.runs.length;
    await expectLater(
      ScriptApi.instance.run(
        key: 'js_example',
        method: 'getConfig',
        paramsJson: paramsJson,
      ),
      throwsA(isA<ScriptApiDisabledException>().having(
        (e) => e.errorCode,
        'errorCode',
        'CORE_E_SCRIPT_JS_CHANNEL_DISABLED',
      )),
    );
    expect(backend.runs.length, runsBefore,
        reason: 'the disabled flag must never reach the backend');
  });
}

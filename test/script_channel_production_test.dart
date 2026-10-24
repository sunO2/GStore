/// Production wiring for the Rust script-channel lane (Plan-Todo 7, Final F1).
///
/// `CoreFlags.jsChannel` is the cutover default, and `ChannelManager` refuses to
/// register Dart `JsChannel`s while it is on. These tests prove the other half:
/// the **production** load path (`ChannelLoader.loadAndRegister`, the entry point
/// `ChannelIntegration` calls at module startup) imports stored packs into the
/// real Rust lane through `ScriptApi`, and the legacy Dart lane is untouched
/// while the flag is off.
///
/// Real-native group (needs the host library):
///
/// ```sh
/// cargo build --release --manifest-path rust/gstore_host/Cargo.toml
/// FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR=$PWD/rust/gstore_host/target/release \
///   flutter test test/script_channel_production_test.dart
/// ```
///
/// Without that env var the native group is skipped, not failed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_channel_service.dart';

/// Flags are read through this fake so the test never needs the native
/// `CoreFlags` backend (the flag itself is the only thing under test here).
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

Future<void> _setFlag({required bool jsChannel}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(jsChannel: jsChannel)),
  );
  await CoreFlags.refresh();
  expect(CoreFlags.jsChannel, jsChannel);
}

Uint8List _zip(String entry, {String? meta}) {
  // Encode as UTF-8 and declare the real byte length: the Rust pack decoder
  // validates the zip header's uncompressed size, and example.js contains
  // multi-byte characters that `ArchiveFile.string` would under-declare.
  final bytes = utf8.encode(entry);
  final archive = Archive()
    ..addFile(ArchiveFile('entry.js', bytes.length, bytes));
  if (meta != null) {
    final metaBytes = utf8.encode(meta);
    archive.addFile(ArchiveFile('meta.json', metaBytes.length, metaBytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// Deterministic fixture: the returned value is composed by the script from its
/// input, so no harness constant can satisfy the assertion.
const String _sendMessageScript = '''
const CHANNEL_META = { name: 'sendmsg fixture', description: 'deterministic' };
function main(method, params) {
  params = params || {};
  if (method === 'getAllApps') {
    return { ok: true, data: 'send:' + (params.token || '') };
  }
  if (method === 'searchApps') {
    return { ok: true, data: [] };
  }
  return null;
}
''';

/// Records whether the facade was reached; used for the flag-off proof that the
/// legacy Dart lane never touches the Rust pack store.
class _RecordingScriptApiBackend implements ScriptApiBackend {
  final List<String> calls = <String>[];
  final List<String> importedKeys = <String>[];

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {
    calls.add('init');
  }

  @override
  Future<rust_pack.ScriptPackInfo> import_({
    required List<int> packZipBytes,
    String? expectedKey,
  }) async {
    calls.add('import:${expectedKey ?? ''}');
    importedKeys.add(expectedKey ?? '');
    return rust_pack.ScriptPackInfo(
      key: expectedKey ?? 'js_unknown',
      name: 'recorded',
      description: '',
      icon: '',
      hasDetail: false,
    );
  }

  @override
  Future<void> remove({required String key}) async => calls.add('remove:$key');

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async {
    calls.add('refresh:$key');
    return rust_pack.ScriptPackInfo(
      key: key,
      name: 'recorded',
      description: '',
      icon: '',
      hasDetail: false,
    );
  }

  @override
  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  }) async =>
      calls.add('setEnv:$key');

  @override
  Future<void> setConfig({
    required String key,
    required Map<String, String> config,
  }) async =>
      calls.add('setConfig:$key');

  @override
  Future<String> run({
    required String key,
    required String method,
    required String paramsJson,
  }) async {
    calls.add('run:$key:$method');
    return '{"ok":true,"data":null}';
  }

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async {
    calls.add('list');
    return const <rust_pack.ScriptPackInfo>[];
  }

  @override
  Future<String> storedApps({required String key}) async {
    calls.add('storedApps:$key');
    return '[]';
  }

  @override
  Future<void> releaseDetail({
    required String key,
    required String appId,
  }) async =>
      calls.add('releaseDetail:$key:$appId');
}

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

  group('real native script lane (jsChannel ON)', () {
    late Directory root;
    late Directory channelDir;

    setUpAll(() {
      // This group needs the real FFI bridge; the global test config disables it.
      RustBridge.debugForceUnavailable = false;
    });

    tearDownAll(() {
      RustBridge.debugForceUnavailable = true;
      ScriptApi.resetBackend();
      ScriptChannelService.resetForTest();
      CoreFlags.resetBackend();
    });

    setUp(() async {
      root = await Directory.systemTemp.createTemp('gstore_script_prod_');
      channelDir = Directory('${root.path}/channels')
        ..createSync(recursive: true);
      // Real example.js pack: proves the shipped asset survives the production
      // load path, not a synthetic fixture only.
      final example =
          await File('assets/channels/example.js').readAsString();
      await File('${channelDir.path}/example.zip').writeAsBytes(_zip(example));
      await File('${channelDir.path}/sendmsg.zip').writeAsBytes(_zip(
        _sendMessageScript,
        meta: '{"name":"sendmsg fixture","description":"deterministic"}',
      ));
      // Inject only the core dirs; RustBridge/FFI stay real (the point of the
      // group). Production uses CutoverPaths.defaultCoreDirs() here.
      ScriptChannelService.installForTest(ScriptChannelService(
        coreDirs: () async => (
          '${root.path}/gstore_core/data',
          '${root.path}/gstore_core/files',
          '${root.path}/gstore_core/cache',
        ),
      ));
      await _setFlag(jsChannel: true);
    });

    tearDown(() async {
      ScriptChannelService.resetForTest();
      CoreFlags.resetBackend();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'loadAndRegister imports stored packs into the real Rust lane and run returns the script value',
      () async {
        final loaded = await ChannelLoader(directory: channelDir).loadAndRegister();
        expect(loaded, isEmpty,
            reason: 'flag on must not build Dart JsChannels');

        final packs = await ScriptApi.instance.list();
        expect(packs.map((p) => p.key).toSet(),
            <String>{'js_example', 'js_sendmsg'});
        expect(packs.firstWhere((p) => p.key == 'js_sendmsg').name,
            'sendmsg fixture');

        final raw = await ScriptApi.instance.run(
          key: 'js_sendmsg',
          method: 'getAllApps',
          paramsJson: '{"token":"real-9"}',
        );
        // ScriptApi.run returns the unwrapped `data` value the Dart runtime
        // would have received (same contract as `JsChannel._callMain`).
        expect(jsonDecode(raw), 'send:real-9');

        // The shipped example asset runs through the same real runtime (its
        // empty-keyword search short-circuits before any network call).
        final example = await ScriptApi.instance.run(
          key: 'js_example',
          method: 'searchApps',
          paramsJson: '{"keyword":""}',
        );
        expect(jsonDecode(example), isEmpty);
      },
      skip: skipReason,
    );

    test(
      'reloading the same directory is idempotent (no duplicate packs)',
      () async {
        await ChannelLoader(directory: channelDir).loadAndRegister();
        final first = await ScriptApi.instance.list();
        expect(first, hasLength(2));

        await ChannelLoader(directory: channelDir).loadAndRegister();
        final second = await ScriptApi.instance.list();
        expect(second.map((p) => p.key).toList(),
            first.map((p) => p.key).toList());

        final raw = await ScriptApi.instance.run(
          key: 'js_sendmsg',
          method: 'getAllApps',
          paramsJson: '{"token":"again"}',
        );
        expect(jsonDecode(raw), 'send:again');
      },
      skip: skipReason,
    );
  });

  group('legacy Dart lane (jsChannel OFF)', () {
    late Directory root;
    late _RecordingScriptApiBackend backend;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('gstore_script_legacy_');
      backend = _RecordingScriptApiBackend();
      ScriptApi.installBackend(backend);
      await _setFlag(jsChannel: false);
    });

    tearDown(() async {
      ScriptApi.resetBackend();
      CoreFlags.resetBackend();
      await ChannelManager.instance.disposeAll();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('loadAndRegister keeps the Dart JsChannel path and never calls ScriptApi',
        () async {
      final dir = Directory('${root.path}/channels')..createSync(recursive: true);
      await File('${dir.path}/gate.zip').writeAsBytes(_zip(_sendMessageScript));

      final loaded = await ChannelLoader(directory: dir).loadAndRegister();

      expect(loaded.map((channel) => channel.channelKey), <String>['js_gate']);
      expect(loaded.single, isA<JsChannel>());
      expect(ChannelManager.instance.getChannelByKey('js_gate'),
          same(loaded.single));
      expect(backend.calls, isEmpty,
          reason: 'flag off must never reach the Rust pack store');
    });
  });
}

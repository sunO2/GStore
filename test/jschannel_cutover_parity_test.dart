/// Todo 7 (Closeout-B3): `jsChannel` cutover parity.
///
/// What is **real** here:
/// - the flag seam (`CoreFlags`) and the production `ChannelLoader` /
///   `ChannelManager` gating;
/// - the production `LegacyWriteGuard` call sites: `JsChannel.addApp`
///   (`_persistApps`) and `JsChannelRuntime` (`_registerDatabaseHost`) are
///   invoked for real and their probed domain is asserted to be `js_channel`;
/// - `ScriptApi`'s flag gate + `getConfig` mapping;
/// - the Dart-lane fixture runs on the real QuickJS engine (`JsChannelRuntime`)
///   and the real `assets/channels/example.js` bytes go through the real
///   `ScriptApi.import_` facade.
///
/// What is **seam-backed**: `ScriptApiBackend` (no FRB dylib inside
/// `flutter test`), i.e. the *Rust host responses* are replayed. The Rust
/// engine path for the same contracts is covered by
/// `cargo test --manifest-path rust/gstore_host/Cargo.toml script_api` and the
/// `core_writes` marker behaviour by `cargo test ... script_db`.
///
/// Marker note: the runtime absence/presence proof (flag off -> no row,
/// flag on -> row) runs in `script_db::tests::
/// script_db_js_channel_marker_only_after_flip`; the Dart test below pins the
/// *wiring* (only `mark_core_write_if_flipped` is called) so the marker can
/// never regress to unconditional.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/js/js_channel_runtime.dart';
import 'package:gstore/core/js/js_native_host.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/script_api.dart';
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

/// In-memory `ChannelAddedAppDao` so the real writer executes without Floor.
class _FakeAppDao implements ChannelAddedAppDao {
  final List<ChannelAddedApp> apps = <ChannelAddedApp>[];

  @override
  Future<void> insertApp(ChannelAddedApp app) async {
    apps
      ..removeWhere(
          (a) => a.channelCode == app.channelCode && a.appId == app.appId)
      ..add(app);
  }

  @override
  Future<void> insertApps(List<ChannelAddedApp> rows) async {
    for (final row in rows) {
      await insertApp(row);
    }
  }

  @override
  Future<void> removeApp(String appId, String channelCode) async {
    apps.removeWhere((a) => a.appId == appId && a.channelCode == channelCode);
  }

  @override
  Future<List<ChannelAddedApp>> getAppsByChannel(String channelCode) async =>
      apps.where((a) => a.channelCode == channelCode).toList();

  @override
  Future<int?> getCountByChannel(String channelCode) async =>
      apps.where((a) => a.channelCode == channelCode).length;

  @override
  Future<ChannelAddedApp?> getApp(String appId, String channelCode) async {
    for (final a in apps) {
      if (a.appId == appId && a.channelCode == channelCode) return a;
    }
    return null;
  }

  @override
  Future<void> clearChannel(String channelCode) async {
    apps.removeWhere((a) => a.channelCode == channelCode);
  }

  @override
  Future<List<ChannelAddedApp>> getAllApps() async => List.of(apps);

  @override
  Future<int?> getTotalCount() async => apps.length;
}

/// Replays the Rust host side of the `ScriptApi` contract.
class _ScriptApiFixtureBackend implements ScriptApiBackend {
  final List<String> calls = <String>[];
  final Map<String, String> methodResults = <String, String>{};
  String? importedEntryScript;

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
    final archive = ZipDecoder().decodeBytes(Uint8List.fromList(packZipBytes));
    importedEntryScript =
        utf8.decode(archive.findFile('entry.js')!.content as List<int>);
    calls.add('import:$expectedKey');
    return rust_pack.ScriptPackInfo(
      key: expectedKey ?? 'js_fixture',
      name: 'Parity',
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
    return const rust_pack.ScriptPackInfo(
      key: 'js_fixture',
      name: 'Parity',
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
    final result = methodResults[method];
    if (result == null) {
      throw StateError('fixture has no result for $method');
    }
    return result;
  }

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async => const [];

  @override
  Future<String> storedApps({required String key}) async => '[]';

  @override
  Future<void> releaseDetail({
    required String key,
    required String appId,
  }) async =>
      calls.add('releaseDetail:$key:$appId');
}

const String _parityScript = r'''
const CHANNEL_META = { name: 'Parity 渠道' };
function main(method, params) {
  if (method === 'getConfig') {
    return { version: '2026.1', proxy: 'http://127.0.0.1:7890' };
  }
  if (method === 'sendMessage') {
    return sendMessage('host.config.get', JSON.stringify({ key: 'channel.region' }));
  }
  if (method === 'uiCall') {
    return host.ui.call('showVersionPicker', { title: '选择版本' });
  }
  return null;
}
''';

Future<void> _setFlag({required bool jsChannel}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(jsChannel: jsChannel)),
  );
  await CoreFlags.refresh();
  expect(CoreFlags.jsChannel, jsChannel);
}

/// Builds a Dart-lane runtime over [_parityScript] with deterministic hosts.
JsChannelRuntime _dartLaneRuntime({required _FakeAppDao dao}) {
  final nativeHost = JSNativeHost()
    ..register(
        'ui',
        'showVersionPicker',
        (Map<String, dynamic> payload) async =>
            <String, dynamic>{'env': 'sit'});
  return JsChannelRuntime(
    channelKey: 'js_parity',
    script: _parityScript,
    appDao: dao,
    configGetter: (String key) async => key == 'channel.region' ? 'sit' : null,
    nativeHost: nativeHost,
  );
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
    await ChannelManager.instance.disposeAll();
  });

  test('jschannel_flip_removes_dart_channels', () async {
    final manager = ChannelManager.instance;
    final dao = _FakeAppDao();

    // --- flag off: the Dart channel registers and writes on its own path.
    await _setFlag(jsChannel: false);
    expect(manager.dartScriptChannelsEnabled, isTrue);

    final dartChannel = JsChannel(
      channelKey: 'js_flip',
      script: _parityScript,
      appDao: dao,
    );
    manager.registerChannel(dartChannel);
    expect(manager.getChannelByKey('js_flip'), isNotNull);

    final probedDomains = <String>[];
    LegacyWriteGuard.probeOverride = (String domain) async {
      probedDomains.add(domain);
      return false;
    };
    final offWrite =
        await manager.getChannelByKey('js_flip')!.addApp(const AppSummary(
              appId: 'app.off',
              name: 'Off',
              user: 'u',
              repositories: 'r',
              icon: 'i',
              des: 'd',
            ));
    expect(offWrite.success, isTrue);
    expect(probedDomains, isNotEmpty);
    expect(dao.apps.map((a) => a.appId), contains('app.off'));
    await manager.disposeAll();

    // --- flip on: registration path is gone, and the residual Dart writer is
    // owned by the `js_channel` marker, not the `channel` marker.
    await _setFlag(jsChannel: true);
    expect(manager.dartScriptChannelsEnabled, isFalse,
        reason: 'the flip must retire Dart script channels');

    final dir = await Directory.systemTemp.createTemp('gstore_jschannel_flip');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/flip.zip')
        .writeAsBytes(_zipOf('function main(){ return null; }'));

    final loaded = await ChannelLoader(directory: dir).loadAndRegister();
    expect(loaded, isEmpty,
        reason: 'ChannelLoader must not build Dart JsChannels when flipped');
    expect(manager.getChannelByKey('js_flip'), isNull);
    expect(manager.dynamicChannels, isEmpty);

    final rejected = JsChannel(
      channelKey: 'js_rejected',
      script: _parityScript,
      appDao: dao,
    );
    manager.registerChannel(rejected);
    expect(manager.getChannelByKey('js_rejected'), isNull);
    expect(manager.getChannel(ChannelType.custom), isNull);

    // Residual Dart writer: after the flip the owning marker is `js_channel`.
    LegacyWriteGuard.probeOverride =
        (String domain) async => domain == 'js_channel';
    final onWrite = await rejected.addApp(const AppSummary(
      appId: 'app.on',
      name: 'On',
      user: 'u',
      repositories: 'r',
      icon: 'i',
      des: 'd',
    ));
    expect(onWrite.success, isFalse,
        reason: 'the Dart JS writer must be blocked by the js_channel marker');
    expect(onWrite.error, contains('LegacyWriteBlocked'));
    expect(dao.apps.where((a) => a.appId == 'app.on'), isEmpty);
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

  test('jschannel_rust_lane_parity_from_dart', () async {
    await _setFlag(jsChannel: true);

    // 1) The real asset bytes go through the real ScriptApi facade.
    final example = await rootBundle.loadString('assets/channels/example.js');
    final backend = _ScriptApiFixtureBackend();
    ScriptApi.installBackend(backend);
    final info = await ScriptApi.instance.import_(
      packZipBytes: _zipOf(example),
      expectedKey: 'js_example',
    );
    expect(info.key, 'js_example');
    expect(backend.importedEntryScript, example,
        reason:
            'the fetched asset must be the pack entry.js the Rust lane gets');
    expect(backend.calls, contains('import:js_example'));

    // 2) Dart lane: the same host contract executed on the real engine.
    final dao = _FakeAppDao();
    final runtime = _dartLaneRuntime(dao: dao);
    await runtime.initialize();
    addTearDown(runtime.dispose);

    final dartConfig =
        await runtime.call('main', <dynamic>['getConfig', <String, dynamic>{}]);
    final dartSendMessage = await runtime
        .call('main', <dynamic>['sendMessage', <String, dynamic>{}]);
    final dartUiCall =
        await runtime.call('main', <dynamic>['uiCall', <String, dynamic>{}]);

    expect(dartConfig, <String, Object?>{
      'version': '2026.1',
      'proxy': 'http://127.0.0.1:7890',
    });
    expect(dartSendMessage, <String, Object?>{
      'ok': true,
      'data': 'sit',
    });
    expect(dartUiCall, <String, Object?>{
      'ok': true,
      'data': <String, Object?>{'env': 'sit'},
    });

    // 3) Rust lane replay of the same script results through ScriptApi.
    backend.methodResults
      ..['getConfig'] = jsonEncode(dartConfig)
      ..['sendMessage'] = jsonEncode(dartSendMessage)
      ..['uiCall'] = jsonEncode(dartUiCall);

    final rustConfig = await ScriptApi.instance.getConfig(key: 'js_example');
    expect(rustConfig, <String, Object?>{
      'version': '2026.1',
      'proxy': 'http://127.0.0.1:7890',
    });
    expect(
      <String, Object?>{
        'version': rustConfig!['version'],
        'proxy': rustConfig['proxy'],
      },
      <String, Object?>{
        'version': (dartConfig as Map)['version'],
        'proxy': dartConfig['proxy'],
      },
      reason: 'getConfig must map to the same {version, proxy} shape',
    );

    for (final method in <String>['sendMessage', 'uiCall']) {
      final raw = await ScriptApi.instance.run(
        key: 'js_example',
        method: method,
        paramsJson: '{}',
      );
      expect(jsonDecode(raw),
          method == 'sendMessage' ? dartSendMessage : dartUiCall,
          reason: '$method must roundtrip the Dart-lane value unchanged');
    }

    expect(
        backend.calls,
        containsAll(<String>[
          'run:js_example:getConfig',
          'run:js_example:sendMessage',
          'run:js_example:uiCall',
        ]));
  });
}

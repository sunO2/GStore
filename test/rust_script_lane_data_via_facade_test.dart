/// Todo 3 — Dart JS lane ↔ `RustChannelFacade` surface.
///
/// Covers both Todo 3 deliverables:
///
/// * **Deliverable 1** — the four JS detail-page methods
///   (`scriptVersionOptions` / `scriptSwitchVersion` / `scriptBuildHistory` /
///   `scriptDetailMenu`) are exposed on `ChannelApiBackend`,
///   `FrbChannelApiBackend`, and `RustChannelFacade`, forwarding to the
///   generated `rust.ChannelApi` with the exact generated signatures.
/// * **Deliverable 2** — `RustScriptChannelLane.searchApps` reads through
///   `RustChannelFacade.search` (the unified `ChannelApi` path), mapping
///   `rust.ChannelAppInfo` → `AppSummary`; a pack that does not implement
///   `searchApps` (empty result, or the driver raises) falls back to
///   `RustChannelFacade.getAllApps` + a local name/des/appId filter.
/// * The lane's **script-domain store** (`storedApps` / `addApp`) keeps going
///   through `ScriptApi`, never the channels-domain facade.
///
/// `ChannelApi.search` resolves an imported-but-unregistered `js_*` pack only
/// because `ChannelApiInner::driver()` now falls back to `script_driver()`
/// (host change + `channel_api_driver_resolves_unregistered_script_pack`
/// regression test); the real-pack native probe is captured in
/// `target/test-evidence/js-unify/03-lane.txt`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_api.dart';

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

/// Records the four detail-page calls the facade forwards, and returns the
/// value the test seeded — so the assertion proves the facade reached the
/// backend, not that a fake invented a result.
class _FakeChannelApiBackend implements ChannelApiBackend {
  final List<String> calls = [];

  rust.ScriptVersionOptions? versionOptionsResult;
  rust.ChannelAppDetailInfo? switchVersionResult;
  List<rust.ScriptBuild> buildHistoryResult = const [];
  List<rust.ChannelDetailAction> detailMenuResult = const [];

  /// The unified search path (Todo 3): `searchApps` reads through
  /// `RustChannelFacade.search`; an empty/raising search falls back to
  /// `getAllApps` (= backend `listApps`).
  final Map<String, List<rust.ChannelAppInfo>> searchResults = {};
  final Map<String, List<rust.ChannelAppInfo>> listAppsResults = {};
  final List<String> searchCalls = [];
  final List<String> listAppsCalls = [];

  /// When non-null, `search` throws it (models an unimplemented driver).
  Object? searchError;

  /// Any other channels-domain data method (`addApp`/...) must NOT be reached by
  /// the lane's script-domain store path.
  final List<String> forbiddenCalls = [];

  @override
  Future<List<rust.ChannelAppInfo>> search({
    required String key,
    required String keyword,
    required bool forceRefresh,
  }) async {
    searchCalls.add('$key:$keyword');
    final error = searchError;
    if (error != null) throw error;
    return searchResults[key] ?? const [];
  }

  @override
  Future<List<rust.ChannelAppInfo>> listApps({
    required String key,
    required bool forceRefresh,
  }) async {
    listAppsCalls.add(key);
    return listAppsResults[key] ?? const [];
  }

  @override
  Future<rust.ScriptVersionOptions?> scriptVersionOptions({
    required String key,
    required String appId,
    String? env,
    String? currentVersion,
  }) async {
    calls.add('scriptVersionOptions:$key:$appId:$env:$currentVersion');
    return versionOptionsResult;
  }

  @override
  Future<rust.ChannelAppDetailInfo?> scriptSwitchVersion({
    required String key,
    required String appId,
    required String env,
    required String version,
    String? buildJson,
  }) async {
    calls.add('scriptSwitchVersion:$key:$appId:$env:$version:$buildJson');
    return switchVersionResult;
  }

  @override
  Future<List<rust.ScriptBuild>> scriptBuildHistory({
    required String key,
    required String appId,
    required String env,
    required String version,
  }) async {
    calls.add('scriptBuildHistory:$key:$appId:$env:$version');
    return buildHistoryResult;
  }

  @override
  Future<List<rust.ChannelDetailAction>> scriptDetailMenu({
    required String key,
    required String appId,
  }) async {
    calls.add('scriptDetailMenu:$key:$appId');
    return detailMenuResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    forbiddenCalls.add(invocation.memberName.toString());
    throw UnimplementedError('unexpected facade call: ${invocation.memberName}');
  }
}

/// Records the script-domain store calls (`storedApps`/`addApp`) so the test can
/// prove the lane used `ScriptApi`, not the channels-domain facade.
class _FakeScriptBackend implements ScriptApiBackend {
  final List<String> storedAppsKeys = [];
  final List<String> addAppKeys = [];
  rust.ChannelAppInfo? lastAddedApp;
  String storedAppsJson = '[]';

  @override
  Future<String> storedApps({required String key}) async {
    storedAppsKeys.add(key);
    return storedAppsJson;
  }

  @override
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {
    addAppKeys.add(key);
    lastAddedApp = app;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused ScriptApi method: ${invocation.memberName}');
}

/// One `rust.ChannelAppInfo` as `ChannelApi.search`/`getAllApps` would emit it.
rust.ChannelAppInfo _channelAppInfo(
  String appId,
  String name, {
  String? packageName,
  String des = 'desc',
  String? extraJson,
}) =>
    rust.ChannelAppInfo(
      appId: appId,
      packageName: packageName,
      name: name,
      user: '',
      repositories: '',
      icon: '',
      des: des,
      category: const <String>[],
      extraJson: extraJson,
      labels: const <rust.ChannelLabel>[],
    );

Future<void> _setFlag({required bool jsChannel}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(jsChannel: jsChannel)),
  );
  await CoreFlags.refresh();
  expect(CoreFlags.jsChannel, jsChannel);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    CoreFlags.resetBackend();
    ScriptApi.resetBackend();
    RustChannelFacade.resetBackend();
    RustScriptChannelLane.resetForTest();
  });

  // ---------------------------------------------------------------------------
  // Deliverable 1 — the four JS detail-page methods on the facade
  // ---------------------------------------------------------------------------

  group('RustChannelFacade exposes the four JS detail-page methods', () {
    test('forwards scriptVersionOptions with the generated optional args',
        () async {
      final backend = _FakeChannelApiBackend()
        ..versionOptionsResult = const rust.ScriptVersionOptions(
          title: 'pick a version',
          envs: ['sit'],
          versions: [],
          extraJson: '{}',
        );
      RustChannelFacade.installBackend(backend);

      final result = await RustChannelFacade.instance.scriptVersionOptions(
        key: 'js_vivo',
        appId: 'com.vivo',
        env: 'sit',
        currentVersion: '1.0.0',
      );

      expect(backend.calls,
          ['scriptVersionOptions:js_vivo:com.vivo:sit:1.0.0']);
      expect(result?.title, 'pick a version');
    });

    test('forwards scriptSwitchVersion (buildJson optional)', () async {
      final backend = _FakeChannelApiBackend()
        ..switchVersionResult = const rust.ChannelAppDetailInfo(
          appId: 'com.vivo',
          name: 'Vivo',
          icon: '',
          description: '',
          channel: 'js_local',
          sections: [],
          downloads: [],
          extraJson: '{}',
          labels: [],
        );
      RustChannelFacade.installBackend(backend);

      final result = await RustChannelFacade.instance.scriptSwitchVersion(
        key: 'js_vivo',
        appId: 'com.vivo',
        env: 'sit',
        version: '1.2.0',
        buildJson: '{"num":3}',
      );

      expect(backend.calls,
          ['scriptSwitchVersion:js_vivo:com.vivo:sit:1.2.0:{"num":3}']);
      expect(result?.appId, 'com.vivo');
    });

    test('forwards scriptBuildHistory', () async {
      final backend = _FakeChannelApiBackend()
        ..buildHistoryResult = const [
          rust.ScriptBuild(num: 3, extraJson: '{}'),
        ];
      RustChannelFacade.installBackend(backend);

      final result = await RustChannelFacade.instance.scriptBuildHistory(
        key: 'js_vivo',
        appId: 'com.vivo',
        env: 'sit',
        version: '1.2.0',
      );

      expect(backend.calls,
          ['scriptBuildHistory:js_vivo:com.vivo:sit:1.2.0']);
      expect(result.single.num, 3);
    });

    test('forwards scriptDetailMenu', () async {
      final backend = _FakeChannelApiBackend()
        ..detailMenuResult = const [
          rust.ChannelDetailAction(action: 'refresh', jscall: 'refresh'),
        ];
      RustChannelFacade.installBackend(backend);

      final result = await RustChannelFacade.instance
          .scriptDetailMenu(key: 'js_vivo', appId: 'com.vivo');

      expect(backend.calls, ['scriptDetailMenu:js_vivo:com.vivo']);
      expect(result.single.action, 'refresh');
    });

    test('the fake backend never saw a channels-domain data call', () {
      final backend = _FakeChannelApiBackend();
      RustChannelFacade.installBackend(backend);
      expect(backend.forbiddenCalls, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Deliverable 2 — searchApps reads through the channels facade
  // ---------------------------------------------------------------------------

  group('lane searchApps reads through the channels facade', () {
    test('calls backend.search and maps ChannelAppInfo -> AppSummary',
        () async {
      await _setFlag(jsChannel: true);
      final facade = _FakeChannelApiBackend()
        ..searchResults['js_probe'] = [
          _channelAppInfo(
            'com.probe',
            'Probe App',
            packageName: 'com.probe.pkg',
            des: 'a probe app',
            extraJson: '{"k":"v"}',
          ),
        ];
      RustChannelFacade.installBackend(facade);
      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);

      final apps = await lane.searchApps('js_probe', 'probe');

      expect(facade.searchCalls, ['js_probe:probe'],
          reason: 'the lane search must call ChannelApi.search (backend)');
      expect(facade.listAppsCalls, isEmpty,
          reason: 'a non-empty search must not fall back to getAllApps');
      expect(apps, hasLength(1));
      expect(apps.single.appId, 'com.probe');
      expect(apps.single.packageName, 'com.probe.pkg');
      expect(apps.single.name, 'Probe App');
      expect(apps.single.des, 'a probe app');
      expect(apps.single.extra, {'k': 'v'});
    });

    test('falls back to getAllApps + local filter when search yields nothing',
        () async {
      await _setFlag(jsChannel: true);
      final facade = _FakeChannelApiBackend()
        ..searchResults['js_probe'] = const []
        ..listAppsResults['js_probe'] = [
          _channelAppInfo('com.probe', 'Probe App'),
          _channelAppInfo('com.other', 'Other'),
        ];
      RustChannelFacade.installBackend(facade);
      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);

      final apps = await lane.searchApps('js_probe', 'probe');

      expect(facade.searchCalls, ['js_probe:probe']);
      expect(facade.listAppsCalls, ['js_probe'],
          reason: 'an empty search must fall back to getAllApps');
      expect(apps.map((a) => a.appId), ['com.probe'],
          reason: 'the fallback must filter locally by name/des/appId');
    });

    test('falls back when search throws (unimplemented searchApps)', () async {
      await _setFlag(jsChannel: true);
      final facade = _FakeChannelApiBackend()
        ..searchError = Exception('unsupported: searchApps')
        ..listAppsResults['js_probe'] = [
          _channelAppInfo('com.probe', 'Probe App')
        ];
      RustChannelFacade.installBackend(facade);
      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);

      final apps = await lane.searchApps('js_probe', 'probe');

      expect(facade.searchCalls, ['js_probe:probe']);
      expect(facade.listAppsCalls, ['js_probe']);
      expect(apps.map((a) => a.appId), ['com.probe']);
    });

    test('empty keyword does not throw (UI guards empty input)', () async {
      await _setFlag(jsChannel: true);
      final facade = _FakeChannelApiBackend()
        ..searchResults['js_probe'] = const [];
      RustChannelFacade.installBackend(facade);
      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);

      expect(await lane.searchApps('js_probe', ''), isEmpty);
    });

    test('flag off: searchApps is empty and never touches the facade',
        () async {
      await _setFlag(jsChannel: false);
      final facade = _FakeChannelApiBackend()
        ..searchResults['js_probe'] = [
          _channelAppInfo('com.probe', 'Probe App')
        ];
      RustChannelFacade.installBackend(facade);
      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);

      expect(await lane.searchApps('js_probe', 'probe'), isEmpty);
      expect(facade.searchCalls, isEmpty);
      expect(facade.listAppsCalls, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // The script-domain store stays on ScriptApi (NOT the channels facade)
  // ---------------------------------------------------------------------------

  group('lane script-domain store stays on ScriptApi', () {
    test('storedApps reads through ScriptApi, never the facade', () async {
      await _setFlag(jsChannel: true);
      final scriptBackend = _FakeScriptBackend()
        ..storedAppsJson =
            '[{"app_id":"com.probe","name":"Probe","user":"","repositories":"",'
                '"icon":"","des":"d","readme":null,"category":null,"extra":null}]';
      ScriptApi.installBackend(scriptBackend);
      final facadeBackend = _FakeChannelApiBackend();
      RustChannelFacade.installBackend(facadeBackend);

      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);

      final apps = await lane.storedApps('js_probe');

      expect(apps.map((a) => a.appId), ['com.probe']);
      expect(scriptBackend.storedAppsKeys, ['js_probe'],
          reason: 'storedApps must read the script-domain rows via ScriptApi');
      expect(facadeBackend.forbiddenCalls, isEmpty,
          reason: 'the channels-domain facade must not serve the script store');
    });

    test('addApp writes through ScriptApi with a faithfully-mapped ChannelAppInfo',
        () async {
      await _setFlag(jsChannel: true);
      final scriptBackend = _FakeScriptBackend();
      ScriptApi.installBackend(scriptBackend);
      final facadeBackend = _FakeChannelApiBackend();
      RustChannelFacade.installBackend(facadeBackend);

      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);

      await lane.addApp(
        'js_probe',
        const AppSummary(
          appId: 'com.probe',
          packageName: 'com.probe.pkg',
          name: 'Probe',
          user: 'alice',
          repositories: 'repo',
          icon: 'https://example.com/i.png',
          des: 'a probe app',
          readme: 'readme',
          category: ['Tools'],
          extra: {'k': 'v'},
        ),
      );

      expect(scriptBackend.addAppKeys, ['js_probe'],
          reason: 'addApp must write the script-domain rows via ScriptApi');
      final mapped = scriptBackend.lastAddedApp!;
      expect(mapped.appId, 'com.probe');
      expect(mapped.packageName, 'com.probe.pkg');
      expect(mapped.name, 'Probe');
      expect(mapped.user, 'alice');
      expect(mapped.repositories, 'repo');
      expect(mapped.category, ['Tools']);
      expect(mapped.extraJson, '{"k":"v"}');
      expect(facadeBackend.forbiddenCalls, isEmpty,
          reason: 'addApp must NOT be routed through the channels facade');
    });

    test('flag off: the script store is never touched', () async {
      await _setFlag(jsChannel: false);
      final scriptBackend = _FakeScriptBackend();
      ScriptApi.installBackend(scriptBackend);
      final facadeBackend = _FakeChannelApiBackend();
      RustChannelFacade.installBackend(facadeBackend);

      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);

      expect(await lane.storedApps('js_probe'), isEmpty);
      expect(scriptBackend.storedAppsKeys, isEmpty);
      expect(facadeBackend.forbiddenCalls, isEmpty);
    });
  });
}

/// Persistence + searchability of the Rust script-channel lane.
///
/// Two defects shipped in the `CoreFlags.jsChannel == true` lane:
///
/// * DEFECT A — `RustScriptChannelLane.refresh()` read `ScriptApi.list()` without
///   initialising the Rust `ScriptApi` first. Import-time worked (the service
///   initialised before `import`), but at STARTUP nothing had, so `list()` threw,
///   the error was swallowed into an empty cache, and the channel vanished —
///   "重启之后也没有了".
/// * DEFECT B — discovery's `_searchInChannel` filtered the saved `channel_apps`
///   rows for a lane pack instead of running the pack's search entry point. A
///   freshly imported pack has no saved rows yet, so the search returned nothing
///   — "搜索渠道没有显示".
///
/// The `ScriptApiBackend` here is the same FRB seam the production lane uses, and
/// it is **init-gated** like the real `FrbScriptApiBackend` (its `_instance`
/// getter throws `StateError('ScriptApi.init() must be awaited before use')`),
/// so a refresh that forgets to initialise fails exactly as it does on device.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_channel_service.dart';
import 'package:gstore/page/home/tab/discovery/logic.dart';

/// Init-gated in-memory `ScriptApiBackend` (the FRB seam).
///
/// Every method except `init` throws [StateError] until `init` has run, mirroring
/// `FrbScriptApiBackend`'s `_instance` getter. This is what makes a
/// "forgot to initialise" refresh fail in the test exactly as it does on device.
class _InitGatedScriptBackend implements ScriptApiBackend {
  bool initialized = false;
  int initCount = 0;

  final Map<String, rust_pack.ScriptPackInfo> packs = {};
  final Map<String, List<Map<String, Object?>>> stored = {};

  /// `"<key>:<method>"` → the raw JSON string `ScriptApi.run` would return.
  final Map<String, String> runResults = {};

  void _requireInit() {
    if (!initialized) {
      throw StateError('ScriptApi.init() must be awaited before use');
    }
  }

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {
    initCount++;
    initialized = true;
  }

  @override
  Future<rust_pack.ScriptPackInfo> import_({
    required List<int> packZipBytes,
    String? expectedKey,
  }) async {
    _requireInit();
    final key = expectedKey ?? 'js_unknown';
    final info = _pack(key);
    packs[key] = info;
    return info;
  }

  @override
  Future<void> remove({required String key}) async {
    _requireInit();
    packs.remove(key);
    stored.remove(key);
  }

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async {
    _requireInit();
    return packs[key] ?? _pack(key);
  }

  @override
  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  }) async =>
      _requireInit();

  @override
  Future<void> setConfig({
    required String key,
    required Map<String, String> config,
  }) async =>
      _requireInit();

  @override
  Future<String> run({
    required String key,
    required String method,
    required String paramsJson,
  }) async {
    _requireInit();
    return runResults['$key:$method'] ?? 'null';
  }

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async {
    _requireInit();
    final values = packs.values.toList()..sort((a, b) => a.key.compareTo(b.key));
    return values;
  }

  @override
  Future<String> storedApps({required String key}) async {
    _requireInit();
    return jsonEncode(stored[key] ?? const <Object?>[]);
  }

  @override
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {}

  @override
  Future<void> releaseDetail({
    required String key,
    required String appId,
  }) async =>
      _requireInit();
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

Future<void> _setFlag({required bool jsChannel}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(jsChannel: jsChannel)),
  );
  await CoreFlags.refresh();
  expect(CoreFlags.jsChannel, jsChannel);
}

void _installScriptService(ScriptApiBackend backend) {
  ScriptApi.installBackend(backend);
  ScriptChannelService.installForTest(ScriptChannelService(
    coreDirs: () async => (
      '/tmp/gstore_lane_persist/data',
      '/tmp/gstore_lane_persist/files',
      '/tmp/gstore_lane_persist/cache',
    ),
    ensureRust: () async {},
  ));
}

rust_pack.ScriptPackInfo _pack(String key, {String name = 'Probe Pack'}) =>
    rust_pack.ScriptPackInfo(
      key: key,
      name: name,
      description: '',
      icon: '',
      hasDetail: false,
    );

/// One script-side AppInfo row as a pack's `searchApps`/`getAllApps` returns it.
Map<String, Object?> _appInfo(String appId, String name) => {
      'appId': appId,
      'name': name,
      'des': 'desc',
      'icon': '',
    };

Uint8List _zipOf(String entry) {
  final archive = Archive()..addFile(ArchiveFile.string('entry.js', entry));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ChannelManager.instance.disposeAll();
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    ScriptApi.resetBackend();
    ScriptChannelService.resetForTest();
    RustScriptChannelLane.resetForTest();
    await ChannelManager.instance.disposeAll();
    ModuleManager.instance.unbind<ChannelManager>();
  });

  // ---------------------------------------------------------------------------
  // DEFECT A — the lane must be readable at startup
  // ---------------------------------------------------------------------------

  test(
      'a fresh lane refresh() lists a pack already in the core DB (survives restart)',
      () async {
    await _setFlag(jsChannel: true);
    final backend = _InitGatedScriptBackend();
    _installScriptService(backend);
    // The pack was imported in a previous run: it is in the core DB, but nothing
    // has initialised the ScriptApi in THIS process (simulated app start).
    backend.packs['js_probe'] = _pack('js_probe');
    expect(backend.initialized, isFalse,
        reason: 'start state: the ScriptApi has never been initialised');

    final lane = RustScriptChannelLane();
    RustScriptChannelLane.installForTest(lane);
    await lane.refresh();

    expect(backend.initialized, isTrue,
        reason: 'refresh() must initialise the lane before reading list()');
    expect(lane.codes, contains('js_probe'),
        reason: 'a pack in the core DB must survive an app restart');
  });

  test('refresh() is best-effort: a failed init is never thrown to the caller',
      () async {
    await _setFlag(jsChannel: true);
    ScriptApi.installBackend(_InitGatedScriptBackend());
    // A service whose Rust bootstrap always fails: refresh() must swallow the
    // failure (startup load / discovery reload must not crash) rather than throw.
    ScriptChannelService.installForTest(ScriptChannelService(
      coreDirs: () async => ('/d', '/f', '/c'),
      ensureRust: () async => throw StateError('rust bridge unavailable'),
    ));
    final lane = RustScriptChannelLane();
    RustScriptChannelLane.installForTest(lane);

    // Must complete without throwing.
    await lane.refresh();
  });

  test('a failed read is recorded as unavailable, not a silent empty lane',
      () async {
    await _setFlag(jsChannel: true);
    ScriptApi.installBackend(_InitGatedScriptBackend());
    ScriptChannelService.installForTest(ScriptChannelService(
      coreDirs: () async => ('/d', '/f', '/c'),
      ensureRust: () async => throw StateError('rust bridge unavailable'),
    ));
    final lane = RustScriptChannelLane();
    RustScriptChannelLane.installForTest(lane);

    await lane.refresh();

    expect(lane.packs, isEmpty);
    expect(lane.hasLoadError, isTrue,
        reason: 'an unreadable lane must be distinguishable from an empty one');
    expect(lane.loadError, contains('rust bridge unavailable'));
  });

  test('a successful refresh clears a previous load error', () async {
    await _setFlag(jsChannel: true);
    final backend = _InitGatedScriptBackend();
    _installScriptService(backend);
    final lane = RustScriptChannelLane();
    RustScriptChannelLane.installForTest(lane);

    // First read: init is forced to fail => recorded as unavailable.
    var failNext = true;
    ScriptChannelService.installForTest(ScriptChannelService(
      coreDirs: () async => ('/d', '/f', '/c'),
      ensureRust: () async {
        if (failNext) throw StateError('first read fails');
      },
    ));
    await lane.refresh();
    expect(lane.hasLoadError, isTrue);

    // Second read: init succeeds and a pack is present => error cleared.
    failNext = false;
    backend.packs['js_probe'] = _pack('js_probe');
    await lane.refresh();
    expect(lane.hasLoadError, isFalse);
    expect(lane.codes, contains('js_probe'));
  });

  // ---------------------------------------------------------------------------
  // Lane search contract (unit level)
  // ---------------------------------------------------------------------------

  test('searchApps maps the script result and never reads the saved rows',
      () async {
    await _setFlag(jsChannel: true);
    final backend = _InitGatedScriptBackend();
    _installScriptService(backend);
    backend.packs['js_probe'] = _pack('js_probe');
    backend.runResults['js_probe:searchApps'] =
        jsonEncode([_appInfo('com.probe', 'Probe App')]);
    // A saved row that must NOT leak into the search result.
    backend.stored['js_probe'] = [
      {
        'app_id': 'com.stale',
        'package_name': 'com.stale',
        'name': 'Stale Row',
        'user': '',
        'repositories': '',
        'icon': '',
        'des': 'desc',
        'readme': null,
        'category': null,
        'extra': null,
      }
    ];

    final lane = RustScriptChannelLane();
    RustScriptChannelLane.installForTest(lane);
    await ScriptChannelService.instance.ensureInitialized();
    await lane.refresh();

    final apps = await lane.searchApps('js_probe', 'probe');
    expect(apps.map((a) => a.appId), ['com.probe']);
  });

  test('flag off: searchApps returns empty without touching the Rust store',
      () async {
    await _setFlag(jsChannel: false);
    final backend = _InitGatedScriptBackend();
    _installScriptService(backend);
    backend.runResults['js_probe:searchApps'] =
        jsonEncode([_appInfo('com.probe', 'Probe App')]);

    final lane = RustScriptChannelLane();
    RustScriptChannelLane.installForTest(lane);
    expect(await lane.searchApps('js_probe', 'probe'), isEmpty);
    expect(backend.initCount, 0);
  });

  // ---------------------------------------------------------------------------
  // DEFECT B — the lane search must run the pack's search entry point
  // ---------------------------------------------------------------------------

  group('Rust-lane discovery search', () {
    setUp(() {
      ModuleManager.instance.bind<ChannelManager>(ChannelManager.instance);
    });

    tearDown(() {
      ModuleManager.instance.unbind<ChannelManager>();
    });

    (ProviderContainer, DiscoveryNotifier) makeContainer() {
      final notifier = DiscoveryNotifier();
      final container = ProviderContainer(overrides: [
        discoveryProvider.overrideWith(() => notifier),
      ]);
      container.read(discoveryProvider);
      return (container, notifier);
    }

    test(
        'a fresh pack with no saved rows is searchable through the script entry',
        () async {
      await _setFlag(jsChannel: true);
      final backend = _InitGatedScriptBackend();
      _installScriptService(backend);
      backend.packs['js_probe'] = _pack('js_probe');
      // The script's searchApps returns one app. There are NO saved channel_apps
      // rows (a freshly imported pack), so filtering stored rows yields nothing.
      backend.runResults['js_probe:searchApps'] =
          jsonEncode([_appInfo('com.probe', 'Probe App')]);

      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);
      await ScriptChannelService.instance.ensureInitialized();
      await lane.refresh();
      expect(lane.packFor('js_probe'), isNotNull,
          reason: 'precondition: the lane must hold the pack before searching');
      expect(backend.stored['js_probe'], isNull,
          reason: 'precondition: no saved rows for a fresh pack');

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);
      notifier.searchController.text = 'probe';
      await notifier.performSearch();

      expect(
          notifier.state.channelApps['js_probe']?.map((a) => a.appId),
          contains('com.probe'),
          reason: 'the Rust-lane search must run the script entry, '
              'not filter the (empty) saved rows');
    });

    test('searchApps fallback runs getAllApps when searchApps is unimplemented',
        () async {
      await _setFlag(jsChannel: true);
      final backend = _InitGatedScriptBackend();
      _installScriptService(backend);
      backend.packs['js_probe'] = _pack('js_probe');
      // searchApps returns null (unimplemented) => fall back to getAllApps.
      backend.runResults['js_probe:searchApps'] = 'null';
      backend.runResults['js_probe:getAllApps'] =
          jsonEncode([_appInfo('com.probe', 'Probe App')]);

      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);
      await ScriptChannelService.instance.ensureInitialized();
      await lane.refresh();

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);
      notifier.searchController.text = 'probe';
      await notifier.performSearch();

      expect(
          notifier.state.channelApps['js_probe']?.map((a) => a.appId),
          contains('com.probe'),
          reason: 'an unimplemented searchApps must fall back to running getAllApps');
    });
  });

  // ---------------------------------------------------------------------------
  // Regression — import / delete / flag-off
  // ---------------------------------------------------------------------------

  test('import adds the pack to the lane, delete removes it', () async {
    await _setFlag(jsChannel: true);
    final backend = _InitGatedScriptBackend();
    _installScriptService(backend);

    final dir = await Directory.systemTemp.createTemp('gstore_lane_persist_io');
    addTearDown(() => dir.delete(recursive: true));
    final loader = ChannelLoader(directory: dir);
    final bytes = _zipOf('function main(){ return null; }');

    final imported = await loader.importZip(
      channelKey: 'js_probe',
      zipBytes: bytes,
    );
    expect(imported, isA<ScriptLaneChannelImport>());
    expect(RustScriptChannelLane.instance.codes, contains('js_probe'));

    await loader.removeChannel('js_probe');
    expect(RustScriptChannelLane.instance.codes, isNot(contains('js_probe')),
        reason: 'delete must drop the pack from the lane cache');
  });

  test('flag off: the lane stays empty and never touches the Rust store',
      () async {
    await _setFlag(jsChannel: false);
    final backend = _InitGatedScriptBackend();
    _installScriptService(backend);
    backend.packs['js_probe'] = _pack('js_probe');

    final lane = RustScriptChannelLane();
    RustScriptChannelLane.installForTest(lane);
    await lane.refresh();

    expect(lane.codes, isEmpty);
    expect(lane.enabled, isFalse);
    expect(backend.initCount, 0,
        reason: 'flag off must not initialise or read the Rust pack store');
  });
}

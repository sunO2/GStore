/// Todo 7 / G-B3 (Final F1): surface the Rust-lane script channels in the UI.
///
/// With `CoreFlags.jsChannel` ON (the Rust default) `ChannelLoader` imports packs
/// into the Rust lane and registers no Dart dynamic channel, so every
/// user-facing surface used to read the now-empty Dart registry:
///
/// * discovery built its channel codes from `dynamicChannels` only;
/// * settings "已导入渠道" listed `dynamicChannels.whereType<JsChannel>()`;
/// * the detail page returned silently (`getChannelByCode == null`) and rendered
///   `SizedBox.shrink()` — a silent blank page.
///
/// These tests drive the **production** import path (`ChannelLoader.importZip`,
/// the same call the settings import dialog makes) with the flag on and assert
/// each surface reads the Rust lane. The `ScriptApiBackend` is a seam (no FRB
/// dylib inside `flutter test`); the real Rust engine path is proven by
/// `test/script_channel_production_test.dart` (native group) and the Rust suite.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_channel_service.dart';
import 'package:gstore/page/detail/logic.dart';
import 'package:gstore/page/detail/state.dart';
import 'package:gstore/page/home/tab/discovery/logic.dart';
import 'package:gstore/page/settings/settings_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory `ScriptApiBackend` (the FRB seam). Records the calls the UI makes
/// and serves `list`/`storedApps`/`run` from its own maps, so the assertions
/// prove the UI reached the Rust lane, never that a fake invented a result.
class _FakeScriptBackend implements ScriptApiBackend {
  final Map<String, rust_pack.ScriptPackInfo> packs = {};
  final Map<String, List<Map<String, Object?>>> stored = {};
  final Map<String, Map<String, Object?>> detail = {};
  final List<String> removed = [];
  final List<String> initCalls = [];
  final List<String> envSets = [];
  final Map<String, Map<String, String>> lastEnv = {};

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {
    initCalls.add('init');
  }

  @override
  Future<rust_pack.ScriptPackInfo> import_({
    required List<int> packZipBytes,
    String? expectedKey,
  }) async {
    final key = expectedKey ?? 'js_unknown';
    final info = rust_pack.ScriptPackInfo(
      key: key,
      name: 'Probe Pack',
      description: 'seam',
      icon: '',
      hasDetail: false,
    );
    packs[key] = info;
    return info;
  }

  @override
  Future<void> remove({required String key}) async {
    removed.add(key);
    packs.remove(key);
    stored.remove(key);
  }

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async {
    final existing = packs[key];
    if (existing != null) return existing;
    return rust_pack.ScriptPackInfo(
      key: key,
      name: 'Probe Pack',
      description: '',
      icon: '',
      hasDetail: false,
    );
  }

  @override
  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  }) async {
    envSets.add(key);
    lastEnv[key] = Map.of(env);
  }

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
    if (method == 'getAppDetail') {
      final payload = detail[key];
      if (payload == null) return 'null';
      return jsonEncode(payload);
    }
    if (method == 'searchApps' || method == 'getAllApps') {
      return jsonEncode(stored[key] ?? const <Object?>[]);
    }
    return 'null';
  }

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async {
    final values = packs.values.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return values;
  }

  @override
  Future<String> storedApps({required String key}) async =>
      jsonEncode(stored[key] ?? const <Object?>[]);

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

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

Future<void> _setFlag({required bool jsChannel}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(jsChannel: jsChannel)),
  );
  await CoreFlags.refresh();
  expect(CoreFlags.jsChannel, jsChannel);
}

void _installScriptService(_FakeScriptBackend backend) {
  ScriptApi.installBackend(backend);
  ScriptChannelService.installForTest(ScriptChannelService(
    coreDirs: () async => (
      '/tmp/gstore_lane_ui/data',
      '/tmp/gstore_lane_ui/files',
      '/tmp/gstore_lane_ui/cache',
    ),
    ensureRust: () async {},
  ));
}

Uint8List _zipOf(String entry) {
  final archive = Archive()..addFile(ArchiveFile.string('entry.js', entry));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// One stored `channel_apps` row as the Rust `storedApps` JSON emits it.
Map<String, Object?> _storedRow({
  required String appId,
  required String name,
  String? packageName,
}) =>
    {
      'app_id': appId,
      'package_name': packageName ?? appId,
      'name': name,
      'user': '',
      'repositories': '',
      'icon': '',
      'des': 'desc',
      'readme': null,
      'category': null,
      'extra': null,
    };

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
  // Discovery
  // ---------------------------------------------------------------------------

  group('Discovery reads the Rust lane when jsChannel is on', () {
    setUp(() async {
      ModuleManager.instance.bind<ChannelManager>(ChannelManager.instance);
    });

    tearDown(() async {
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

    test('imported pack appears in sortedChannelCodes and resolves by code',
        () async {
      await _setFlag(jsChannel: true);
      final backend = _FakeScriptBackend();
      _installScriptService(backend);

      final dir = await Directory.systemTemp.createTemp('gstore_lane_disco');
      addTearDown(() => dir.delete(recursive: true));

      final imported = await ChannelLoader(directory: dir).importZip(
        channelKey: 'js_probe',
        zipBytes: _zipOf('function main(){ return null; }'),
      );
      expect(imported, isA<ScriptLaneChannelImport>(),
          reason: 'flag on must import through the Rust ScriptApi lane');
      backend.stored['js_probe'] = [
        _storedRow(appId: 'com.probe', name: 'Probe App'),
      ];

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);
      await notifier.loadData();

      expect(notifier.sortedChannelCodes, contains('js_probe'),
          reason: 'a Rust-lane pack must appear in the discovery channel codes');
      expect(notifier.state.channelApps['js_probe']?.map((a) => a.appId),
          contains('com.probe'),
          reason: 'discovery must load the Rust-lane stored apps for js_*');
      // ChannelManager-equivalent lookup: the js_* code resolves to the pack.
      expect(notifier.getChannelName('js_probe'), 'Probe Pack');
    });

    test('reload is idempotent (no duplicate codes)', () async {
      await _setFlag(jsChannel: true);
      final backend = _FakeScriptBackend();
      _installScriptService(backend);

      final dir = await Directory.systemTemp.createTemp('gstore_lane_idem');
      addTearDown(() => dir.delete(recursive: true));
      await ChannelLoader(directory: dir).importZip(
        channelKey: 'js_probe',
        zipBytes: _zipOf('function main(){ return null; }'),
      );
      backend.stored['js_probe'] = [
        _storedRow(appId: 'com.probe', name: 'Probe App'),
      ];

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);
      await notifier.loadData();
      await notifier.loadData();

      final codes = notifier.sortedChannelCodes;
      expect(codes.where((c) => c == 'js_probe').length, 1,
          reason: 'reloading must not duplicate a Rust-lane code');
    });

    test('flag off: Dart JsChannel is registered and drives the codes list',
        () async {
      await _setFlag(jsChannel: false);
      final dir = await Directory.systemTemp.createTemp('gstore_lane_off');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/gate.zip')
          .writeAsBytes(_zipOf('function main(){ return null; }'));

      final loaded = await ChannelLoader(directory: dir).loadAndRegister();
      expect(loaded.map((c) => c.channelKey), <String>['js_gate']);
      expect(loaded.single, isA<JsChannel>());

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);
      await notifier.loadData();

      expect(notifier.sortedChannelCodes, contains('js_gate'));
      expect(notifier.getChannelName('js_gate'), isNotEmpty);
    });

    test('import -> delete -> re-import leaves no ghost entry (stale_state)',
        () async {
      await _setFlag(jsChannel: true);
      final backend = _FakeScriptBackend();
      _installScriptService(backend);

      final dir = await Directory.systemTemp.createTemp('gstore_lane_stale');
      addTearDown(() => dir.delete(recursive: true));
      final loader = ChannelLoader(directory: dir);
      final bytes = _zipOf('function main(){ return null; }');

      await loader.importZip(channelKey: 'js_ghost', zipBytes: bytes);
      expect(RustScriptChannelLane.instance.packFor('js_ghost'), isNotNull,
          reason: 'import must register the pack in the lane cache');

      await loader.removeChannel('js_ghost');
      expect(RustScriptChannelLane.instance.packFor('js_ghost'), isNull,
          reason: 'delete must drop the pack from the lane cache (no ghost)');
      expect(RustScriptChannelLane.instance.codes, isNot(contains('js_ghost')));

      await loader.importZip(channelKey: 'js_ghost', zipBytes: bytes);
      expect(RustScriptChannelLane.instance.codes.where((c) => c == 'js_ghost').length, 1,
          reason: 're-import must yield exactly one entry, not a duplicate');
    });
  });

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  group('Settings 已导入渠道 reads the Rust lane when jsChannel is on', () {
    late Directory tempDir;
    late PathProviderPlatform originalPathProvider;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      ConfigStore.instance.resetForTest();
      await ConfigStore.instance
          .initialize(storages: [MemoryConfigStorage(), MemoryConfigStorage()]);
      tempDir = await Directory.systemTemp.createTemp('settings_rust_lane');
      originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    });

    tearDown(() async {
      PathProviderPlatform.instance = originalPathProvider;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
          home: const SettingsPage(),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('count + list reflect a real Rust-lane import; delete reaches ScriptApi.remove',
        (tester) async {
      final backend = _FakeScriptBackend();
      // The flag write, the pack staging and the import all need the real
      // event loop (CoreFlags serializes on a process-wide queue, and the pack
      // is staged through real file IO); `runAsync` escapes FakeAsync for both.
      await tester.runAsync(() async {
        await _setFlag(jsChannel: true);
        _installScriptService(backend);
        await ChannelLoader().importZip(
          channelKey: 'js_probe',
          zipBytes: _zipOf('function main(){ return null; }'),
        );
      });
      await pumpSettings(tester);

      expect(find.text('1 个渠道包'), findsOneWidget,
          reason: 'the settings count must reflect the Rust-lane pack');

      await tester.ensureVisible(find.text('已导入渠道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已导入渠道'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('script_channel_manage_js_probe')),
          findsOneWidget,
          reason: 'the manage dialog must list the Rust-lane pack');
      expect(find.text('js_probe'), findsOneWidget);

      await tester.tap(find.byKey(const Key('script_channel_delete_js_probe')));
      await tester.pumpAndSettle();
      expect(find.text('删除渠道包'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(backend.removed, contains('js_probe'),
          reason: 'delete must reach ScriptApi.remove for a Rust-lane pack');
    });

    testWidgets('env edit reaches ScriptApi.setEnv', (tester) async {
      final backend = _FakeScriptBackend();
      await tester.runAsync(() async {
        await _setFlag(jsChannel: true);
        _installScriptService(backend);
        await ChannelLoader().importZip(
          channelKey: 'js_probe',
          zipBytes: _zipOf('function main(){ return null; }'),
        );
      });

      await pumpSettings(tester);
      await tester.ensureVisible(find.text('已导入渠道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已导入渠道'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('script_channel_env_edit_js_probe')));
      await tester.pumpAndSettle();

      // Add one env row and save.
      await tester.tap(find.byKey(const Key('script_channel_env_add')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('script_channel_env_key_0')), 'PROBE_TOKEN');
      await tester.enterText(
          find.byKey(const Key('script_channel_env_value_0')), 'secret');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(backend.envSets, contains('js_probe'),
          reason: 'env edit must reach ScriptApi.setEnv for a Rust-lane pack');
      expect(backend.lastEnv['js_probe'], {'PROBE_TOKEN': 'secret'});
    });
  });

  // ---------------------------------------------------------------------------
  // Detail
  // ---------------------------------------------------------------------------

  group('Detail resolves js_* from the Rust lane when jsChannel is on', () {
    setUp(() async {
      ModuleManager.instance.bind<ChannelManager>(ChannelManager.instance);
    });

    tearDown(() async {
      ModuleManager.instance.unbind<ChannelManager>();
    });

    AppDetailRequest requestFor(String code) => AppDetailRequest(
          appId: 'com.probe',
          name: 'Probe App',
          channel: ChannelType.custom,
          channelCode: code,
        );

    test('js_* detail page loads from the Rust lane (not a silent blank)',
        () async {
      await _setFlag(jsChannel: true);
      final backend = _FakeScriptBackend();
      _installScriptService(backend);
      backend.packs['js_probe'] = const rust_pack.ScriptPackInfo(
        key: 'js_probe',
        name: 'Probe Pack',
        description: '',
        icon: '',
        hasDetail: false,
      );
      backend.detail['js_probe'] = {
        'appId': 'com.probe',
        'name': 'Probe App',
        'description': 'loaded from rust',
        'downloads': <Object?>[],
      };

      final state = DetailState();
      final logic = DetailLogic(state: state);
      logic.setRouteExtra(requestFor('js_probe'));
      await logic.start();

      expect(state.detailInfo, isNotNull,
          reason: 'a js_* detail page must load, not render a blank page');
      expect(state.detailInfo!.name, 'Probe App');
      expect(state.errorMessage, isEmpty);
    });

    test('unresolvable js_* code shows a typed error, never a silent blank',
        () async {
      await _setFlag(jsChannel: true);
      final backend = _FakeScriptBackend();
      _installScriptService(backend);

      final state = DetailState();
      final logic = DetailLogic(state: state);
      logic.setRouteExtra(requestFor('js_missing'));
      await logic.start();

      expect(state.detailInfo, isNull);
      expect(state.errorMessage, isNotEmpty,
          reason: 'a missing js_* channel must surface a typed error message');
    });

    test('flag off: the legacy JsChannel route still drives the detail page',
        () async {
      await _setFlag(jsChannel: false);
      final dir = await Directory.systemTemp.createTemp('gstore_detail_off');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/gate.zip')
          .writeAsBytes(_zipOf('function main(){ return null; }'));
      final loaded = await ChannelLoader(directory: dir).loadAndRegister();
      expect(loaded.single.channelKey, 'js_gate');

      final state = DetailState();
      final logic = DetailLogic(state: state);
      logic.setRouteExtra(const AppDetailRequest(
        appId: 'com.gate',
        name: 'Gate',
        channel: ChannelType.custom,
        channelCode: 'js_gate',
      ));
      await logic.start();

      // The legacy route resolves a real JsChannel and installs a detail
      // channel; it must not take the Rust-lane branch.
      expect(logic.detailChannel, isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Backup omission visibility (residual, pinned at the source seam)
  // ---------------------------------------------------------------------------

  group('Backup', () {
    test('backup export consults the Rust lane and marks the omission', () {
      final source =
          File('lib/core/service/backup_service.dart').readAsStringSync();
      expect(source.contains('RustScriptChannelLane'), isTrue,
          reason: 'backup must be aware of the Rust script lane');
      expect(source.contains('js_envs_rust_lane_omitted'), isTrue,
          reason: 'the Rust-lane env omission must be recorded, not silent');
    });
  });
}

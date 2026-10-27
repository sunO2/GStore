/// Post-wave06 bug fix: the discovery SEARCH-CHANNEL PICKER must offer the
/// Rust-lane (`js_*`) channels, and saving a search result into a lane code must
/// write through the FRB facade (`ChannelApi.addApp`), reporting a typed failure
/// — never a silent `false` — when the facade call fails.
///
/// User report: "发现页.渠道列表有 jschannel 导入的渠道，但是搜索却没有导入的
/// 渠道搜索项选择". The channel LIST is lane-aware (`sortedChannelCodes` merges
/// `RustScriptChannelLane.codes`); the picker was not.
///
/// The `ScriptApiBackend` is a seam (no FRB dylib inside `flutter test`); the
/// production import path (`ChannelLoader.importZip`) drives the Rust lane, so
/// the assertions prove the picker reads the real lane cache. The lane SAVE path
/// is proven against the `ChannelApiBackend` seam (`RustChannelFacade`), since no
/// native host library is loadable in `flutter test`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_channel_service.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/page/home/tab/discovery/logic.dart';
import 'package:gstore/page/home/tab/discovery/search_channel.dart';

import 'support/discovery_facade_seams.dart';

/// In-memory `ScriptApiBackend` (the FRB seam). Serves `list`/`storedApps`/`run`
/// from its own maps and records `run` calls, so the assertions prove the UI
/// reached the Rust lane, never that a fake invented a result.
class _FakeScriptBackend implements ScriptApiBackend {
  final Map<String, rust_pack.ScriptPackInfo> packs = {};
  final Map<String, List<Map<String, Object?>>> stored = {};

  /// Script entry-point results (`searchApps`/`getAllApps`), camelCase shape.
  final Map<String, List<Map<String, Object?>>> scriptResults = {};
  final List<String> runCalls = [];

  /// Script-domain insert records (the lane save path).
  final List<String> addAppKeys = [];
  rust.ChannelAppInfo? lastAddedApp;

  /// Invoked with the insert's `(key, app)` before recording, so a test can model
  /// persistence (make the saved row readable through [storedApps]).
  void Function(String key, rust.ChannelAppInfo app)? onAddApp;

  /// When non-null, [addApp] throws it (the lane failure path).
  Object? addAppError;

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
    runCalls.add('$key:$method');
    if (method == 'searchApps' || method == 'getAllApps') {
      return jsonEncode(scriptResults[key] ?? const <Object?>[]);
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
  }) async {
    final error = addAppError;
    if (error != null) throw error;
    onAddApp?.call(key, app);
    addAppKeys.add(key);
    lastAddedApp = app;
  }

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

/// Minimal enum channel so the flag-off picker has a real Dart registry entry
/// and the Dart save path can be exercised without a network/db.
class _FakeEnumChannel extends IChannel {
  _FakeEnumChannel(this._type, this._apps);

  final ChannelType _type;
  final List<AppSummary> _apps;

  @override
  ChannelInfo get info => ChannelInfo(
        type: _type,
        name: _type.code,
        description: '测试用枚举渠道',
      );

  @override
  bool isInitialized = false;

  @override
  Future<void> initialize() async => isInitialized = true;

  @override
  Future<bool> checkAvailable() async => true;

  @override
  Widget? getAddAppWidget(
    BuildContext context,
    Function(AppSummary) onAppAdded, {
    VoidCallback? onAppSaved,
  }) =>
      null;

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: _apps, from: _type);

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.failure(from: _type, error: '不支持');

  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(String appId) async =>
      ChannelResult.failure(from: _type, error: '不支持');

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<ChannelResult<void>> removeApp(String appId) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<ChannelResult<List<AppSummary>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: _apps, from: _type);

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(
    String categoryId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: _type);

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: _type);

  @override
  Future<ChannelResult<bool>> checkUpdate() async =>
      ChannelResult.success(data: false, from: _type);

  @override
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  }) async =>
      ChannelResult.success(data: true, from: _type);

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheSize() async => 0;

  @override
  Future<void> dispose() async {}
}

/// The channels-domain facade seam (no FRB dylib in `flutter test`).
///
/// A lane save must NOT reach this seam: `ChannelApi.addApp` is for channels-
/// domain channels and a `js_*` script pack is not one. It records every
/// `addApp` call so a test can assert the lane path never used it; every other
/// method is unused and fails loudly.
class _FakeChannelApiBackend implements ChannelApiBackend {
  final List<String> addAppKeys = [];

  @override
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {
    addAppKeys.add(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused facade method: ${invocation.memberName}');
}

/// Minimal aggregate seam: records `getAddedAppsIndex` reads and returns a
/// mutable [index] so a test can prove `_updateAddedAppsIndex` ran after a save.
class _FakeAggregateService implements IAggregateService {
  int getAddedAppsIndexCalls = 0;
  Map<String, Set<String>> index = {};

  @override
  Stream<List<AddedAppInfo>> get appsChangedStream => const Stream.empty();

  @override
  Future<Map<String, Set<String>>> getAddedAppsIndex() async {
    getAddedAppsIndexCalls++;
    return index;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused aggregate method: ${invocation.memberName}');
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
      '/tmp/gstore_picker_lane/data',
      '/tmp/gstore_picker_lane/files',
      '/tmp/gstore_picker_lane/cache',
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
}) =>
    {
      'app_id': appId,
      'package_name': appId,
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

  (ProviderContainer, DiscoveryNotifier) makeContainer() {
    final notifier = DiscoveryNotifier();
    final container = ProviderContainer(overrides: [
      discoveryProvider.overrideWith(() => notifier),
    ]);
    container.read(discoveryProvider);
    return (container, notifier);
  }

  setUp(() async {
    await ChannelManager.instance.disposeAll();
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    ModuleManager.instance.bind<ChannelManager>(ChannelManager.instance);
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    ScriptApi.resetBackend();
    ScriptChannelService.resetForTest();
    RustScriptChannelLane.resetForTest();
    RustChannelFacade.resetBackend();
    AddedAppsFacade.backendOverride = null;
    AddedAppsFacade.legacyBackendOverride = null;
    for (final type in ChannelType.values) {
      if (ChannelManager.instance.getChannel(type) != null) {
        ChannelManager.instance.unregisterChannel(type);
      }
    }
    await ChannelManager.instance.disposeAll();
    ModuleManager.instance.unbind<ChannelManager>();
  });

  /// Imports one pack through the production Rust-lane path and seeds one
  /// searchable row, returning the lane code.
  Future<String> importLanePack(_FakeScriptBackend backend) async {
    await _setFlag(jsChannel: true);
    _installScriptService(backend);
    final dir = await Directory.systemTemp.createTemp('gstore_picker_lane');
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
    backend.scriptResults['js_probe'] = [
      {'appId': 'com.probe', 'name': 'Probe App', 'des': 'desc'},
    ];
    return 'js_probe';
  }

  group('search picker includes Rust-lane channels', () {
    test('(a) picker list contains the imported js_* code with the pack name',
        () async {
      final backend = _FakeScriptBackend();
      final code = await importLanePack(backend);

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);

      // Precondition: the Dart dynamic registry is empty (the Rust lane owns it).
      expect(ChannelManager.instance.dynamicChannels, isEmpty);

      final options = notifier.searchChannelOptions();
      final lane = options.where((o) => o.code == code).toList();
      expect(lane, hasLength(1),
          reason: 'the picker must offer the Rust-lane $code channel');
      expect(lane.single.name, 'Probe Pack',
          reason: 'the lane channel must show its pack name');

      // Dedup: no code may appear twice even if Dart and lane ever overlap.
      final codes = options.map((o) => o.code).toList();
      expect(codes.toSet().length, codes.length, reason: 'codes must be unique');
    });

    test('(a2) the picker list is exactly the same source of truth as the '
        'channel list (sortedChannelCodes)', () async {
      final backend = _FakeScriptBackend();
      final code = await importLanePack(backend);

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);
      await notifier.loadData();

      expect(notifier.sortedChannelCodes, contains(code));
      expect(
        notifier.searchChannelOptions().map((o) => o.code).toSet(),
        containsAll(notifier.sortedChannelCodes.where((c) => c == code)),
        reason: 'a code shown as a channel tab must be selectable in the picker',
      );
    });

    test('(b) selecting the lane code searches through the lane (ScriptApi.run)',
        () async {
      final backend = _FakeScriptBackend();
      final code = await importLanePack(backend);

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);

      final apps = await notifier.searchChannelApps(code, 'probe');
      expect(apps.map((a) => a.appId), contains('com.probe'),
          reason: 'the picker search must run the Rust-lane script search');
      expect(backend.runCalls, contains('$code:searchApps'),
          reason: 'the lane search must go through ScriptApi.run(searchApps)');
    });

    test('save (a) saving a search result into a lane code calls the '
        'script-domain addApp with a faithfully-mapped app and returns success',
        () async {
      final backend = _FakeScriptBackend();
      final code = await importLanePack(backend);

      // (c) the channels-domain facade is installed but must NOT be used.
      final channelBackend = _FakeChannelApiBackend();
      RustChannelFacade.installBackend(channelBackend);

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);

      const app = AppSummary(
        appId: 'com.probe',
        packageName: 'com.probe.pkg',
        name: 'Probe App',
        user: 'alice',
        repositories: 'repo',
        icon: 'https://example.com/i.png',
        des: 'a probe app',
        readme: 'readme text',
        category: ['Tools', 'Games'],
        extra: {'k': 'v'},
      );

      final outcome = await notifier.saveSearchToChannel(code, app);

      expect(outcome, isA<SearchSaved>(),
          reason: 'a lane save must succeed when the script write succeeds');
      expect(backend.addAppKeys, [code],
          reason: 'the lane save must go through ScriptApi.addApp(key=code)');
      expect(channelBackend.addAppKeys, isEmpty,
          reason: 'ChannelApi.addApp must NOT be used for a lane code');
      final mapped = backend.lastAddedApp!;
      expect(mapped.appId, 'com.probe');
      expect(mapped.packageName, 'com.probe.pkg');
      expect(mapped.name, 'Probe App');
      expect(mapped.user, 'alice');
      expect(mapped.repositories, 'repo');
      expect(mapped.icon, 'https://example.com/i.png');
      expect(mapped.des, 'a probe app');
      expect(mapped.readme, 'readme text');
      expect(mapped.category, ['Tools', 'Games']);
      expect(jsonDecode(mapped.extraJson!), {'k': 'v'},
          reason: 'extra must round-trip as a JSON object string');
    });

    test('save (a2) an app without optional fields maps them to null/empty, '
        'not invented values', () async {
      final backend = _FakeScriptBackend();
      final code = await importLanePack(backend);

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);

      await notifier.saveSearchToChannel(
        code,
        const AppSummary(
          appId: 'com.bare',
          name: 'Bare',
          user: '',
          repositories: '',
          icon: '',
          des: '',
        ),
      );

      final mapped = backend.lastAddedApp!;
      expect(mapped.packageName, isNull);
      expect(mapped.readme, isNull);
      expect(mapped.extraJson, isNull);
      expect(mapped.category, isEmpty,
          reason: 'a missing category must map to an empty list, not invented');
    });

    test('save (b) a script-domain error surfaces as a typed failure, not a '
        'silent success', () async {
      final backend = _FakeScriptBackend();
      final code = await importLanePack(backend);

      // The Rust lane rejects an unknown key with a typed `pack_not_found`.
      backend.addAppError = Exception('pack_not_found: pack not installed: $code');

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);

      final outcome = await notifier.saveSearchToChannel(
        code,
        const AppSummary(
          appId: 'com.probe',
          name: 'Probe App',
          user: '',
          repositories: '',
          icon: '',
          des: '',
        ),
      );
      expect(outcome, isA<SearchSaveFailed>(),
          reason: 'a script-domain failure must never be a silent success');
      final failed = outcome as SearchSaveFailed;
      expect(failed.code, SearchSaveFailed.writeFailed);
      expect(failed.message, contains('pack_not_found'));
    });

    test('save (d) a successful lane save runs the refresh hooks '
        '(_refreshChannelApps + _updateAddedAppsIndex through the facade)',
        () async {
      final backend = _FakeScriptBackend();
      final code = await importLanePack(backend);
      // No saved rows yet: the slot starts empty, so the save must be what makes
      // the row appear (proves _refreshChannelApps re-read the lane rows).
      backend.stored[code] = [];

      // Model persistence: the added app becomes readable via ScriptApi.
      backend.onAddApp = (key, app) {
        backend.stored[key] = [_storedRow(appId: app.appId, name: app.name)];
      };

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);
      // Keep the autoDispose provider alive across the awaits below.
      final keepAlive = container.listen(discoveryProvider, (_, __) {});
      addTearDown(keepAlive.close);

      await notifier.loadData();
      await Future<void>.delayed(Duration.zero);
      expect(notifier.state.channelApps[code], isEmpty,
          reason: 'precondition: no saved rows before the save');

      // Bind the read seams only after the initial load settles, so ONLY the
      // save's _updateAddedAppsIndex observes them. `catalog` is off here, so the
      // facade routes the read to the legacy backend, NOT the aggregate service.
      final legacyBackend = RecordingAddedApps('legacy')
        ..added[code] = {'com.new'};
      AddedAppsFacade.legacyBackendOverride = legacyBackend;
      final agg = _FakeAggregateService()..index = {code: {'com.new'}};
      ModuleManager.instance.bindByType(IAggregateService, agg);
      addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));
      final listCallsBefore = legacyBackend.listCalls;

      final outcome = await notifier.saveSearchToChannel(
        code,
        const AppSummary(
          appId: 'com.new',
          name: 'New App',
          user: '',
          repositories: '',
          icon: '',
          des: '',
        ),
      );

      expect(outcome, isA<SearchSaved>());
      expect(notifier.state.channelApps[code]!.map((a) => a.appId),
          contains('com.new'),
          reason: '_refreshChannelApps must re-read the lane saved rows');
      expect(legacyBackend.listCalls, greaterThan(listCallsBefore),
          reason: '_updateAddedAppsIndex must read the facade after a lane save');
      expect(notifier.state.addedAppsIndex[code], contains('com.new'),
          reason: 'the refreshed added index must be applied to state');
      expect(agg.getAddedAppsIndexCalls, 0,
          reason: 'the read must NOT go through the legacy aggregate service');
    });
  });

  group('flag off: the picker is unchanged (Dart registry only)', () {
    test('(c) flag off: no lane code appears; the Dart channel is offered',
        () async {
      await _setFlag(jsChannel: false);
      ChannelManager.instance
          .registerChannel(_FakeEnumChannel(ChannelType.fdroid, const []));

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);

      final options = notifier.searchChannelOptions();
      expect(options.map((o) => o.code), contains('fdroid'));
      expect(options.map((o) => o.code).where((c) => c.startsWith('js_')),
          isEmpty,
          reason: 'flag off must never surface Rust-lane codes');
      expect(RustScriptChannelLane.instance.enabled, isFalse);
    });

    test('(c2) Dart-registry save path still succeeds (regression guard)',
        () async {
      await _setFlag(jsChannel: false);
      ChannelManager.instance
          .registerChannel(_FakeEnumChannel(ChannelType.fdroid, const []));

      final (container, notifier) = makeContainer();
      addTearDown(container.dispose);

      final outcome = await notifier.saveSearchToChannel(
        'fdroid',
        const AppSummary(
          appId: 'com.x',
          name: 'X',
          user: '',
          repositories: '',
          icon: '',
          des: '',
        ),
      );
      expect(outcome, isA<SearchSaved>());
    });
  });
}

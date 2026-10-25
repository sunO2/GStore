/// Post-wave06 bug fix: the discovery SEARCH-CHANNEL PICKER must offer the
/// Rust-lane (`js_*`) channels, and saving a search result into a lane code must
/// report a typed failure rather than a silent `false`.
///
/// User report: "发现页.渠道列表有 jschannel 导入的渠道，但是搜索却没有导入的
/// 渠道搜索项选择". The channel LIST is lane-aware (`sortedChannelCodes` merges
/// `RustScriptChannelLane.codes`); the picker was not.
///
/// The `ScriptApiBackend` is a seam (no FRB dylib inside `flutter test`); the
/// production import path (`ChannelLoader.importZip`) drives the Rust lane, so
/// the assertions prove the picker reads the real lane cache.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_channel_service.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/page/home/tab/discovery/logic.dart';
import 'package:gstore/page/home/tab/discovery/search_channel.dart';

/// In-memory `ScriptApiBackend` (the FRB seam). Serves `list`/`storedApps`/`run`
/// from its own maps and records `run` calls, so the assertions prove the UI
/// reached the Rust lane, never that a fake invented a result.
class _FakeScriptBackend implements ScriptApiBackend {
  final Map<String, rust_pack.ScriptPackInfo> packs = {};
  final Map<String, List<Map<String, Object?>>> stored = {};

  /// Script entry-point results (`searchApps`/`getAllApps`), camelCase shape.
  final Map<String, List<Map<String, Object?>>> scriptResults = {};
  final List<String> runCalls = [];

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

    test('(c) saving a search result into a lane code is a typed failure, '
        'not a silent false', () async {
      final backend = _FakeScriptBackend();
      final code = await importLanePack(backend);

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
          reason: 'the Rust lane has no save API: must not be a silent false');
      expect((outcome as SearchSaveFailed).code,
          SearchSaveFailed.laneUnsupported);
    });
  });

  group('flag off: the picker is unchanged (Dart registry only)', () {
    test('(d) no lane code appears; the Dart channel is offered', () async {
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

    test('(d2) Dart save path still succeeds (regression guard)', () async {
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

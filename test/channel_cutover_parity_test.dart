import 'dart:convert';

import 'package:flutter/material.dart';import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/page/home/tab/discovery/logic.dart';
import 'package:gstore/page/home/tab/discovery/search_channel.dart';

/// Flags backend that only toggles `channels` (the B2 gate).
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

/// Canonical fixture shared by both parity lanes.
const _appId = 'owner/repo';
const _appName = 'Example App';

rust.ChannelAppInfo _fixtureApp() => const rust.ChannelAppInfo(
      appId: _appId,
      packageName: 'com.example.app',
      name: _appName,
      user: 'owner',
      repositories: 'repo',
      icon: 'icon://example',
      des: 'fixture description',
      readme: '# readme',
      category: <String>['Tools'],
      extraJson: '{"packageName":"com.example.app"}',
      labels: <rust.ChannelLabel>[],
    );

AppSummary _legacyApp() => const AppSummary(
      appId: _appId,
      packageName: 'com.example.app',
      name: _appName,
      user: 'owner',
      repositories: 'repo',
      icon: 'icon://example',
      des: 'fixture description',
      readme: '# readme',
      category: <String>['Tools'],
      extra: <String, dynamic>{'packageName': 'com.example.app'},
    );

/// Recording facade backend; every call is observable so the parity and
/// discovery tests can prove which lane served the request.
class _RecordingFacadeBackend implements ChannelApiBackend {
  final List<String> calls = <String>[];

  @override
  Future<rust.LibraryApi> library() async =>
      throw UnimplementedError('library() is not used by this test');

  @override
  Future<List<rust.ChannelEntry>> list() async {
    calls.add('list');
    return const <rust.ChannelEntry>[];
  }

  @override
  Future<rust.ChannelEntry> get({required String key}) async {
    calls.add('get:$key');
    throw const ChannelApiException('not_found', 'not used');
  }

  @override
  Future<rust.ChannelEntry> register(
      {required rust.ChannelRegistration registration}) async {
    calls.add('register:${registration.key}');
    throw const ChannelApiException('not_found', 'not used');
  }

  @override
  Future<void> unregister({required String key}) async {
    calls.add('unregister:$key');
  }

  @override
  Future<rust.ChannelEntry> enable({required String key}) async {
    calls.add('enable:$key');
    throw const ChannelApiException('not_found', 'not used');
  }

  @override
  Future<rust.ChannelEntry> disable({required String key}) async {
    calls.add('disable:$key');
    throw const ChannelApiException('not_found', 'not used');
  }

  @override
  Future<rust.ChannelPackInfo> importPack({required String path}) async {
    calls.add('importPack:$path');
    throw const ChannelApiException('pack_invalid', 'not used');
  }

  @override
  Future<BigInt> exportPack({required String key, required String path}) async {
    calls.add('exportPack:$key:$path');
    return BigInt.zero;
  }

  @override
  Future<bool> removePack({required String key}) async {
    calls.add('removePack:$key');
    return true;
  }

  @override
  Future<String?> envGet({required String key, required String name}) async {
    calls.add('envGet:$key:$name');
    return null;
  }

  @override
  Future<void> envSet({
    required String key,
    required String name,
    required String value,
  }) async {
    calls.add('envSet:$key:$name');
  }

  @override
  Future<bool> envRemove({required String key, required String name}) async {
    calls.add('envRemove:$key:$name');
    return false;
  }

  @override
  Future<bool> refresh({required String key}) async {
    calls.add('refresh:$key');
    return true;
  }

  @override
  Future<List<rust.ChannelAppInfo>> listApps({
    required String key,
    required bool forceRefresh,
  }) async {
    calls.add('listApps:$key:$forceRefresh');
    return <rust.ChannelAppInfo>[_fixtureApp()];
  }

  @override
  Future<bool> checkUpdate({required String key}) async {
    calls.add('checkUpdate:$key');
    return true;
  }

  @override
  Future<List<rust.ChannelAppInfo>> search({
    required String key,
    required String keyword,
    required bool forceRefresh,
  }) async {
    calls.add('search:$key:$keyword:$forceRefresh');
    return <rust.ChannelAppInfo>[_fixtureApp()];
  }

  @override
  Future<rust.ChannelAppInfo> getAppInfo({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) async {
    calls.add('getAppInfo:$key:$appId:$forceRefresh');
    return _fixtureApp();
  }

  @override
  Future<rust.ChannelAppDetailInfo> getAppDetail({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) async {
    calls.add('getAppDetail:$key:$appId:$forceRefresh');
    throw const ChannelApiException('not_found', 'not used');
  }

  @override
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {
    calls.add('addApp:$key:${app.appId}');
  }

  @override
  Future<void> removeApp({required String key, required String appId}) async {
    calls.add('removeApp:$key:$appId');
  }

  @override
  Future<List<rust.ChannelAppInfo>> searchByCategory({
    required String key,
    required String categoryId,
    required bool forceRefresh,
  }) async {
    calls.add('searchByCategory:$key:$categoryId:$forceRefresh');
    return <rust.ChannelAppInfo>[_fixtureApp()];
  }

  @override
  Future<List<rust.ChannelCategoryInfo>> getAllCategories({
    required String key,
    required bool forceRefresh,
  }) async {
    calls.add('getAllCategories:$key:$forceRefresh');
    return const <rust.ChannelCategoryInfo>[
      rust.ChannelCategoryInfo(
        id: 'Tools',
        description: '工具',
        icon: 'icon://tools',
      ),
    ];
  }

  @override
  Future<String> canonicalAppId({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {
    calls.add('canonicalAppId:$key:${app.appId}');
    return app.appId;
  }

  @override
  Future<rust.ChannelConfigInfo?> getConfig({
    required String key,
    required bool forceRefresh,
  }) async {
    calls.add('getConfig:$key:$forceRefresh');
    return const rust.ChannelConfigInfo(version: '1.0', proxy: null);
  }

  @override
  Future<void> setFdroidSources({required List<String> sources}) async {
    calls.add('setFdroidSources:${sources.join(',')}');
  }

  // Todo 2 added the four JS detail-page methods to `ChannelApiBackend`; this
  // recording fake must implement them to stay a concrete implementation. No
  // parity test exercises them.
  @override
  Future<rust.ScriptVersionOptions?> scriptVersionOptions({
    required String key,
    required String appId,
    String? env,
    String? currentVersion,
  }) async =>
      null;

  @override
  Future<rust.ChannelAppDetailInfo?> scriptSwitchVersion({
    required String key,
    required String appId,
    required String env,
    required String version,
    String? buildJson,
  }) async =>
      null;

  @override
  Future<List<rust.ScriptBuild>> scriptBuildHistory({
    required String key,
    required String appId,
    required String env,
    required String version,
  }) async =>
      const [];

  @override
  Future<List<rust.ChannelDetailAction>> scriptDetailMenu({
    required String key,
    required String appId,
  }) async =>
      const [];

  @override
  Future<void> scriptDetailAction({
    required String key,
    required String appId,
    required String jscall,
  }) async {}
}

/// Legacy lane fixture: same observable data as [_RecordingFacadeBackend].
class _StubChannel extends IChannel {
  _StubChannel(this._type);

  final ChannelType _type;
  int getAllAppsCalls = 0;
  int searchAppsCalls = 0;

  @override
  ChannelInfo get info =>
      ChannelInfo(type: _type, name: 'stub', description: 'parity fixture');

  @override
  bool isInitialized = true;

  @override
  Future<void> initialize() async {}

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
  Future<ChannelResult<List<AppSummary>>> getAllApps(
      {bool forceRefresh = false}) async {
    getAllAppsCalls++;
    return ChannelResult.success(
      data: <AppSummary>[_legacyApp()],
      from: _type,
    );
  }

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: _legacyApp(), from: _type);

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.failure(from: _type, error: 'not used');

  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(String appId) async =>
      ChannelResult.failure(from: _type, error: 'not used');

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<String> canonicalAppId(AppSummary appInfo) async => appInfo.appId;

  @override
  Future<ChannelResult<void>> removeApp(String appId) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<ChannelResult<List<AppSummary>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  }) async {
    searchAppsCalls++;
    return ChannelResult.success(
      data: <AppSummary>[_legacyApp()],
      from: _type,
    );
  }

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(
    String categoryId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: <AppSummary>[_legacyApp()], from: _type);

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories(
      {bool forceRefresh = false}) async =>
      ChannelResult.success(
        data: <db.AppCategory>[
          db.AppCategory('Tools', '工具', 'icon://tools'),
        ],
        from: _type,
      );

  @override
  Future<ChannelResult<bool>> checkUpdate() async =>
      ChannelResult.success(data: true, from: _type);

  @override
  Future<ChannelResult<bool>> doUpdate(
          {Function(int current, int total)? onProgress}) async =>
      ChannelResult.success(data: true, from: _type);

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig(
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheSize() async => 0;

  @override
  Future<void> dispose() async {}
}

Future<void> _setChannelsFlag({required bool channels}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(channels: channels)),
  );
  await CoreFlags.refresh();
  expect(CoreFlags.channels, channels);
}

List<Map<String, Object?>> _appsSnapshot(List<AppSummary>? apps) =>
    <Map<String, Object?>>[
      for (final app in apps ?? const <AppSummary>[])
        <String, Object?>{
          'appId': app.appId,
          'packageName': app.packageName,
          'name': app.name,
          'user': app.user,
          'repositories': app.repositories,
          'icon': app.icon,
          'des': app.des,
          'readme': app.readme,
          'category': app.category,
          'extra': app.extra,
        },
    ];

Map<String, Object?> _appsResult(
  ChannelResult<List<AppSummary>> result,
) =>
    <String, Object?>{
      'success': result.success,
      'from': result.from.code,
      'apps': _appsSnapshot(result.data),
    };

Map<String, Object?> _detailResult(
  ChannelResult<AppSummary?> result,
) =>
    <String, Object?>{
      'success': result.success,
      'from': result.from.code,
      'apps': _appsSnapshot(
        result.data == null ? null : <AppSummary>[result.data!],
      ),
    };

/// One observable snapshot of every gated channel read. The same function runs
/// for the legacy lane and the facade lane so a non-empty diff means the
/// cutover changed behaviour.
Future<Map<String, Object?>> _channelReadSnapshot() async {
  final manager = ChannelManager.instance;
  final list = await manager.getAllApps(from: ChannelType.vivo);
  final search = await manager.searchApps('Example', from: ChannelType.vivo);
  final detail = await manager.getAppInfo(_appId, from: ChannelType.vivo);
  final categories =
      await manager.getAllCategories(from: ChannelType.vivo);
  final update = await manager.checkUpdate(from: ChannelType.vivo);
  return <String, Object?>{
    'list': _appsResult(list),
    'search': _appsResult(search),
    'detail': _detailResult(detail),
    'categories': <List<String>>[
      for (final category in categories.data ?? const <db.AppCategory>[])
        <String>[category.id, category.description, category.icon],
    ],
    'update': <String, Object?>{
      'success': update.success,
      'from': update.from.code,
      'data': update.data,
    },
  };
}

(ProviderContainer, DiscoveryNotifier) _makeContainer() {
  final notifier = DiscoveryNotifier();
  final container = ProviderContainer(
    overrides: [discoveryProvider.overrideWith(() => notifier)],
  );
  container.read(discoveryProvider);
  return (container, notifier);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _StubChannel stub;
  late _RecordingFacadeBackend backend;

  setUp(() async {
    await ChannelManager.instance.disposeAll();
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    ModuleManager.instance.bind<ChannelManager>(ChannelManager.instance);

    stub = _StubChannel(ChannelType.vivo);
    await stub.initialize();
    ChannelManager.instance.registerChannel(stub);

    backend = _RecordingFacadeBackend();
    RustChannelFacade.installBackend(backend);
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    RustChannelFacade.resetBackend();
    await ChannelManager.instance.disposeAll();
    ModuleManager.instance.unbind<ChannelManager>();
  });

  test('discovery_uses_facade_after_flip', () async {
    await _setChannelsFlag(channels: true);
    final (container, notifier) = _makeContainer();
    addTearDown(container.dispose);

    // Reset after the provider's first-frame microtask so only the explicit
    // loadData() below is measured.
    stub.getAllAppsCalls = 0;
    backend.calls.clear();

    await notifier.loadData();

    expect(
      backend.calls.where((call) => call.startsWith('listApps:')).toList(),
      isNotEmpty,
      reason: 'flag on 时 discovery 必须经 facade 读取渠道应用列表',
    );
    expect(
      stub.getAllAppsCalls,
      0,
      reason: 'flag on 时 discovery 不得再直接调用 IChannel.getAllApps',
    );
  });

  test('fallback reads and checkAllUpdates route to the facade after flip',
      () async {
    await _setChannelsFlag(channels: true);
    final manager = ChannelManager.instance;
    backend.calls.clear();
    stub.getAllAppsCalls = 0;

    final all = await manager.getAllAppsWithFallback();
    final info = await manager.getAppInfoWithFallback(_appId);
    final updates = await manager.checkAllUpdates();

    expect(all.success, isTrue);
    expect(info.success, isTrue);
    expect(updates[ChannelType.vivo]?.success, isTrue);
    expect(backend.calls, contains('listApps:vivo:false'));
    expect(backend.calls, contains('getAppInfo:vivo:$_appId:false'));
    expect(backend.calls, contains('checkUpdate:vivo'));
    expect(stub.getAllAppsCalls, 0);
  });

  test('discovery save-to-channel writes through the facade after flip',
      () async {
    await _setChannelsFlag(channels: true);
    final (container, notifier) = _makeContainer();
    addTearDown(container.dispose);
    backend.calls.clear();

    final outcome = await notifier.saveSearchToChannel('vivo', _legacyApp());

    expect(outcome, isA<SearchSaved>());
    expect(backend.calls, contains('addApp:vivo:$_appId'),
        reason: 'flag on 时发现页「添加」必须写 Rust facade（Dart 写被守卫拒绝）');
  });

  test('by-code info/add/remove/detail/canonical route to the facade after flip',
      () async {
    await _setChannelsFlag(channels: true);
    final manager = ChannelManager.instance;
    backend.calls.clear();

    final info = await manager.getAppInfoByCode('vivo', _appId);
    final added = await manager.addAppByCode('vivo', _legacyApp());
    final removed = await manager.removeAppByCode('vivo', _appId);
    final canonical = await manager.canonicalAppIdByCode('vivo', _legacyApp());
    final detail = await manager.getAppDetailByCode('vivo', _appId);

    expect(info.success, isTrue);
    expect(info.data?.appId, _appId);
    expect(added.success, isTrue);
    expect(removed.success, isTrue);
    expect(canonical, _appId);
    expect(detail.success, isFalse,
        reason: 'the recording backend throws for getAppDetail');

    expect(backend.calls, contains('getAppInfo:vivo:$_appId:false'));
    expect(backend.calls, contains('addApp:vivo:$_appId'));
    expect(backend.calls, contains('removeApp:vivo:$_appId'));
    expect(backend.calls, contains('canonicalAppId:vivo:$_appId'));
    expect(backend.calls, contains('getAppDetail:vivo:$_appId:false'));
  });

  test('by-code reads fall back to the Dart channel when the flag is off',
      () async {
    await _setChannelsFlag(channels: false);
    final manager = ChannelManager.instance;
    backend.calls.clear();

    final info = await manager.getAppInfoByCode('vivo', _appId);
    final added = await manager.addAppByCode('vivo', _legacyApp());

    expect(info.success, isTrue);
    expect(info.data?.appId, _appId);
    expect(added.success, isTrue);
    expect(backend.calls, isEmpty,
        reason: 'flag off 时 by-code 方法不得触碰 Rust facade');
  });

  test('channel list/search/detail/categories/update-check parity', () async {
    await _setChannelsFlag(channels: false);
    final legacy = await _channelReadSnapshot();
    expect(
      backend.calls,
      isEmpty,
      reason: 'flag off 不得触碰 Rust facade（旧路径不变）',
    );

    // Reset every shared singleton between the two lanes.
    backend.calls.clear();
    stub.getAllAppsCalls = 0;
    stub.searchAppsCalls = 0;
    await ChannelManager.instance.disposeAll();
    await _setChannelsFlag(channels: true);
    final freshStub = _StubChannel(ChannelType.vivo);
    await freshStub.initialize();
    ChannelManager.instance.registerChannel(freshStub);

    final facade = await _channelReadSnapshot();
    final legacyJson = jsonEncode(legacy);
    final facadeJson = jsonEncode(facade);
    final diff = legacyJson == facadeJson ? '' : '$facadeJson != $legacyJson';
    debugPrint('parity diff (legacy vs facade) = "$diff"');
    expect(
      diff,
      isEmpty,
      reason: 'legacy 与 facade 的渠道读结果 diff 必须为空',
    );
    expect(freshStub.getAllAppsCalls, 0, reason: 'facade lane 不得走旧 IChannel');
    expect(backend.calls, contains('listApps:vivo:false'));
    expect(backend.calls, contains('search:vivo:Example:false'));
    expect(backend.calls, contains('getAppInfo:vivo:$_appId:false'));
    expect(backend.calls, contains('getAllCategories:vivo:false'));
    expect(backend.calls, contains('checkUpdate:vivo'));
  });
}

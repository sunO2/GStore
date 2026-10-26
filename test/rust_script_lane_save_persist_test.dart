/// End-to-end Dart proof that a lane SAVE persists and is VISIBLE, and that the
/// card's 入库 action actually reaches the home library for a Rust-lane code.
///
/// User report: "jschannel可以搜索并添加了，但是无法入库" — the search-result SAVE
/// ("添加") worked, but adding the saved app to the home library ("入库", the card
/// tap / 添加到首页) did nothing. `DiscoveryNotifier.toggleApp` returned early
/// because a `js_*` lane pack has no Dart channels-domain instance, so the
/// aggregate (`IAggregateService`) — which already supports a null channel
/// instance — was never called.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_channel_service.dart';
import 'package:gstore/page/home/tab/discovery/logic.dart';
import 'package:gstore/page/home/tab/discovery/search_channel.dart';

/// In-memory `ScriptApiBackend` that PERSISTS inserts the way the real Rust
/// `ScriptApi.add_app` does: `addApp` writes a snake_case `channel_apps` row and
/// `storedApps` re-reads it. `decodeStoredApps` therefore runs against the real
/// serialized shape, not a hand-shaped shortcut.
class _PersistentScriptBackend implements ScriptApiBackend {
  final Map<String, rust_pack.ScriptPackInfo> packs = {};
  final Map<String, List<Map<String, Object?>>> stored = {};
  final Map<String, List<Map<String, Object?>>> scriptResults = {};
  final List<String> addAppKeys = [];

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
      description: '',
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
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async =>
      packs[key] ??
      rust_pack.ScriptPackInfo(
        key: key,
        name: 'Probe Pack',
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
    addAppKeys.add(key);
    final rows = stored.putIfAbsent(key, () => []);
    rows.removeWhere((row) => row['app_id'] == app.appId);
    rows.add({
      'app_id': app.appId,
      'package_name': app.packageName,
      'name': app.name,
      'user': app.user,
      'repositories': app.repositories,
      'icon': app.icon,
      'des': app.des,
      'readme': app.readme,
      'category': app.category.isEmpty ? null : app.category,
      'extra': app.extraJson == null ? null : jsonDecode(app.extraJson!),
    });
  }

  @override
  Future<void> releaseDetail({
    required String key,
    required String appId,
  }) async {}
}

/// Minimal aggregate seam: records `toggleApp` and serves a mutable index.
class _RecordingAggregate implements IAggregateService {
  final List<(String, String)> toggleCalls = [];
  Map<String, Set<String>> index = {};

  @override
  Stream<List<AddedAppInfo>> get appsChangedStream => const Stream.empty();

  @override
  Future<bool> toggleApp({
    required String channelCode,
    required AppSummary appInfo,
  }) async {
    toggleCalls.add((channelCode, appInfo.appId));
    return true;
  }

  @override
  Future<Map<String, Set<String>>> getAddedAppsIndex() async => index;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused aggregate method: ${invocation.memberName}');
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
    coreDirs: () async => ('/d', '/f', '/c'),
    ensureRust: () async {},
  ));
}

Uint8List _zipOf(String entry) {
  final archive = Archive()..addFile(ArchiveFile.string('entry.js', entry));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Map<String, Object?> _row(String appId, String name) => {
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

const AppSummary _savedApp = AppSummary(
  appId: 'com.new',
  name: 'New App',
  user: '',
  repositories: '',
  icon: '',
  des: '',
);

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

  Future<String> importLanePack(_PersistentScriptBackend backend) async {
    await _setFlag(jsChannel: true);
    _installScriptService(backend);
    final dir = await Directory.systemTemp.createTemp('gstore_save_persist');
    addTearDown(() => dir.delete(recursive: true));
    final imported = await ChannelLoader(directory: dir).importZip(
      channelKey: 'js_probe',
      zipBytes: _zipOf('function main(){ return null; }'),
    );
    expect(imported, isA<ScriptLaneChannelImport>());
    return 'js_probe';
  }

  test(
      'a lane save persists, is visible without re-entering the page, and '
      'survives a lane refresh() + re-read', () async {
    final backend = _PersistentScriptBackend();
    final code = await importLanePack(backend);

    final (container, notifier) = makeContainer();
    addTearDown(container.dispose);
    final keepAlive = container.listen(discoveryProvider, (_, __) {});
    addTearDown(keepAlive.close);

    await notifier.loadData();
    await Future<void>.delayed(Duration.zero);
    expect(notifier.state.channelApps[code] ?? const [], isEmpty,
        reason: 'precondition: the freshly imported pack has no saved rows');

    final outcome = await notifier.saveSearchToChannel(code, _savedApp);
    expect(outcome, isA<SearchSaved>());
    expect(backend.addAppKeys, [code],
        reason: '(i) the save must call ScriptApi.addApp with the UI key');
    expect(notifier.state.channelApps[code]!.map((a) => a.appId),
        contains('com.new'),
        reason: '(ii) the saved row must appear without re-entering the page');

    // (iii) a lane refresh() re-reads the same rows; the app must still be there.
    await RustScriptChannelLane.instance.refresh();
    await notifier.loadData();
    expect(notifier.state.channelApps[code]!.map((a) => a.appId),
        contains('com.new'),
        reason: '(iii) the saved row must survive a lane refresh() + re-read');
  });

  testWidgets(
      'tapping 入库 (toggleApp) on a lane card reaches the home aggregate',
      (tester) async {
    late _PersistentScriptBackend backend;
    late String code;
    late _RecordingAggregate agg;
    late DiscoveryNotifier notifier;
    late ProviderContainer container;

    // Real file I/O (import) and the aggregate bind run on the real event loop;
    // testWidgets' FakeAsync would otherwise never complete them.
    await tester.runAsync(() async {
      backend = _PersistentScriptBackend();
      code = await importLanePack(backend);
      backend.stored[code] = [_row('com.probe', 'Probe App')];
      agg = _RecordingAggregate()..index = {
        code: {'com.probe'},
      };
      ModuleManager.instance.bindByType(IAggregateService, agg);
      final made = makeContainer();
      container = made.$1;
      notifier = made.$2;
      container.listen(discoveryProvider, (_, __) {});
      await notifier.loadData();
    });
    addTearDown(container.dispose);
    addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

    expect(notifier.state.channelApps[code]!.map((a) => a.appId),
        contains('com.probe'),
        reason: 'precondition: the saved row is visible in the channel view');

    // A real mounted context, then unmount it so the fire-and-forget tag sheet
    // is skipped and this test exercises only the 入库 aggregate call.
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }),
    ));
    await tester.pumpWidget(const SizedBox());

    await tester.runAsync(() => notifier.toggleApp(ctx, code, _rowApp));

    expect(agg.toggleCalls, contains((code, 'com.probe')),
        reason: '入库 on a lane code must reach IAggregateService.toggleApp');
  });
}

const AppSummary _rowApp = AppSummary(
  appId: 'com.probe',
  name: 'Probe App',
  user: '',
  repositories: '',
  icon: '',
  des: '',
);

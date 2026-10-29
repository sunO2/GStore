/// Regression: every "add to home" entry point must let the Rust
/// `LibraryService` write the app's `channel_apps` metadata (name/icon) as part
/// of the same call that writes the `added_apps` membership.
///
/// S3 moved the write path from "Dart `AddedAppsApi.add` + `ChannelApi.addApp`"
/// to ONE `rust.LibraryApi.add/toggle` carrying a `ChannelAppInfo`. These tests
/// drive the production `AddedAppsFacade` against a fake `rust.LibraryApi`
/// (`RustChannelFacade.installBackend`) and assert:
///
/// * the `LibraryApi.add/toggle` call carries the right code + appId + name +
///   icon (so Rust can persist the metadata row), and
/// * the legacy channels-domain `ChannelApi.addApp` is NEVER called by Dart, and
/// * a js-lane code still works (Rust resolves `js_*` to the script driver).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
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

import 'support/discovery_facade_seams.dart';
import 'support/library_api_seam.dart';

/// Minimal `ScriptApiBackend` serving one installed pack + one stored row, so
/// the Rust script lane reports `js_probe` as a lane code.
class _FakeScriptBackend implements ScriptApiBackend {
  static const _pack = rust_pack.ScriptPackInfo(
    key: 'js_probe',
    name: 'Probe Pack',
    description: 'seam',
    icon: '',
    hasDetail: false,
  );

  static const _stored =
      '[{"app_id":"com.probe","name":"Probe App","user":"","repositories":"",'
      '"icon":"probe.png","des":"d","readme":null,"category":null,"extra":null}]';

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {}

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async => const [_pack];

  @override
  Future<String> storedApps({required String key}) async => _stored;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused ScriptApiBackend member: ${invocation.memberName}');
}

Future<void> _setFlags({
  bool channels = false,
  bool catalog = false,
  bool jsChannel = false,
}) async {
  CoreFlags.installBackend(
    FakeFlagsBackend(CoreFlagsSnapshot(
      channels: channels,
      catalog: catalog,
      jsChannel: jsChannel,
    )),
  );
  await CoreFlags.refresh();
}

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
    AddedAppsFacade.backendOverride = null;
    RustChannelFacade.resetBackend();
    ScriptApi.resetBackend();
    ScriptChannelService.resetForTest();
    RustScriptChannelLane.resetForTest();
    await ChannelManager.instance.disposeAll();
    ModuleManager.instance.unbind<ChannelManager>();
  });

  /// Captures a mounted [BuildContext] then unmounts it, so the fire-and-forget
  /// tag sheet is skipped and only the write path is exercised.
  Future<BuildContext> unmountedContext(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }));
    await tester.pumpWidget(const SizedBox());
    return ctx;
  }

  /// Builds the flag + provider container on the real event loop (see
  /// `discovery_add_via_facade_test.dart` for the zone caveat).
  Future<(ProviderContainer, DiscoveryNotifier)> boot(
    WidgetTester tester, {
    bool load = false,
  }) async {
    late ProviderContainer container;
    late DiscoveryNotifier notifier;
    await tester.runAsync(() async {
      final made = makeContainer();
      container = made.$1;
      notifier = made.$2;
      container.listen(discoveryProvider, (_, __) {});
      if (load) {
        await notifier.loadData();
      }
    });
    addTearDown(container.dispose);
    return (container, notifier);
  }

  testWidgets(
      'toggleApp writes channel metadata via LibraryApi.toggle with the right '
      'code + name/icon (no Dart addApp)', (tester) async {
    final library = FakeLibraryApi();
    final channels = FakeChannelApiBackend(library);
    RustChannelFacade.installBackend(channels);

    ChannelManager.instance
        .registerChannel(FakeEnumChannel(ChannelType.fdroid, const []));
    ModuleManager.instance.bindByType(IAggregateService, RecordingAggregate());
    addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

    await tester.runAsync(() => _setFlags(channels: true));
    final (_, notifier) = await boot(tester);
    final ctx = await unmountedContext(tester);

    const app = AppSummary(
      appId: 'com.metadata',
      name: 'Metadata App',
      user: '',
      repositories: '',
      icon: 'https://icons/metadata.png',
      des: 'desc',
    );
    await tester.runAsync(() => notifier.toggleApp(ctx, 'fdroid', app));

    expect(library.toggleCalls, hasLength(1),
        reason: 'adding to home must go through the Rust library toggle');
    final call = library.toggleCalls.single;
    expect(call.channel, 'fdroid');
    expect(call.app.appId, 'com.metadata');
    expect(call.app.name, 'Metadata App',
        reason: 'the LibraryApi payload must carry the real name, not the appId');
    expect(call.app.icon, 'https://icons/metadata.png');
    expect(channels.addAppCalls, isEmpty,
        reason: 'Dart must no longer write channel_apps through ChannelApi');
  });

  testWidgets('multi-select batchAddSelected passes channel metadata to '
      'LibraryApi.toggle for each add', (tester) async {
    final library = FakeLibraryApi();
    final channels = FakeChannelApiBackend(library);
    RustChannelFacade.installBackend(channels);

    const app = AppSummary(
      appId: 'com.batch',
      name: 'Batch App',
      user: '',
      repositories: '',
      icon: 'batch.png',
      des: 'desc',
    );
    channels.listAppsResult = [
      rust.ChannelAppInfo(
        appId: app.appId,
        packageName: app.packageName,
        name: app.name,
        user: app.user,
        repositories: app.repositories,
        icon: app.icon,
        des: app.des,
        category: const <String>[],
        labels: const <rust.ChannelLabel>[],
      ),
    ];
    ChannelManager.instance
        .registerChannel(FakeEnumChannel(ChannelType.fdroid, const [app]));
    ModuleManager.instance.bindByType(IAggregateService, RecordingAggregate());
    addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

    await tester.runAsync(() => _setFlags(channels: true));
    final (_, notifier) = await boot(tester, load: true);

    // Select the app, then run the batch add.
    await tester.runAsync(() async {
      notifier.toggleAppSelection('fdroid', 'com.batch');
      await notifier.batchAddSelected();
    });

    expect(library.toggleCalls, hasLength(1),
        reason: 'batch add must also go through the Rust library toggle');
    final call = library.toggleCalls.single;
    expect(call.channel, 'fdroid');
    expect(call.app.appId, 'com.batch');
    expect(call.app.name, 'Batch App');
    expect(channels.addAppCalls, isEmpty,
        reason: 'Dart must not write channel_apps through ChannelApi');
  });

  testWidgets('addAllFromChannel passes channel metadata to LibraryApi.add for '
      'every app', (tester) async {
    final library = FakeLibraryApi();
    final channels = FakeChannelApiBackend(library);
    RustChannelFacade.installBackend(channels);

    const appA = AppSummary(
      appId: 'com.a',
      name: 'A',
      user: '',
      repositories: '',
      icon: 'a.png',
      des: '',
    );
    const appB = AppSummary(
      appId: 'com.b',
      name: 'B',
      user: '',
      repositories: '',
      icon: 'b.png',
      des: '',
    );
    channels.listAppsResult = [
      for (final app in const [appA, appB])
        rust.ChannelAppInfo(
          appId: app.appId,
          packageName: app.packageName,
          name: app.name,
          user: app.user,
          repositories: app.repositories,
          icon: app.icon,
          des: app.des,
          category: const <String>[],
          labels: const <rust.ChannelLabel>[],
        ),
    ];
    ChannelManager.instance.registerChannel(
        FakeEnumChannel(ChannelType.fdroid, const [appA, appB]));
    ModuleManager.instance.bindByType(IAggregateService, RecordingAggregate());
    addTearDown(() => ModuleManager.instance.unbindByType(IAggregateService));

    await tester.runAsync(() => _setFlags(channels: true));
    final (_, notifier) = await boot(tester, load: true);
    await tester.runAsync(() => notifier.addAllFromChannel('fdroid'));

    expect(
      library.addCalls.map((c) => c.app.appId).toSet(),
      {'com.a', 'com.b'},
      reason: 'every batch-added app must carry its metadata to LibraryApi.add',
    );
    expect(library.addCalls.map((c) => c.app.name).toSet(), {'A', 'B'});
    expect(channels.addAppCalls, isEmpty,
        reason: 'Dart must not write channel_apps through ChannelApi');
  });

  testWidgets('js-lane codes still add through LibraryApi (Rust script driver '
      'owns the metadata) and never touch the channels domain', (tester) async {
    final library = FakeLibraryApi();
    final channels = FakeChannelApiBackend(library);
    RustChannelFacade.installBackend(channels);

    final script = _FakeScriptBackend();
    ScriptApi.installBackend(script);
    ScriptChannelService.installForTest(ScriptChannelService(
      coreDirs: () async => (
        '/tmp/gstore_meta_lane/data',
        '/tmp/gstore_meta_lane/files',
        '/tmp/gstore_meta_lane/cache',
      ),
      ensureRust: () async {},
    ));

    await tester.runAsync(() async {
      await _setFlags(channels: true, jsChannel: true);
      await RustScriptChannelLane.instance.refresh();
    });
    expect(RustScriptChannelLane.instance.packFor('js_probe'), isNotNull,
        reason: 'precondition: js_probe is a Rust lane pack');

    final (_, notifier) = await boot(tester, load: true);
    expect(notifier.state.channelApps['js_probe'], isNotEmpty,
        reason: 'precondition: the lane stored row is loaded into the grid');

    await tester.runAsync(() => notifier.addAllFromChannel('js_probe'));

    expect(library.addCalls, hasLength(1),
        reason: 'the home-list add still goes through the Rust library');
    final call = library.addCalls.single;
    expect(call.channel, 'js_probe');
    expect(call.app.appId, 'com.probe');
    expect(call.app.name, 'Probe App',
        reason: 'Rust resolves js_* to the script driver, so its row is kept');
    expect(channels.addAppCalls, isEmpty,
        reason: 'the js lane must never be routed at the channels-domain '
            'ChannelApi.addApp');
  });
}

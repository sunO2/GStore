/// Post-wave06: F-Droid is fully cut over to the Rust core, so channel reads
/// must route through the Rust facade (like github/vivo) when
/// `CoreFlags.channels` is on, and only fall back to the Dart `IChannel` lane
/// when the flag is off.
///
/// History: wave-6 cut every channel read over to the Rust core facade
/// (`cdffd124`) and `CoreFlags.channels` defaults true, but the core `fdroid`
/// driver was non-functional at the time — `CoreConfig.fdroid_sources` was never
/// populated at runtime and the core never downloaded its `data_dir/repo.db`
/// index — so fdroid was gated off the facade (`_dartOnlyFacadeCodes`).
///
/// That gap is closed: `FdroidRepoManager` pushes the enabled sources to the core
/// via `setFdroidSources` (arming the driver with sources), and
/// `FdroidDriver::search_apps` / `get_app_detail` now call `ensure_active_index`
/// to download the index on demand — mirroring Dart `FdroidChannel`, which
/// downloads the index lazily. So fdroid's list/search/info/detail/add/remove all
/// go through the facade, exactly like github/vivo.
///
/// This test proves the routing: with the flag on fdroid goes through the facade
/// (and the Dart repo service is untouched); with the flag off it falls back to
/// the Dart lane. No native library is loadable inside `flutter test`, so the
/// `ChannelApiBackend` and `IFdroidRepoService` are the seams; the assertions
/// prove which lane served the request, never that a fake invented a result.
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/FdroidChannel.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Flags backend that only toggles `channels` (the B2 gate), same shape as the
/// parity suite's `_FakeFlagsBackend`.
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

/// The channels-domain facade seam. Records every call so a test can prove which
/// lane served the request; only `search` is exercised (fdroid + vivo control).
class _RecordingFacadeBackend implements ChannelApiBackend {
  final List<String> calls = <String>[];

  @override
  Future<List<rust.ChannelAppInfo>> search({
    required String key,
    required String keyword,
    required bool forceRefresh,
  }) async {
    calls.add('search:$key:$keyword:$forceRefresh');
    return <rust.ChannelAppInfo>[
      const rust.ChannelAppInfo(
        appId: 'owner/repo',
        packageName: 'com.example.app',
        name: 'Example App',
        user: 'owner',
        repositories: 'repo',
        icon: 'icon://example',
        des: 'fixture description',
        readme: '# readme',
        category: <String>['Tools'],
        extraJson: null,
        labels: <rust.ChannelLabel>[],
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused facade method: ${invocation.memberName}');
}

/// The fdroid repo seam. `searchApps` returns exactly one row (the Dart-lane
/// proof); every other method is unused and fails loudly. This mirrors the
/// `noSuchMethod`-throwing fake pattern used elsewhere in the suite.
class _FakeFdroidRepoService implements IFdroidRepoService {
  int searchCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> searchApps(
    String keyword, {
    int limit = 50,
  }) async {
    searchCalls++;
    return <Map<String, dynamic>>[
      {
        'packageName': 'com.demo',
        'name': 'Demo',
        'summary': 's',
        'icon': '',
        'categories': <dynamic>[],
        'sourceId': 'official',
      },
    ];
  }

  @override
  FdroidSource? get currentSource => null;

  @override
  String identityKeyFor(FdroidSource source) => 'test:${source.id}';

  @override
  String? cachedBaseFor(FdroidSource source) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused fdroid repo method: ${invocation.memberName}');
}

Future<void> _setChannelsFlag({required bool channels}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(channels: channels)),
  );
  await CoreFlags.refresh();
  expect(CoreFlags.channels, channels);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ChannelManager.instance.disposeAll();
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    ModuleManager.instance.bind<ChannelManager>(ChannelManager.instance);
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    RustChannelFacade.resetBackend();
    ModuleManager.instance.unbindByType(IFdroidRepoService);
    await ChannelManager.instance.disposeAll();
    ModuleManager.instance.unbind<ChannelManager>();
  });

  /// Binds the fake repo service + recording facade backend, registers the REAL
  /// [FdroidChannel], and returns the recording backend for assertions.
  _RecordingFacadeBackend wireFdroidLane(_FakeFdroidRepoService fake) {
    ModuleManager.instance.bindByType(IFdroidRepoService, fake);
    final backend = _RecordingFacadeBackend();
    RustChannelFacade.installBackend(backend);
    ChannelManager.instance.registerChannel(FdroidChannel(dio: Dio()));
    return backend;
  }

  test('flag on: fdroid search routes to the Rust facade', () async {
    await _setChannelsFlag(channels: true);
    final fake = _FakeFdroidRepoService();
    final backend = wireFdroidLane(fake);

    final result =
        await ChannelManager.instance.searchAppsByCode('fdroid', 'demo');

    expect(result.success, isTrue,
        reason: 'fdroid search must succeed via the Rust facade');
    expect(result.data!.map((a) => a.appId), contains('owner/repo'),
        reason: 'the facade row must surface for fdroid');
    expect(backend.calls, contains('search:fdroid:demo:false'),
        reason: 'fdroid search must go through the Rust facade after the cutover');
    expect(fake.searchCalls, 0,
        reason: 'the Dart IFdroidRepoService must not serve fdroid search '
            'when the flag is on');
  });

  test('control: vivo still routes to the facade', () async {
    await _setChannelsFlag(channels: true);
    final backend = _RecordingFacadeBackend();
    RustChannelFacade.installBackend(backend);

    final result =
        await ChannelManager.instance.searchAppsByCode('vivo', 'demo');

    expect(result.success, isTrue);
    expect(backend.calls, contains('search:vivo:demo:false'),
        reason: 'vivo must keep using the Rust facade after the cutover');
    expect(backend.calls.where((c) => c.startsWith('search:vivo')).length, 1);
  });

  test('flag off: fdroid search falls back to the Dart path', () async {
    await _setChannelsFlag(channels: false);
    final fake = _FakeFdroidRepoService();
    final backend = wireFdroidLane(fake);

    final result =
        await ChannelManager.instance.searchAppsByCode('fdroid', 'demo');

    expect(result.success, isTrue);
    expect(result.data!.map((a) => a.appId), contains('com.demo'));
    expect(fake.searchCalls, 1,
        reason: 'flag off must serve fdroid through the Dart lane');
    expect(backend.calls, isEmpty,
        reason: 'flag off must never touch the Rust facade');
  });
}

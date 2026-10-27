/// Post-wave06 bug fix: F-Droid channel search must stay on the **Dart lane**
/// even while `CoreFlags.channels` is on.
///
/// Root cause (Oracle-verified, see `rust/target/test-evidence/270-fdroid-dart-lane.txt`):
/// wave-6 cut every channel read over to the Rust core facade (`cdffd124`), and
/// `CoreFlags.channels` defaults true. But the core `fdroid` driver is provably
/// non-functional: `FdroidDriver::search_apps`/`get_all_apps` early-return `[]`
/// when `active_sources()` is empty, and `CoreConfig.fdroid_sources` is never
/// populated at runtime (`ChannelApi::init` builds `CoreConfig::new(None, token)`;
/// the only `with_fdroid_sources` caller is the one-time migration import that
/// persists to `update_prefs` but never updates the live config). Even with
/// sources, the core `HostRepoPort` queries a single `data_dir/repo.db` the core
/// never downloads — the Dart path indexes per-source `docs/fdroid_<hash>.db`.
/// github/vivo are stateless HTTP drivers and local_db reads the core DB, so
/// only fdroid is broken. The Dart path (`FdroidChannel.searchApps` →
/// `IFdroidRepoService` → per-source repo module) works and is what the in-file
/// fdroid search widget already uses.
///
/// The fix gates ONLY fdroid off the facade in `ChannelManager`, at the
/// predicate (not the UI): the facade lane is skipped for fdroid and the Dart
/// `IChannel` fallback serves the read. This test proves the routing.
///
/// No native library is loadable inside `flutter test`, so the `ChannelApiBackend`
/// and `IFdroidRepoService` are the seams; the assertions prove which lane served
/// the request, never that a fake invented a result.
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

/// The channels-domain facade seam. Records every call so a test can prove the
/// fdroid lane never reached it; only `search` is exercised (vivo control).
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

  test('flag on: fdroid search stays on the Dart path, facade untouched',
      () async {
    await _setChannelsFlag(channels: true);
    final fake = _FakeFdroidRepoService();
    final backend = wireFdroidLane(fake);

    final result =
        await ChannelManager.instance.searchAppsByCode('fdroid', 'demo');

    expect(result.success, isTrue,
        reason: 'fdroid search must succeed via the Dart lane with the flag on');
    expect(result.data!.map((a) => a.appId), contains('com.demo'),
        reason: 'the Dart repo service row must surface');
    expect(fake.searchCalls, 1,
        reason: 'the fdroid search must go through the Dart IFdroidRepoService');
    expect(
      backend.calls.where((c) => c.startsWith('search:fdroid')).toList(),
      isEmpty,
      reason: 'the gate must keep fdroid off the Rust facade',
    );
    expect(backend.calls, isEmpty,
        reason: 'the fdroid lane must not touch the facade at all');
  });

  test('control: vivo still routes to the facade (gate is fdroid-scoped)',
      () async {
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

  test('flag off: fdroid search still works via the Dart path', () async {
    await _setChannelsFlag(channels: false);
    final fake = _FakeFdroidRepoService();
    final backend = wireFdroidLane(fake);

    final result =
        await ChannelManager.instance.searchAppsByCode('fdroid', 'demo');

    expect(result.success, isTrue);
    expect(result.data!.map((a) => a.appId), contains('com.demo'));
    expect(fake.searchCalls, 1);
    expect(backend.calls, isEmpty,
        reason: 'flag off must never touch the Rust facade');
  });
}

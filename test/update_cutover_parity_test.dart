import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/rust/core_bootstrap.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_cache.dart';
import 'package:gstore/core/update/update_facade.dart';
import 'package:gstore/core/update/update_log.dart';
import 'package:gstore/core/update/update_manager.dart';
import 'package:gstore/page/update/logic.dart';
import 'package:gstore/page/update/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Flags backend that only toggles the two domains the update cutover needs.
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

const int _checkedAtMillis = 1710000000000;
final DateTime _checkedAt = DateTime.fromMillisecondsSinceEpoch(_checkedAtMillis);

/// Core-native fixture: the exact camelCase JSON `UpdateApi` emits (no
/// `detail`). This is deliberately NOT the Dart object shape: the parity path
/// decodes it with the production [decodeUpdateList] codec.
List<Map<String, dynamic>> _coreUpdatesJson({String alphaLatest = '2.0.0'}) {
  return <Map<String, dynamic>>[
    <String, dynamic>{
      'channelId': 'github',
      'appId': 'owner/alpha',
      'appName': 'Alpha',
      'iconUrl': 'https://example.test/alpha.png',
      'packageName': 'com.example.alpha',
      'installedVersion': '1.0.0',
      'latestVersion': alphaLatest,
      'checkedAt': _checkedAtMillis,
      'download': <String, dynamic>{
        'url': 'https://example.test/alpha-arm64-$alphaLatest.apk',
        'name': 'alpha-arm64-v8a.apk',
        'size': 1234,
        'downloadCount': 7,
        'version': alphaLatest,
        'versionCode': 200,
        'publishedAt': _checkedAtMillis,
        'platform': 'arm64-v8a',
        'hash': 'alpha-sha256',
        'hashType': 'sha256',
      },
    },
    <String, dynamic>{
      'channelId': 'github',
      'appId': 'owner/beta',
      'appName': 'Beta',
      'iconUrl': 'https://example.test/beta.png',
      'packageName': 'com.example.beta',
      'installedVersion': '3.1.0',
      'latestVersion': '4.0.0',
      'checkedAt': _checkedAtMillis,
      'download': <String, dynamic>{
        'url': 'https://example.test/beta-universal.apk',
        'name': 'beta-universal.apk',
        'size': 4321,
        'downloadCount': 3,
        'version': '4.0.0',
        'versionCode': 400,
        'publishedAt': _checkedAtMillis,
        'platform': 'universal',
        'hash': 'beta-sha256',
        'hashType': 'sha256',
      },
    },
  ];
}

/// Legacy-native fixture: the same logical check expressed as Dart models the
/// legacy engine builds. It is produced independently of the core JSON above
/// so an echo-it-back fake cannot fake parity.
List<AppUpdateInfo> _legacyUpdates() => <AppUpdateInfo>[
      AppUpdateInfo(
        channelId: 'github',
        appId: 'owner/alpha',
        appName: 'Alpha',
        iconUrl: 'https://example.test/alpha.png',
        packageName: 'com.example.alpha',
        installedVersion: '1.0.0',
        latestVersion: '2.0.0',
        checkedAt: _checkedAt,
        latestDownload: DownloadInfo(
          url: 'https://example.test/alpha-arm64-2.0.0.apk',
          name: 'alpha-arm64-v8a.apk',
          size: 1234,
          downloadCount: 7,
          version: '2.0.0',
          versionCode: 200,
          publishedAt: _checkedAt,
          platform: 'arm64-v8a',
          hash: 'alpha-sha256',
          hashType: 'sha256',
        ),
      ),
      AppUpdateInfo(
        channelId: 'github',
        appId: 'owner/beta',
        appName: 'Beta',
        iconUrl: 'https://example.test/beta.png',
        packageName: 'com.example.beta',
        installedVersion: '3.1.0',
        latestVersion: '4.0.0',
        checkedAt: _checkedAt,
        latestDownload: DownloadInfo(
          url: 'https://example.test/beta-universal.apk',
          name: 'beta-universal.apk',
          size: 4321,
          downloadCount: 3,
          version: '4.0.0',
          versionCode: 400,
          publishedAt: _checkedAt,
          platform: 'universal',
          hash: 'beta-sha256',
          hashType: 'sha256',
        ),
      ),
    ];

/// Legacy-lane fake manager: reproduces `UpdateManagerService.checkUpdates`
/// state + persistence (the same four prefs keys) without touching channels.
class _FixtureUpdateManager extends UpdateManagerService {
  _FixtureUpdateManager({List<AppUpdateInfo>? updates})
      : _fixture = updates ?? const <AppUpdateInfo>[];

  final List<AppUpdateInfo> _fixture;

  int checkCount = 0;

  @override
  Future<void> checkUpdates({
    bool force = false,
    void Function(UpdateCheckProgress progress)? onProgress,
    void Function(CheckLogLevel level, String message)? onLog,
    void Function(List<String> appNames)? onCheckList,
  }) async {
    checkCount++;
    final logs = <CheckLogEntry>[
      CheckLogEntry(
        level: CheckLogLevel.info,
        text: '开始检测应用更新...',
        time: _checkedAt,
      ),
      CheckLogEntry(
        level: CheckLogLevel.info,
        text: '已添加应用共 ${_fixture.length} 个',
        time: _checkedAt,
      ),
      for (final update in _fixture)
        CheckLogEntry(
          level: CheckLogLevel.update,
          text: '${update.appName}：发现更新 ${update.latestVersion}',
          time: _checkedAt,
        ),
      CheckLogEntry(
        level: CheckLogLevel.update,
        text: '检测完成：发现 ${_fixture.length} 个可更新应用',
        time: _checkedAt,
      ),
    ];
    debugSetState(
      updateList: _fixture,
      checkLog: logs,
      lastCheckedAt: _checkedAt,
      checkList: <String>[for (final update in _fixture) update.appName],
      checkedCount: _fixture.length,
      totalCount: _fixture.length,
    );
    // The real manager persists these four keys; parity is defined on them.
    await UpdateCache.saveCheckedAt(_checkedAt);
    await UpdateCache.saveResults(_fixture);
    await UpdateCache.saveLogs(logs);
    onCheckList?.call(<String>[for (final update in _fixture) update.appName]);
    onLog?.call(CheckLogLevel.update, logs.last.text);
  }
}

/// Core-lane fake: only the existing `UpdateBackend.check` contract is used, so
/// the RED run compiles against today's API while proving the facade path is
/// not consulted.
class _RecordingCoreBackend implements UpdateBackend {
  _RecordingCoreBackend(this.updatesJson);

  final List<Map<String, dynamic>> updatesJson;
  final List<String> calls = <String>[];

  List<AppUpdateInfo> get _updates => decodeUpdateList(jsonEncode(updatesJson));

  @override
  Future<List<AppUpdateInfo>> check({required bool force}) async {
    calls.add('check:$force');
    return _updates;
  }

  @override
  Future<List<AppUpdateInfo>> run() async {
    calls.add('run');
    return _updates;
  }

  @override
  Future<List<AppUpdateInfo>> list() async {
    calls.add('list');
    return _updates;
  }

  @override
  Future<AppUpdateInfo?> checkApp(String appId, {String? channelCode}) async {
    calls.add('checkApp:$appId');
    return _updates.firstWhere((update) => update.appId == appId,
        orElse: () => _updates.first);
  }

  @override
  Future<bool> markUpdated(String appId) async {
    calls.add('markUpdated:$appId');
    return true;
  }

  @override
  Future<bool> hasUpdate(String appId) async {
    calls.add('hasUpdate:$appId');
    return _updates.any((update) => update.appId == appId);
  }

  @override
  Future<int> count() async {
    calls.add('count');
    return _updates.length;
  }

  @override
  Future<bool> cacheValid() async {
    calls.add('cacheValid');
    return false;
  }
}

/// Core-lane fake that throws a raw core error, exactly like a rejected FRB
/// call carrying a typed Rust message.
class _ThrowingCoreBackend extends _RecordingCoreBackend {
  _ThrowingCoreBackend(this.error) : super(const <Map<String, dynamic>>[]);

  final String error;

  Never _fail() => throw Exception(error);

  @override
  Future<List<AppUpdateInfo>> check({required bool force}) async => _fail();

  @override
  Future<List<AppUpdateInfo>> run() async => _fail();
}

/// Runs one page check through the real notifier (the UI entry point) and
/// returns the resulting state. The facade state mirror is the bound manager.
Future<UpdateState> _runNotifierCheck(UpdateManagerService manager) async {
  ModuleManager.instance.bind<UpdateManagerService>(manager);
  ModuleManager.instance.bind<BadgeService>(BadgeService());
  final notifier = UpdateNotifier();
  final container = ProviderContainer(overrides: <Override>[
    updateProvider.overrideWith(() => notifier),
  ]);
  final sub = container.listen(updateProvider, (_, __) {});
  await Future<void>.delayed(Duration.zero);
  await notifier.checkUpdates();
  await Future<void>.delayed(Duration.zero);
  final state = container.read(updateProvider);
  sub.close();
  container.dispose();
  return state;
}

Map<String, Object?> _canonicalFromPrefs(SharedPreferences prefs) {
  final results =
      jsonDecode(prefs.getString('update_results_v1') ?? '[]') as List<dynamic>;
  final logs =
      jsonDecode(prefs.getString('update_check_logs_v1') ?? '[]') as List<dynamic>;
  final preferred =
      jsonDecode(prefs.getString('update_preferred_apk') ?? 'null');
  return <String, Object?>{
    'candidates': results,
    'installedVersions': <String, Object?>{
      for (final item in results)
        (item as Map<String, dynamic>)['appId']: item['installedVersion'],
    },
    'latestVersions': <String, Object?>{
      for (final item in results)
        (item as Map<String, dynamic>)['appId']: item['latestVersion'],
    },
    'update_last_checked_at': prefs.getInt('update_last_checked_at'),
    'update_results_v1': results,
    'update_check_logs_v1': logs,
    'update_preferred_apk': preferred,
  };
}

Map<String, Object?> _canonicalFromManager(
  UpdateManagerService manager,
  SharedPreferences prefs,
) {
  final results = <Map<String, dynamic>>[
    for (final update in manager.updateList) update.toCacheJson(),
  ];
  final logs = <Map<String, dynamic>>[
    for (final entry in manager.checkLog) entry.toJson(),
  ];
  final preferred = jsonDecode(prefs.getString('update_preferred_apk') ?? 'null');
  return <String, Object?>{
    'candidates': results,
    'installedVersions': <String, Object?>{
      for (final item in results) item['appId']: item['installedVersion'],
    },
    'latestVersions': <String, Object?>{
      for (final item in results) item['appId']: item['latestVersion'],
    },
    'update_last_checked_at': manager.lastCheckedAt?.millisecondsSinceEpoch,
    'update_results_v1': results,
    'update_check_logs_v1': logs,
    'update_preferred_apk': preferred,
  };
}

/// Parity diff: an empty list means the two lanes are identical. The test also
/// proves the diff is not vacuous by feeding it a deliberate divergence.
List<String> _canonicalDiff(
  Map<String, Object?> legacy,
  Map<String, Object?> facade,
) {
  final keys = <String>{...legacy.keys, ...facade.keys};
  final diff = <String>[];
  for (final key in keys) {
    if (jsonEncode(legacy[key]) != jsonEncode(facade[key])) diff.add(key);
  }
  return diff;
}

const Set<String> _legacyManagerAllowlist = <String>{
  // The legacy service definition itself.
  'lib/core/update/update_manager.dart',
  // The facade owns the only remaining calls: the legacy backend
  // (`update_backends.dart`) and the shared reactive state mirror
  // (`update_facade.dart`). No production caller may touch it directly.
  'lib/core/update/update_backends.dart',
  'lib/core/update/update_facade.dart',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CoreBootstrap.reset();
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    UpdateFacade.backendOverride = null;
    UpdateFacade.legacyBackendOverride = null;
    CoreBootstrap.reset();
    await ModuleManager.instance.clear();
  });

  test('update_cutover_parity_diff_empty', () async {
    // ---- legacy lane: flag off, legacy service writes the canonical state ----
    CoreFlags.installBackend(_FakeFlagsBackend(const CoreFlagsSnapshot()));
    await CoreFlags.refresh();
    UpdateFacade.backendOverride = null;

    final legacyManager =
        _FixtureUpdateManager(updates: _legacyUpdates());
    legacyManager.debugSetState(lastCheckedAt: _checkedAt);
    await UpdateCache.savePreferredApk(
        'github', 'owner/alpha', 'alpha-arm64-v8a.apk');
    await _runNotifierCheck(legacyManager);

    final legacyPrefs = await SharedPreferences.getInstance();
    final legacyCanonical = _canonicalFromPrefs(legacyPrefs);

    // Non-empty on BOTH sides: empty-vs-empty is a false pass.
    expect(legacyCanonical['candidates'], hasLength(2),
        reason: 'legacy fixture must produce candidates');
    expect(legacyCanonical['installedVersions'],
        <String, Object?>{'owner/alpha': '1.0.0', 'owner/beta': '3.1.0'});
    expect(legacyCanonical['latestVersions'],
        <String, Object?>{'owner/alpha': '2.0.0', 'owner/beta': '4.0.0'});
    expect((legacyCanonical['update_check_logs_v1'] as List<dynamic>).length,
        greaterThanOrEqualTo(3));
    for (final key in const <String>[
      'update_last_checked_at',
      'update_results_v1',
      'update_check_logs_v1',
      'update_preferred_apk',
    ]) {
      expect(legacyPrefs.get(key), isNotNull, reason: '$key must be written');
    }
    expect(legacyCanonical['update_last_checked_at'], _checkedAtMillis);
    expect(legacyCanonical['update_preferred_apk'],
        <String, dynamic>{'github:owner/alpha': 'alpha-arm64-v8a.apk'});

    // ---- reset the cached adapters/prefs between the two halves ----
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final resetPrefs = await SharedPreferences.getInstance();
    expect(resetPrefs.getString('update_results_v1'), isNull,
        reason: 'stale legacy cache must not leak into the core half');

    // ---- facade/core lane: flag on, core backend drives the same state ----
    CoreFlags.resetBackend();
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(catalog: true, update: true)),
    );
    await CoreFlags.refresh();

    await UpdateCache.savePreferredApk(
        'github', 'owner/alpha', 'alpha-arm64-v8a.apk');
    final coreBackend = _RecordingCoreBackend(_coreUpdatesJson());
    UpdateFacade.backendOverride = coreBackend;

    final coreManager = _FixtureUpdateManager();
    coreManager.debugSetState(lastCheckedAt: _checkedAt);
    final coreState = await _runNotifierCheck(coreManager);

    // The facade path is REAL: the core backend was consulted and the legacy
    // engine was not. A fake that never runs cannot fake parity.
    expect(coreBackend.calls, isNotEmpty,
        reason: 'flag on + facade path must consult the core backend');
    expect(coreManager.checkCount, 0,
        reason: 'flag on must not run the legacy check engine');
    expect(coreState.updateList, hasLength(2),
        reason: 'the facade must mirror the core result into the shared state');

    final corePrefs = await SharedPreferences.getInstance();
    final coreCanonical = _canonicalFromManager(coreManager, corePrefs);

    expect(coreCanonical['candidates'], hasLength(2),
        reason: 'core fixture must produce candidates');
    expect(
      (coreCanonical['update_check_logs_v1'] as List<dynamic>).length,
      greaterThanOrEqualTo(3),
      reason: 'the facade must derive non-empty check logs',
    );
    // The same four prefs contracts hold on the mirrored core side.
    expect(coreCanonical['update_last_checked_at'], _checkedAtMillis);
    expect(coreCanonical['update_results_v1'], hasLength(2));
    expect(coreCanonical['update_preferred_apk'],
        <String, dynamic>{'github:owner/alpha': 'alpha-arm64-v8a.apk'});

    final diff = _canonicalDiff(legacyCanonical, coreCanonical);
    expect(diff, isEmpty, reason: 'update parity diverged: $diff');

    // ---- adversarial: a deliberate divergence must FAIL the diff ----
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await UpdateCache.savePreferredApk(
        'github', 'owner/alpha', 'alpha-arm64-v8a.apk');
    UpdateFacade.backendOverride =
        _RecordingCoreBackend(_coreUpdatesJson(alphaLatest: '9.9.9'));
    final divergedManager = _FixtureUpdateManager();
    divergedManager.debugSetState(lastCheckedAt: _checkedAt);
    await _runNotifierCheck(divergedManager);
    final divergedPrefs = await SharedPreferences.getInstance();
    final divergedCanonical =
        _canonicalFromManager(divergedManager, divergedPrefs);

    final divergedDiff = _canonicalDiff(legacyCanonical, divergedCanonical);
    expect(divergedDiff, isNotEmpty,
        reason: 'the parity diff must detect a real divergence');
    expect(divergedDiff, contains('latestVersions'));
  });

  test('update_cutover_runs_after_bootstrap_facts_and_inventory', () async {
    // Startup order: main awaits the bootstrap (facts then inventory) before
    // any module init can trigger an update check.
    final mainSource = File('lib/main.dart').readAsStringSync();
    final bootstrapAt = mainSource.indexOf('await CoreBootstrap.start();');
    final registerAt = mainSource.indexOf('await registerService();');
    expect(bootstrapAt, greaterThanOrEqualTo(0));
    expect(registerAt, greaterThanOrEqualTo(0));
    expect(bootstrapAt, lessThan(registerAt),
        reason: 'CoreBootstrap must run before registerService (module init)');

    final bootstrapSource =
        File('lib/core/rust/core_bootstrap.dart').readAsStringSync();
    final factsAt = bootstrapSource.indexOf('await backend.pushPlatformFacts(');
    final inventoryAt = bootstrapSource.indexOf('await backend.pushInventory(');
    expect(factsAt, greaterThanOrEqualTo(0));
    expect(inventoryAt, greaterThanOrEqualTo(0));
    expect(factsAt, lessThan(inventoryAt),
        reason: 'facts must be pushed before the inventory snapshot');

    // And the update cutover refuses to run before the bootstrap completed:
    // a missing push is a typed CORE_E_FACTS_MISSING, never a silent fallback.
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(catalog: true, update: true)),
    );
    await CoreFlags.refresh();
    expect(CoreBootstrap.ready, isFalse);

    final legacyManager = _FixtureUpdateManager(updates: _legacyUpdates());
    legacyManager.debugSetState(lastCheckedAt: _checkedAt);
    final state = await _runNotifierCheck(legacyManager);

    expect(state.errorMessage, contains('CORE_E_FACTS_MISSING'),
        reason: 'pre-bootstrap update checks must surface the typed code');
    expect(legacyManager.checkCount, 0,
        reason: 'a missing bootstrap push must not silently fall back');
  });

  test('update_cutover_requires_catalog_authoritative', () async {
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(update: true)),
    );
    await CoreFlags.refresh();

    final legacyManager = _FixtureUpdateManager(updates: _legacyUpdates());
    legacyManager.debugSetState(lastCheckedAt: _checkedAt);
    final state = await _runNotifierCheck(legacyManager);

    expect(state.errorMessage, contains('CORE_E_UPDATE_CUTOVER_ORDER'),
        reason: 'update must not cut over before catalog is authoritative');
    expect(legacyManager.checkCount, 0,
        reason: 'an out-of-order cutover must not silently fall back');
  });

  test('update_core_errors_are_typed_and_reach_the_ui', () async {
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(catalog: true, update: true)),
    );
    await CoreFlags.refresh();
    UpdateFacade.backendOverride = _ThrowingCoreBackend(
      'Unsupported: CORE_E_INVENTORY_STALE: source android is older than 86400s',
    );

    final legacyManager = _FixtureUpdateManager(updates: _legacyUpdates());
    legacyManager.debugSetState(lastCheckedAt: _checkedAt);
    final state = await _runNotifierCheck(legacyManager);

    expect(state.errorMessage, contains('CORE_E_INVENTORY_STALE'),
        reason: 'the raw FRB error must become a typed UI error');
    expect(legacyManager.checkCount, 0,
        reason: 'a typed core rejection must not fall back to the legacy lane');
  });

  test('update_callers_use_the_facade', () async {
    // Grep gate: no production construction/call of the legacy service outside
    // its own definition and the facade's legacy backend.
    final offenders = <String>[];
    final references = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (!entity.readAsStringSync().contains('UpdateManagerService')) continue;
      references.add(entity.path);
      if (_legacyManagerAllowlist.contains(entity.path)) continue;
      offenders.add(entity.path);
    }
    expect(references, isNotEmpty);
    expect(offenders, isEmpty,
        reason: 'unexpected UpdateManagerService references: $offenders');

    // Positive: every migrated caller is a real facade caller.
    for (final path in const <String>[
      'lib/page/update/logic.dart',
      'lib/page/update/view.dart',
      'lib/page/home/tab/applist/logic.dart',
      'lib/core/service/badge_service.dart',
      'lib/core/agent/agent_service.dart',
      'lib/core/module/app_modules.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('UpdateManagerService')),
          reason: '$path must not reference the legacy service');
      expect(source, contains('UpdateFacade'),
          reason: '$path must go through the facade');
    }
  });
}

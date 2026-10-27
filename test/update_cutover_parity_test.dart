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

// ---------------------------------------------------------------------------
// Committed fixtures (shared with rust/gstore_core/tests/update_parity_golden.rs)
// ---------------------------------------------------------------------------
//
// `update_parity_input.json` is INPUT ONLY: the handcrafted channel payloads /
// installed versions / preferred APK the Rust fixture generator consumes. It is
// never compared against anything as an expectation.
//
// `update_parity_golden.json` is REAL core output: it is produced by running
// the production Rust `UpdateService` over the committed SQLite fixture
// (`update_parity_input.db`). It is the authoritative core expectation here.
const String _fixturesDir = 'rust/gstore_core/tests/fixtures';

String _inputPath() => '$_fixturesDir/update_parity_input.json';

/// Test-only override so a mutated /tmp golden copy can be proven to fail; the
/// committed golden is never modified in that mode.
String _goldenPath() =>
    Platform.environment['GSTORE_UPDATE_PARITY_GOLDEN'] ??
    '$_fixturesDir/update_parity_golden.json';

Map<String, dynamic> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _inputFixture() => _readJson(_inputPath());
Map<String, dynamic> _golden() => _readJson(_goldenPath());
Map<String, dynamic> _goldenCanonical() =>
    (_golden()['canonical'] as Map).cast<String, dynamic>();
Map<String, dynamic> _goldenReport() =>
    (_golden()['report'] as Map).cast<String, dynamic>();

int get _checkedAtMillis => (_inputFixture()['checkedAt'] as num).toInt();
DateTime get _checkedAt => DateTime.fromMillisecondsSinceEpoch(_checkedAtMillis);

/// Builds the legacy lane's input from the SAME committed INPUT fixture the
/// Rust generator consumes, ordered exactly like `AddedAppsService::list`
/// (`add_time DESC`) so the two lanes are fed identical data.
List<AppUpdateInfo> _legacyUpdates() {
  final input = _inputFixture();
  final added = <Map<String, dynamic>>[
    ...(input['added'] as List).cast<Map<String, dynamic>>(),
  ]..sort((a, b) => (b['addTime'] as int).compareTo(a['addTime'] as int));
  final channels = <String, Map<String, dynamic>>{
    for (final channel
        in (input['channels'] as List).cast<Map<String, dynamic>>())
      channel['code'] as String: channel,
  };
  return <AppUpdateInfo>[
    for (final entry in added)
      _legacyUpdate(
        channelId: entry['channelId'] as String,
        update: (channels[entry['channelId']]!['updates'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((update) => update['appId'] == entry['appId']),
      ),
  ];
}

AppUpdateInfo _legacyUpdate({
  required String channelId,
  required Map<String, dynamic> update,
}) {
  final download = update['download'] as Map<String, dynamic>;
  return AppUpdateInfo(
    channelId: channelId,
    appId: update['appId'] as String,
    appName: update['appName'] as String,
    iconUrl: update['iconUrl'] as String?,
    packageName: update['packageName'] as String,
    installedVersion: _installedVersionFor(update['packageName'] as String),
    latestVersion: update['latestVersion'] as String,
    checkedAt: _checkedAt,
    latestDownload: DownloadInfo(
      url: download['url'] as String,
      name: download['name'] as String,
      size: download['size'] as int?,
      downloadCount: download['downloadCount'] as int?,
      version: download['version'] as String?,
      versionCode: download['versionCode'] as int?,
      publishedAt: download['publishedAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(download['publishedAt'] as int),
      platform: download['platform'] as String?,
      hash: download['hash'] as String?,
      hashType: download['hashType'] as String?,
    ),
  );
}

String _installedVersionFor(String packageName) {
  for (final app
      in (_inputFixture()['installed'] as List).cast<Map<String, dynamic>>()) {
    if (app['packageName'] == packageName) {
      return app['versionName'] as String;
    }
  }
  throw StateError('no installed version for $packageName');
}

/// Seeds the user preference fixture the golden covers.
Future<void> _seedPreferredApk() async {
  final preferred =
      (_inputFixture()['preferredApk'] as Map).cast<String, String>();
  for (final entry in preferred.entries) {
    final parts = entry.key.split(':');
    await UpdateCache.savePreferredApk(parts[0], parts[1], entry.value);
  }
}

/// A report-backed core fake: replays the committed golden candidates and hands
/// the production facade a real [CoreCheckReport], so the `lastReport` branch
/// (and therefore `deriveCoreCheckLogs`) is exercised, not bypassed.
_ReportCoreBackend _goldenCoreBackend({
  List<Map<String, dynamic>>? candidates,
  CoreCheckReport? report,
}) {
  final json = candidates ??
      (_goldenCanonical()['candidates'] as List).cast<Map<String, dynamic>>();
  final reportJson = _goldenReport();
  final decoded = decodeUpdateList(jsonEncode(json));
  return _ReportCoreBackend(
    updatesJson: json,
    report: report ??
        CoreCheckReport(
          updates: decoded,
          skipped: <UpdateSkip>[
            for (final skip
                in (reportJson['skipped'] as List).cast<Map<String, dynamic>>())
              UpdateSkip.fromJson(skip),
          ],
          checkedAt: DateTime.fromMillisecondsSinceEpoch(
            (reportJson['checkedAt'] as num).toInt(),
          ),
          total: (reportJson['total'] as num).toInt(),
          usedCache: reportJson['usedCache'] as bool,
        ),
  );
}

/// Fixture lane: reproduces the deleted Dart engine's canonical state +
/// persistence (the same four prefs keys) without touching channels.
///
/// The engine and its `UpdateCache` writers were removed in this increment, so
/// the fixture reproduces the four-key output directly. The parity diff below
/// therefore still compares a legacy-shaped canonical document against the real
/// Rust golden.
///
/// [checkCount] is FIXTURE INSTRUMENTATION, not a production counter. It exists
/// only so this test can prove the fixture lane ran (or did not).
class _FixtureUpdateManager extends UpdateManagerService {
  _FixtureUpdateManager({List<AppUpdateInfo>? updates})
      : _fixture = updates ?? const <AppUpdateInfo>[];

  final List<AppUpdateInfo> _fixture;

  /// Fixture instrumentation: number of times this fixture lane ran.
  int checkCount = 0;

  /// Replays the deleted engine's canonical state + four-key persistence.
  Future<void> runFixtureCheck() async {
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
    // The real manager persisted these keys; the fixture writes them directly
    // (its writer helpers were removed with the engine). Parity is defined on
    // these four keys.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      'update_last_checked_at',
      _checkedAt.millisecondsSinceEpoch,
    );
    await prefs.setString(
      'update_results_v1',
      jsonEncode(<Map<String, dynamic>>[
        for (final update in _fixture) update.toCacheJson(),
      ]),
    );
    await prefs.setString(
      'update_check_logs_v1',
      jsonEncode(<Map<String, dynamic>>[
        for (final entry in logs) entry.toJson(),
      ]),
    );
  }
}

/// Core-lane fake: only the existing `UpdateBackend.check` contract is used, so
/// the production facade path is what gets exercised. The golden is the source
/// of truth for [updatesJson]; `lastReport` supplies the production report.
class _RecordingCoreBackend extends UpdateBackend {
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

/// Core fake that additionally carries a real [CoreCheckReport] through the
/// `UpdateBackend.lastReport` seam (production: `FrbUpdateBackend`).
class _ReportCoreBackend extends _RecordingCoreBackend
    implements UpdateReportSource {
  _ReportCoreBackend({
    required List<Map<String, dynamic>> updatesJson,
    required this.report,
  }) : super(updatesJson);

  final CoreCheckReport? report;

  @override
  CoreCheckReport? get lastReport => report;
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
  // The state-holder definition itself.
  'lib/core/update/update_manager.dart',
  // The facade owns the shared reactive state mirror (`update_facade.dart`).
  // No production caller may touch it directly.
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
    CoreBootstrap.reset();
    await ModuleManager.instance.clear();
  });

  test('update_cutover_parity_diff_empty', () async {
    final goldenCanonical = _goldenCanonical();

    // ---- fixture lane: the deleted engine's canonical output, simulated ----
    CoreFlags.installBackend(_FakeFlagsBackend(const CoreFlagsSnapshot()));
    await CoreFlags.refresh();
    UpdateFacade.backendOverride = null;

    final legacyManager = _FixtureUpdateManager(updates: _legacyUpdates());
    legacyManager.debugSetState(lastCheckedAt: _checkedAt);
    await _seedPreferredApk();
    await legacyManager.runFixtureCheck();

    // Positive control: the fixture lane really ran (not a dead counter).
    expect(legacyManager.checkCount, 1,
        reason: 'positive control: the fixture lane must run once');

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

    await _seedPreferredApk();
    final coreBackend = _goldenCoreBackend();
    UpdateFacade.backendOverride = coreBackend;

    final coreManager = _FixtureUpdateManager();
    coreManager.debugSetState(lastCheckedAt: _checkedAt);
    final coreState = await _runNotifierCheck(coreManager);

    // The facade path is REAL: the core backend was consulted. A fake that
    // never runs cannot fake parity.
    expect(coreBackend.calls, isNotEmpty,
        reason: 'flag on + facade path must consult the core backend');
    expect(coreManager.checkCount, 0,
        reason: 'fixture instrumentation: the fixture lane must not run here');
    expect(coreState.updateList, hasLength(2),
        reason: 'the facade must mirror the core report into the shared state');

    final corePrefs = await SharedPreferences.getInstance();
    final coreCanonical = _canonicalFromManager(coreManager, corePrefs);

    expect(coreCanonical['candidates'], hasLength(2),
        reason: 'core golden must produce candidates');
    expect(
      (coreCanonical['update_check_logs_v1'] as List<dynamic>).length,
      greaterThanOrEqualTo(3),
      reason: 'the facade must derive non-empty check logs from the report',
    );
    // The same four prefs contracts hold on the mirrored core side.
    expect(coreCanonical['update_last_checked_at'], _checkedAtMillis);
    expect(coreCanonical['update_results_v1'], hasLength(2));
    expect(coreCanonical['update_preferred_apk'],
        <String, dynamic>{'github:owner/alpha': 'alpha-arm64-v8a.apk'});

    // ---- legacy == golden == real Rust; core report replay == golden ----
    expect(legacyCanonical, goldenCanonical,
        reason: 'legacy lane diverged from the real Rust golden');
    expect(coreCanonical, goldenCanonical,
        reason: 'core lane diverged from the real Rust golden');
    expect(_canonicalDiff(legacyCanonical, coreCanonical), isEmpty,
        reason: 'update parity diverged');

    // ---- adversarial: a deliberate divergence must FAIL the diff ----
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _seedPreferredApk();
    final divergedCandidates = <Map<String, dynamic>>[
      for (final item in (goldenCanonical['candidates'] as List)
          .cast<Map<String, dynamic>>())
        Map<String, dynamic>.from(item),
    ];
    divergedCandidates.first['latestVersion'] = '9.9.9';
    UpdateFacade.backendOverride =
        _goldenCoreBackend(candidates: divergedCandidates);
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

  test('update_facade_uses_the_backend_report_branch', () async {
    // The production `lastReport` branch must be driven by the report itself,
    // not by a concrete backend type check. `usedCache` and `checkedAt` can
    // only come from the report, so an `_adopt` fallback cannot fake them.
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(catalog: true, update: true)),
    );
    await CoreFlags.refresh();

    final reportAt = _checkedAtMillis + 4242;
    final candidates =
        (_goldenCanonical()['candidates'] as List).cast<Map<String, dynamic>>();
    final updates = decodeUpdateList(jsonEncode(candidates));
    final backend = _ReportCoreBackend(
      updatesJson: candidates,
      report: CoreCheckReport(
        updates: updates,
        skipped: const <UpdateSkip>[],
        checkedAt: DateTime.fromMillisecondsSinceEpoch(reportAt),
        total: updates.length,
        usedCache: true,
      ),
    );
    UpdateFacade.backendOverride = backend;

    final manager = _FixtureUpdateManager();
    final state = await _runNotifierCheck(manager);

    expect(manager.lastCheckedAt, DateTime.fromMillisecondsSinceEpoch(reportAt),
        reason: 'the facade must take checkedAt from the report branch');
    expect(manager.checkLog, hasLength(1),
        reason: 'usedCache reports render the single cache line');
    expect(manager.checkLog.single.text, contains('使用缓存结果'));
    expect(state.updateList, hasLength(2));
  });

  test('fixture_check_count_probe_is_falsifiable', () async {
    // Committed positive control for the D1 probe: it fires when the fixture
    // lane runs and stays zero when nothing ran.
    final called = _FixtureUpdateManager(updates: _legacyUpdates());
    await called.runFixtureCheck();
    expect(called.checkCount, 1,
        reason: 'the fixture probe must fire when the fixture lane runs');
    final notCalled = _FixtureUpdateManager(updates: _legacyUpdates());
    expect(notCalled.checkCount, 0,
        reason: 'the fixture probe stays zero when nothing ran');
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
        reason:
            'fixture instrumentation: a missing bootstrap push must not silently fall back');
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
        reason:
            'fixture instrumentation: an out-of-order cutover must not silently fall back');
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
        reason:
            'fixture instrumentation: a typed core rejection must not fall back to the legacy lane');
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

// Todo 23: config migration is wired into the awaited boot sequence.
//
// Production boot (lib/main.dart):
//   CoreBootstrap.start() (core ready)
//   -> ConfigMigrationTool.run() with AppDialogs progress (skipped when the
//      navigator context is unavailable, migration still runs)
//   -> ConfigInitializer.initialize() (ConfigStore backend + ConfigApi.list)
//   -> CoreBootstrap.runDeferredMigrations() (local_db -> gstore)
//   -> _startBatteryHistoryRecorderIfEnabled()
//   -> registerService()
//
// The tests drive `runBootConfigPhase` through its injected seams, so they
// assert the real ordering without touching FFI / platform channels.

import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/migration/config_migration_tool.dart';
import 'package:gstore/core/config/rust/config_api.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/module/module_toggle_config.dart';
import 'package:gstore/core/rust/generated/config_api.dart' as generated;
import 'package:gstore/main.dart' as app;

generated.ConfigEntryDto _boolEntry(String module, String key, bool value) {
  return generated.ConfigEntryDto(
    module: module,
    key: key,
    wireKey: '$module.$key',
    valueType: 'bool',
    valueJson: 'null',
    masked: false,
    revision: BigInt.zero,
    sensitive: false,
    agentAccessible: true,
    visibility: 'owner',
    defaultJson: '$value',
    descriptionZh: '$module.$key',
    descriptionEn: '$module.$key',
    category: module,
    enumValues: const <String>[],
  );
}

/// Records when ConfigApi becomes ready and answers toggle reads.
class _OrderProbeClient implements ConfigApiClient {
  _OrderProbeClient(this.order);

  final List<String> order;

  @override
  Future<List<generated.ConfigEntryDto>> list({String? module}) async {
    order.add('config-api-ready');
    return <generated.ConfigEntryDto>[
      _boolEntry('module', 'channel.enabled', true),
    ];
  }

  @override
  Future<String> get({
    required String module,
    required String key,
    required bool masked,
  }) async =>
      'true';

  @override
  Stream<generated.ConfigChangeDto> watch({
    required String module,
    String? key,
  }) =>
      const Stream<generated.ConfigChangeDto>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory legacy snapshot for the real [ConfigMigrationTool] retry test.
class _MapLegacySource implements LegacyConfigSource {
  _MapLegacySource(this.prefs);

  final Map<String, Object?> prefs;

  @override
  Future<Map<String, Object?>> readPrefs() async => prefs;

  @override
  Future<Map<String, String?>> readSecure() async => const <String, String?>{};
}

/// In-memory [ConfigMigrationApi]; optionally throws on the first import so the
/// marker stays absent and the next launch retries.
class _FlakyMigrationApi implements ConfigMigrationApi {
  _FlakyMigrationApi({this.failFirstImport = false});

  final bool failFirstImport;
  int importAttempts = 0;
  String? marker;

  @override
  Future<MigrationImportResult> importEntries(
    List<MigrationEntry> entries, {
    required String source,
  }) async {
    importAttempts++;
    if (failFirstImport && importAttempts == 1) {
      throw StateError('simulated import failure');
    }
    return MigrationImportResult(
      total: entries.length,
      applied: entries.length,
      eventsPublished: entries.length,
    );
  }

  @override
  Future<MigrationVerifyResult> verifyEntries(
    List<MigrationEntry> entries,
  ) async =>
      MigrationVerifyResult(total: entries.length, matched: entries.length);

  @override
  Future<String?> getMeta(String key) async => marker;

  @override
  Future<void> setMeta(String key, String valueJson) async {
    marker = valueJson;
  }
}

app.BootConfigPhaseSeams _noopSeams({
  required List<String> order,
  Future<ConfigMigrationReport> Function(
    ConfigMigrationProgress? onProgress,
  )? migrateConfig,
}) {
  return app.BootConfigPhaseSeams(
    startCore: () async => order.add('core-start'),
    migrateConfig: migrateConfig ??
        (onProgress) async {
          order.add('migration-start');
          onProgress?.call(1, 1);
          order.add('migration-end');
          return const ConfigMigrationReport(coreReady: true);
        },
    initializeConfig: () async => order.add('config-init'),
    runDeferredMigrations: () async => order.add('deferred-migrations'),
    startBatteryHistory: () async => order.add('battery-recorder'),
    navigatorReady: () async => false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    ConfigInitializer.debugReset();
    ConfigStore.instance.resetForTest();
    await ModuleManager.instance.clear();
  });

  tearDown(() {
    ConfigInitializer.debugReset();
    ConfigStore.instance.resetForTest();
  });

  test('boot order: core -> config migration -> config init -> module toggles',
      () async {
    final order = <String>[];
    final client = _OrderProbeClient(order);

    ConfigInitializer.debugSetSteps(
      initializeStore: () async {
        await ConfigStore.instance.initialize(storages: <ConfigStorage>[
          MemoryConfigStorage(),
          MemoryConfigStorage(),
        ]);
        ConfigService.instance.debugSetApi(ConfigRustApi(client));
        order.add('config-store-init');
      },
      // Production ensureServiceReady (ConfigApi.list hydration).
    );

    await app.runBootConfigPhase(
      seams: app.BootConfigPhaseSeams(
        startCore: () async => order.add('core-start'),
        migrateConfig: (onProgress) async {
          order.add('migration-start');
          onProgress?.call(1, 1);
          order.add('migration-end');
          return const ConfigMigrationReport(coreReady: true);
        },
        // Production ConfigInitializer.initialize().
        runDeferredMigrations: () async => order.add('deferred-migrations'),
        startBatteryHistory: () async => order.add('battery-recorder'),
        navigatorReady: () async => false,
      ),
    );
    order.add('module-toggles-start');
    await ModuleToggleConfig.preApplyToggles(ModuleManager.instance);
    order.add('module-toggles-end');

    expect(order.first, 'core-start');
    expect(
      order.indexOf('core-start'),
      lessThan(order.indexOf('migration-start')),
    );
    expect(
      order.indexOf('migration-end'),
      lessThan(order.indexOf('config-store-init')),
      reason: 'legacy config must be imported before ConfigStore is wired',
    );
    expect(
      order.indexOf('config-store-init'),
      lessThan(order.indexOf('config-api-ready')),
      reason: 'ConfigStore.initialize must precede ConfigApi.list',
    );
    expect(
      order.indexOf('config-api-ready'),
      lessThan(order.indexOf('deferred-migrations')),
      reason: 'local-db migration runs after config init',
    );
    expect(
      order.indexOf('deferred-migrations'),
      lessThan(order.indexOf('battery-recorder')),
      reason: 'battery gate reads config after init',
    );
    expect(
      order.indexOf('config-api-ready'),
      lessThan(order.indexOf('module-toggles-start')),
      reason: 'module toggles read config after init',
    );
    expect(order.last, 'module-toggles-end');
  });

  test('ConfigStore.initialize / ConfigApi.list never run before core start',
      () async {
    final order = <String>[];

    ConfigInitializer.debugSetSteps(
      initializeStore: () async {
        await ConfigStore.instance.initialize(storages: <ConfigStorage>[
          MemoryConfigStorage(),
          MemoryConfigStorage(),
        ]);
        order.add('config-store-init');
      },
      ensureServiceReady: () async => order.add('config-api-init'),
    );

    await app.runBootConfigPhase(
      seams: app.BootConfigPhaseSeams(
        startCore: () async {
          order.add('core-start');
          // Core is the first thing the phase touches.
          expect(order, <String>['core-start']);
        },
        migrateConfig: (onProgress) async {
          order.add('migration');
          // No config/FFI access has happened yet.
          expect(order.contains('config-store-init'), isFalse);
          expect(order.contains('config-api-init'), isFalse);
          return const ConfigMigrationReport(coreReady: true);
        },
        // Production ConfigInitializer.initialize().
        runDeferredMigrations: () async => order.add('deferred-migrations'),
        startBatteryHistory: () async => order.add('battery-recorder'),
        navigatorReady: () async => false,
      ),
    );

    expect(order.indexOf('core-start'), 0);
    expect(
      order.indexOf('core-start'),
      lessThan(order.indexOf('config-store-init')),
    );
    expect(
      order.indexOf('migration'),
      lessThan(order.indexOf('config-store-init')),
    );
    expect(
      order.indexOf('config-store-init'),
      lessThan(order.indexOf('config-api-init')),
    );
  });

  test('migration failure leaves startup usable (later steps still run)',
      () async {
    final order = <String>[];

    await app.runBootConfigPhase(
      seams: _noopSeams(
        order: order,
        migrateConfig: (onProgress) async {
          order.add('migration-start');
          throw StateError('simulated migration failure');
        },
      ),
    );

    expect(order, <String>[
      'core-start',
      'migration-start',
      'config-init',
      'deferred-migrations',
      'battery-recorder',
    ]);
  });

  test('failed migration writes no marker; the next launch retries', () async {
    final api = _FlakyMigrationApi(failFirstImport: true);
    final source = _MapLegacySource(<String, Object?>{
      'config_download_max_concurrent': 4,
    });

    final first = await ConfigMigrationTool.run(api: api, source: source);
    expect(first.errorCode, 'migration_failed');
    expect(first.markerWritten, isFalse);
    expect(api.marker, isNull);

    final second = await ConfigMigrationTool.run(api: api, source: source);
    expect(second.markerWritten, isTrue);
    expect(second.failed, 0);
    expect(api.marker, isNotNull);
  });

  test('progress sheet is skipped gracefully when navigator is unavailable',
      () async {
    final order = <String>[];

    await app.runBootConfigPhase(
      seams: app.BootConfigPhaseSeams(
        startCore: () async => order.add('core-start'),
        migrateConfig: (onProgress) async {
          order.add('migration');
          onProgress?.call(1, 2);
          order.add('migration-done');
          return const ConfigMigrationReport(coreReady: true);
        },
        initializeConfig: () async => order.add('config-init'),
        runDeferredMigrations: () async => order.add('deferred-migrations'),
        startBatteryHistory: () async => order.add('battery-recorder'),
        navigatorReady: () async => false,
        showMigrationProgress: (_) => order.add('sheet-shown'),
        dismissMigrationProgress: () => order.add('sheet-dismissed'),
      ),
    );

    expect(order.contains('sheet-shown'), isFalse);
    expect(order.contains('sheet-dismissed'), isFalse);
    expect(order.contains('migration'), isTrue);
    expect(order.contains('migration-done'), isTrue);
    expect(order.last, 'battery-recorder');
  });

  test('progress sheet is shown and forwards done/total when navigator ready',
      () async {
    ValueNotifier<app.BootMigrationProgress>? notifier;
    final observed = <app.BootMigrationProgress>[];

    await app.runBootConfigPhase(
      seams: app.BootConfigPhaseSeams(
        startCore: () async {},
        migrateConfig: (onProgress) async {
          onProgress?.call(1, 4);
          observed.add(notifier!.value);
          onProgress?.call(4, 4);
          observed.add(notifier!.value);
          return const ConfigMigrationReport(coreReady: true);
        },
        initializeConfig: () async {},
        runDeferredMigrations: () async {},
        startBatteryHistory: () async {},
        navigatorReady: () async => true,
        showMigrationProgress: (progress) {
          notifier = progress;
          observed.add(progress.value);
        },
        dismissMigrationProgress: () => observed.add((
          done: -1,
          total: -1,
          message: 'dismissed',
        )),
      ),
    );

    expect(observed.first, (
      done: 0,
      total: 0,
      message: '正在迁移配置数据…',
    ));
    expect(observed[1].done, 1);
    expect(observed[1].total, 4);
    expect(observed[2].done, 4);
    expect(observed[2].total, 4);
    expect(observed.last.message, 'dismissed');
  });

  test(
      'navigator ready with NO show seam uses the real named-arg wrapper '
      'and completes every boot step', () async {
    final order = <String>[];

    await app.runBootConfigPhase(
      seams: app.BootConfigPhaseSeams(
        startCore: () async => order.add('core-start'),
        migrateConfig: (onProgress) async {
          order.add('migration');
          onProgress?.call(1, 1);
          return const ConfigMigrationReport(coreReady: true);
        },
        initializeConfig: () async => order.add('config-init'),
        runDeferredMigrations: () async => order.add('deferred-migrations'),
        startBatteryHistory: () async => order.add('battery-recorder'),
        // Navigator reported ready, but no show/dismiss seam injected: this
        // must exercise the production AppDialogs.showProgress wrapper.
        navigatorReady: () async => true,
      ),
    );

    expect(order, <String>[
      'core-start',
      'migration',
      'config-init',
      'deferred-migrations',
      'battery-recorder',
    ]);
  });

  test('a throwing show-progress seam cannot abort the boot phase', () async {
    final order = <String>[];

    await app.runBootConfigPhase(
      seams: app.BootConfigPhaseSeams(
        startCore: () async => order.add('core-start'),
        migrateConfig: (_) async {
          order.add('migration');
          return const ConfigMigrationReport(coreReady: true);
        },
        initializeConfig: () async => order.add('config-init'),
        runDeferredMigrations: () async => order.add('deferred-migrations'),
        startBatteryHistory: () async => order.add('battery-recorder'),
        navigatorReady: () async => true,
        showMigrationProgress: (_) =>
            throw StateError('simulated UI show failure'),
      ),
    );

    expect(order, <String>[
      'core-start',
      'migration',
      'config-init',
      'deferred-migrations',
      'battery-recorder',
    ]);
  });

  test('a throwing dismiss-progress seam cannot abort the boot phase',
      () async {
    final order = <String>[];

    await app.runBootConfigPhase(
      seams: app.BootConfigPhaseSeams(
        startCore: () async => order.add('core-start'),
        migrateConfig: (_) async {
          order.add('migration');
          return const ConfigMigrationReport(coreReady: true);
        },
        initializeConfig: () async => order.add('config-init'),
        runDeferredMigrations: () async => order.add('deferred-migrations'),
        startBatteryHistory: () async => order.add('battery-recorder'),
        navigatorReady: () async => true,
        showMigrationProgress: (_) {},
        dismissMigrationProgress: () =>
            throw StateError('simulated UI dismiss failure'),
      ),
    );

    expect(order, <String>[
      'core-start',
      'migration',
      'config-init',
      'deferred-migrations',
      'battery-recorder',
    ]);
  });

  test('deferred migrations run exactly once inside the awaited sequence',
      () async {
    var deferredCalls = 0;

    await app.runBootConfigPhase(
      seams: app.BootConfigPhaseSeams(
        startCore: () async {},
        migrateConfig: (_) async => const ConfigMigrationReport(),
        initializeConfig: () async {},
        runDeferredMigrations: () async => deferredCalls++,
        startBatteryHistory: () async {},
        navigatorReady: () async => false,
      ),
    );

    expect(deferredCalls, 1);
  });

  test('source has no pre-core ConfigStore init and no post-frame migration',
      () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(
      RegExp(r'ConfigStore\.instance').hasMatch(source),
      isFalse,
      reason: 'C5: no pre-core ConfigStore access may exist in main.dart',
    );

    // Arrow-form, block-form and reformatted post-frame triggers all contain
    // `addPostFrameCallback` within 400 chars of `runDeferredMigrations`.
    final postFrameMigration = RegExp(
      r'addPostFrameCallback[\s\S]{0,400}?runDeferredMigrations',
    );
    expect(
      postFrameMigration.hasMatch(source),
      isFalse,
      reason: 'C13: deferred migrations must not have a separate trigger',
    );

    expect(source.contains('runBootConfigPhase(mark: bootMark)'), isTrue);
  });
}

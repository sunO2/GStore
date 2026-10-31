// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/rust/config_api.dart';
import 'package:gstore/core/rust/CoreApiFacade.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as generated;
import 'package:gstore/core/rust/generated/config_api.dart' as generated;

/// Fake seam over the generated API.
///
/// [watch] applies the **same** module/key filter the Rust bus applies, so the
/// test proves the wrapper forwards the filter instead of dropping events in
/// Dart. Nothing here re-implements the wrapper's mapping logic.
class _FakeConfigApiClient implements ConfigApiClient {
  _FakeConfigApiClient({
    List<generated.ConfigEntryDto>? entries,
    List<generated.ConfigSnapshotDto>? snapshots,
  })  : _entries = entries ?? const [],
        _snapshots = snapshots ?? const [];

  final List<generated.ConfigEntryDto> _entries;
  final List<generated.ConfigSnapshotDto> _snapshots;
  final List<String> watchFilters = <String>[];
  final StreamController<generated.ConfigChangeDto> _changes =
      StreamController<generated.ConfigChangeDto>.broadcast(sync: true);

  void emit(generated.ConfigChangeDto change) => _changes.add(change);

  Future<void> close() => _changes.close();

  @override
  Future<List<generated.ConfigEntryDto>> list({String? module}) async {
    return _entries
        .where((entry) => module == null || entry.module == module)
        .toList();
  }

  @override
  Future<generated.ConfigSnapshotDto?> snapshot({
    required String module,
    required String key,
  }) async {
    for (final snapshot in _snapshots) {
      if (snapshot.module == module && snapshot.key == key) return snapshot;
    }
    return null;
  }

  @override
  Future<List<generated.ConfigSnapshotDto>> snapshots({String? module}) async {
    return _snapshots
        .where((snapshot) => module == null || snapshot.module == module)
        .toList();
  }

  @override
  Future<String> get({
    required String module,
    required String key,
    required bool masked,
  }) async =>
      'null';

  @override
  Future<generated.ConfigOpResultDto> set({
    required String module,
    required String key,
    required String valueJson,
    required String source,
  }) async =>
      _opResult(module, key, valueJson);

  @override
  Future<generated.ConfigOpResultDto> clear({
    required String module,
    required String key,
    required String source,
  }) async =>
      _opResult(module, key, null);

  @override
  Future<generated.ConfigOpResultDto> reset({
    required String module,
    required String key,
    required String source,
  }) async =>
      _opResult(module, key, 'null');

  @override
  Stream<generated.ConfigChangeDto> watch({
    required String module,
    String? key,
  }) {
    watchFilters.add('$module/${key ?? '*'}');
    return _changes.stream.where(
      (change) =>
          change.module == module && (key == null || change.key == key),
    );
  }

  static generated.ConfigOpResultDto _opResult(
    String module,
    String key,
    String? valueJson,
  ) {
    return generated.ConfigOpResultDto(
      success: true,
      message: 'ok',
      module: module,
      key: key,
      wireKey: '$module.$key',
      valueJson: valueJson,
      defaultJson: 'null',
    );
  }
}

generated.ConfigChangeDto _change({
  required String module,
  required String key,
  required String? valueJson,
  String? oldValueJson,
  String source = 'user',
  int revision = 1,
}) {
  return generated.ConfigChangeDto(
    module: module,
    key: key,
    wireKey: '$module.$key',
    valueJson: valueJson,
    oldValueJson: oldValueJson,
    revision: BigInt.from(revision),
    source: source,
  );
}

generated.ConfigEntryDto _entryDto({
  String module = 'download',
  String key = 'max_concurrent',
  String valueType = 'int',
  String defaultJson = '4',
  bool sensitive = false,
  bool agentAccessible = true,
  String visibility = 'owner',
  String descriptionZh = '最大并发',
  String descriptionEn = 'max concurrency',
  String category = 'download',
  String? unit,
  double? min,
  double? max,
  List<String> enumValues = const <String>[],
  String? example,
}) {
  return generated.ConfigEntryDto(
    module: module,
    key: key,
    wireKey: '$module.$key',
    valueType: valueType,
    valueJson: defaultJson,
    masked: false,
    revision: BigInt.zero,
    sensitive: sensitive,
    agentAccessible: agentAccessible,
    visibility: visibility,
    defaultJson: defaultJson,
    descriptionZh: descriptionZh,
    descriptionEn: descriptionEn,
    category: category,
    unit: unit,
    min: min,
    max: max,
    enumValues: enumValues,
    example: example,
  );
}

generated.ConfigSnapshotDto _snapshotDto({
  String module = 'download',
  String key = 'max_concurrent',
  String? valueJson = '7',
}) {
  return generated.ConfigSnapshotDto(
    module: module,
    key: key,
    wireKey: '$module.$key',
    valueJson: valueJson,
    masked: false,
    revision: BigInt.from(5),
    updatedAt: 1234,
    updatedBy: 'user',
  );
}

void main() {
  group('ConfigRustApi filtered watch (fake seam)', () {
    late _FakeConfigApiClient fake;
    late ConfigRustApi api;

    setUp(() {
      fake = _FakeConfigApiClient();
      api = ConfigRustApi(fake);
    });

    tearDown(() => fake.close());

    test('passes the filter down and delivers only matching module/key events',
        () async {
      final moduleEvents = <ConfigChangeEvent>[];
      final keyEvents = <ConfigChangeEvent>[];
      final moduleSub = api.watch('download').listen(moduleEvents.add);
      final keySub =
          api.watch('download', 'max_concurrent').listen(keyEvents.add);

      fake.emit(_change(
        module: 'download',
        key: 'max_concurrent',
        oldValueJson: '2',
        valueJson: '3',
        source: 'user',
        revision: 11,
      ));
      fake.emit(_change(
        module: 'download',
        key: 'wifi_only',
        oldValueJson: 'false',
        valueJson: 'true',
        source: 'internal',
        revision: 12,
      ));
      // Unrelated module must never reach either subscriber.
      fake.emit(_change(
        module: 'theme',
        key: 'mode',
        oldValueJson: '0',
        valueJson: '1',
        source: 'agent',
        revision: 13,
      ));

      await Future<void>.delayed(Duration.zero);
      await moduleSub.cancel();
      await keySub.cancel();

      expect(
        moduleEvents.map((event) => event.key).toList(),
        <String>['download.max_concurrent', 'download.wifi_only'],
      );
      expect(
        keyEvents.map((event) => event.key).toList(),
        <String>['download.max_concurrent'],
      );

      final first = keyEvents.single;
      expect(first.oldValue, 2);
      expect(first.newValue, 3);
      expect(first.source, ConfigChangeSource.user);
      expect(moduleEvents.first.newValue, 3);
      expect(moduleEvents.last.newValue, true);
      expect(moduleEvents.last.source, ConfigChangeSource.internal);

      // The filter was handed to the generated API, not applied by a Dart
      // global-firehose `where`. `*` = whole module.
      expect(fake.watchFilters, <String>['download/*', 'download/max_concurrent']);
    });

    test('maps ConfigEntryDto/ConfigSnapshotDto onto ConfigEntry/ConfigSnapshot',
        () async {
      fake = _FakeConfigApiClient(
        entries: <generated.ConfigEntryDto>[
          _entryDto(
            unit: 'tasks',
            min: 1,
            max: 8,
            enumValues: const <String>[],
            example: '4',
          ),
        ],
        snapshots: <generated.ConfigSnapshotDto>[_snapshotDto()],
      );
      api = ConfigRustApi(fake);

      final entries = await api.list(module: 'download');
      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry.key, 'download.max_concurrent');
      expect(entry.type, ConfigValueType.int);
      expect(entry.defaultValue, 4);
      expect(entry.description, '最大并发');
      expect(entry.descriptionEn, 'max concurrency');
      expect(entry.category, 'download');
      expect(entry.unit, 'tasks');
      expect(entry.min, 1);
      expect(entry.max, 8);
      expect(entry.agentAccessible, isTrue);
      expect(entry.sensitive, isFalse);

      final snapshot = await api.snapshot('download', 'max_concurrent');
      expect(snapshot, isNotNull);
      expect(snapshot!.key, 'download.max_concurrent');
      expect(snapshot.type, 'int');
      expect(snapshot.value, 7);
      expect(snapshot.defaultValue, 4);
      expect(snapshot.description, '最大并发');

      final snapshots = await api.snapshots(module: 'download');
      expect(snapshots, hasLength(1));
      expect(snapshots.single.value, 7);

      expect(await api.snapshot('download', 'wifi_only'), isNull);
    });

    test('maps mutation DTOs onto ConfigOpResult', () async {
      final result = await api.set(
        'download',
        'max_concurrent',
        3,
        source: ConfigChangeSource.user,
      );
      expect(result.success, isTrue);
      expect(result.key, 'download.max_concurrent');
      expect(result.value, 3);
      expect(result.defaultValue, isNull);
    });
  });

  // Real native FRB harness. Mirrors test/core_api_test.dart: opt-in only,
  // because test/flutter_test_config.dart forces the bridge unavailable.
  //
  //   cargo build --manifest-path rust/gstore_host/Cargo.toml
  //   FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR=$PWD/rust/gstore_host/target/debug/ \
  //     flutter test test/config_rust_api_watch_test.dart
  final nativeLibDir =
      Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'];
  final nativeLibAvailable = nativeLibDir != null &&
      Directory(nativeLibDir).existsSync() &&
      Directory(nativeLibDir)
          .listSync()
          .any((e) => e.path.split('/').last.startsWith('libgstore_host'));
  final skipReason = nativeLibAvailable
      ? null
      : 'native host library not loadable: run `cargo build` in rust/gstore_host '
          'and set FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR='
          'rust/gstore_host/target/debug/';

  group('ConfigRustApi native watch', skip: skipReason, () {
    late Directory root;
    late generated.CoreApi core;
    late ConfigRustApi api;

    setUpAll(() async {
      RustBridge.debugForceUnavailable = false;
      root = await Directory.systemTemp.createTemp('gstore_config_watch_');
      final dataDir = '${root.path}/data';
      final filesDir = '${root.path}/files';
      final cacheDir = '${root.path}/cache';
      for (final dir in <String>[dataDir, filesDir, cacheDir]) {
        await Directory(dir).create(recursive: true);
      }
      core = await CoreApiFacade.init(
        dataDir: dataDir,
        filesDir: filesDir,
        cacheDir: cacheDir,
      );
      api = await ConfigRustApi.init();
    });

    tearDownAll(() async {
      core.dispose();
      CoreApiFacade.resetForTest();
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('watch(module) / watch(module,key) isolate delivered events',
        () async {
      final moduleEvents = <ConfigChangeEvent>[];
      final keyEvents = <ConfigChangeEvent>[];
      final themeEvents = <ConfigChangeEvent>[];
      print('STEP: subscribe');
      final moduleSub = api.watch('download').listen(moduleEvents.add);
      final keySub =
          api.watch('download', 'max_concurrent').listen(keyEvents.add);
      final themeSub = api.watch('theme').listen(themeEvents.add);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      print('STEP: set max_concurrent');
      await api.set('download', 'max_concurrent', 3,
          source: ConfigChangeSource.user);
      print('STEP: set wifi_only');
      await api.set('download', 'wifi_only', true,
          source: ConfigChangeSource.user);
      print('STEP: set theme.mode');
      await api.set('theme', 'mode', 1, source: ConfigChangeSource.user);
      print('STEP: delay for delivery');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      print('STEP: detach listeners');
      // FRB 2.11 stream cancellation can block on the Rust-side sink teardown
      // for a `StreamSink` whose producer never completes. The assertions only
      // need the delivered events, so detach without awaiting cancellation.
      unawaited(moduleSub.cancel());
      unawaited(keySub.cancel());
      unawaited(themeSub.cancel());
      print('STEP: assertions');

      print('watch(download,null)   -> '
          '${moduleEvents.map((e) => e.key).toList()}');
      print('watch(download,max)    -> '
          '${keyEvents.map((e) => e.key).toList()}');
      print('watch(theme,null)      -> '
          '${themeEvents.map((e) => e.key).toList()}');

      expect(
        moduleEvents.map((event) => event.key).toSet(),
        <String>{'download.max_concurrent', 'download.wifi_only'},
        reason: 'whole-module watch covers only its module',
      );
      expect(
        keyEvents.map((event) => event.key).toList(),
        <String>['download.max_concurrent'],
        reason: 'single-key watch must not receive sibling keys',
      );
      expect(
        themeEvents.map((event) => event.key).toList(),
        <String>['theme.mode'],
        reason: 'theme watch must not receive download changes',
      );

      final concurrent = keyEvents.single;
      expect(concurrent.newValue, 3);
      expect(await api.get('download', 'max_concurrent'), 3);
    });

    test('invalid module/key surfaces the Rust typed error', () async {
      await expectLater(
        api.set('bad module!', 'key', 1),
        throwsA(
          predicate(
            (Object error) =>
                error.toString().contains('config_invalid') ||
                error.toString().contains('config_key'),
          ),
        ),
      );
    });
  });
}

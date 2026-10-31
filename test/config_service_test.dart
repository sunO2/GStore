// ConfigService rewritten for the module-scoped Rust backend (Todo 14).
//
// Two layers:
//  1. Fake `ConfigApiClient` seam tests run everywhere and exercise the full
//     facade semantics (hydration, mirror, redaction, filtered watches, clear
//     oldValue, JSON/stringList typing). The fake applies the same module/key
//     filter the Rust bus applies, so a Dart-side `where` firehose would fail.
//  2. One native smoke group proves the real Rust round-trip when the host
//     library is loadable, mirroring test/config_rust_api_watch_test.dart:
//
//       cd rust/gstore_host && cargo build
//       FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR=$PWD/rust/gstore_host/target/debug/ \
//         flutter test test/config_service_test.dart
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/rust/config_api.dart';
import 'package:gstore/core/rust/CoreApiFacade.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as generated;
import 'package:gstore/core/rust/generated/config_api.dart' as generated;

const String _themeModeKey = 'theme.mode';
const String _themeConfigKey = 'theme.config';
const String _downloadConcurrentKey = 'download.max_concurrent';
const String _downloadWifiKey = 'download.wifi_only';
const String _webdavPasswordKey = 'webdav.password';
const String _selectedChannelsKey = 'discovery.selected_channels';
const String _proxyUrlKey = 'network.proxy_url';

const String _rawSecretMarker = 'native-secret-marker-7f3a';

generated.ConfigEntryDto _entryDto({
  required String module,
  required String key,
  required String valueType,
  required String defaultJson,
  bool sensitive = false,
  bool agentAccessible = true,
  String visibility = 'owner',
  String category = '',
  List<String> enumValues = const <String>[],
  double? min,
  double? max,
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
    descriptionZh: '$module.$key',
    descriptionEn: '$module.$key',
    category: category,
    enumValues: enumValues,
    min: min,
    max: max,
    example: example,
  );
}

List<generated.ConfigEntryDto> _defaultEntries() {
  return <generated.ConfigEntryDto>[
    _entryDto(
      module: 'theme',
      key: 'mode',
      valueType: 'int',
      defaultJson: '0',
      category: 'theme',
      enumValues: const <String>['0', '1', '2'],
    ),
    _entryDto(
      module: 'theme',
      key: 'config',
      valueType: 'json',
      defaultJson: '{}',
      category: 'theme',
    ),
    _entryDto(
      module: 'download',
      key: 'max_concurrent',
      valueType: 'int',
      defaultJson: '3',
      category: 'download',
      min: 1,
      max: 10,
    ),
    _entryDto(
      module: 'download',
      key: 'wifi_only',
      valueType: 'bool',
      defaultJson: 'false',
      category: 'download',
    ),
    _entryDto(
      module: 'webdav',
      key: 'password',
      valueType: 'string',
      defaultJson: '""',
      sensitive: true,
      agentAccessible: false,
      visibility: 'secret',
      category: 'webdav',
    ),
    _entryDto(
      module: 'discovery',
      key: 'selected_channels',
      valueType: 'string_list',
      defaultJson: '[]',
      category: 'discovery',
    ),
    _entryDto(
      module: 'network',
      key: 'proxy_url',
      valueType: 'string',
      defaultJson: '""',
      category: 'network',
    ),
  ];
}

generated.ConfigChangeDto _changeDto({
  required String module,
  required String key,
  required String? valueJson,
  String? oldValueJson,
  String source = 'internal',
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

/// In-memory [ConfigApiClient] that applies the Rust bus's module/key filter.
class _FakeConfigApiClient implements ConfigApiClient {
  _FakeConfigApiClient({List<generated.ConfigEntryDto>? entries})
      : _entries = entries ?? _defaultEntries();

  final List<generated.ConfigEntryDto> _entries;
  final Map<String, Object?> _values = <String, Object?>{};
  final List<String> watchFilters = <String>[];
  final StreamController<generated.ConfigChangeDto> _changes =
      StreamController<generated.ConfigChangeDto>.broadcast(sync: true);
  int _revision = 0;

  generated.ConfigEntryDto? _entryFor(String module, String key) {
    for (final entry in _entries) {
      if (entry.module == module && entry.key == key) return entry;
    }
    return null;
  }

  generated.ConfigEntryDto _requireEntry(String module, String key) {
    final entry = _entryFor(module, key);
    if (entry == null) {
      throw StateError('config_unknown: $module.$key');
    }
    return entry;
  }

  void _emit(
    generated.ConfigEntryDto entry, {
    required Object? oldValue,
    required Object? newValue,
    required String source,
  }) {
    final oldJson = oldValue == null
        ? null
        : jsonEncode(entry.sensitive ? '***' : oldValue);
    final newJson = newValue == null
        ? null
        : jsonEncode(entry.sensitive ? '***' : newValue);
    _changes.add(_changeDto(
      module: entry.module,
      key: entry.key,
      oldValueJson: oldJson,
      valueJson: newJson,
      source: source,
      revision: ++_revision,
    ));
  }

  generated.ConfigOpResultDto _op(
    String action,
    generated.ConfigEntryDto entry,
    Object? value,
  ) {
    return generated.ConfigOpResultDto(
      success: true,
      message: '$action ${entry.wireKey}',
      module: entry.module,
      key: entry.key,
      wireKey: entry.wireKey,
      valueJson: value == null
          ? null
          : jsonEncode(entry.sensitive ? '***' : value),
      defaultJson: entry.defaultJson,
    );
  }

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
    final entry = _requireEntry(module, key);
    if (!_values.containsKey(entry.wireKey)) return null;
    return generated.ConfigSnapshotDto(
      module: entry.module,
      key: entry.key,
      wireKey: entry.wireKey,
      valueJson:
          jsonEncode(entry.sensitive ? '***' : _values[entry.wireKey]),
      masked: entry.sensitive,
      revision: BigInt.from(_revision),
      updatedAt: 0,
      updatedBy: 'user',
    );
  }

  @override
  Future<List<generated.ConfigSnapshotDto>> snapshots({String? module}) async {
    final out = <generated.ConfigSnapshotDto>[];
    for (final entry in _entries) {
      if (module != null && entry.module != module) continue;
      final snap = await snapshot(module: entry.module, key: entry.key);
      if (snap != null) out.add(snap);
    }
    return out;
  }

  @override
  Future<String> get({
    required String module,
    required String key,
    required bool masked,
  }) async {
    final entry = _requireEntry(module, key);
    if (!_values.containsKey(entry.wireKey)) return entry.defaultJson;
    if (masked && entry.sensitive) return jsonEncode('***');
    return jsonEncode(_values[entry.wireKey]);
  }

  @override
  Future<generated.ConfigOpResultDto> set({
    required String module,
    required String key,
    required String valueJson,
    required String source,
  }) async {
    final entry = _requireEntry(module, key);
    final value = jsonDecode(valueJson);
    final oldValue = _values[entry.wireKey];
    _values[entry.wireKey] = value;
    _emit(entry, oldValue: oldValue, newValue: value, source: source);
    return _op('set', entry, value);
  }

  @override
  Future<generated.ConfigOpResultDto> clear({
    required String module,
    required String key,
    required String source,
  }) async {
    final entry = _requireEntry(module, key);
    final oldValue = _values.remove(entry.wireKey);
    _emit(entry, oldValue: oldValue, newValue: null, source: source);
    return _op('clear', entry, null);
  }

  @override
  Future<generated.ConfigOpResultDto> reset({
    required String module,
    required String key,
    required String source,
  }) async {
    final entry = _requireEntry(module, key);
    final oldValue = _values[entry.wireKey];
    final value = jsonDecode(entry.defaultJson);
    _values[entry.wireKey] = value;
    _emit(entry, oldValue: oldValue, newValue: value, source: source);
    return _op('reset', entry, value);
  }

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
}

Future<void> _settle([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = ConfigService.instance;

  group('ConfigService fake seam', () {
    late _FakeConfigApiClient fake;

    setUp(() async {
      await service.resetForTest();
      fake = _FakeConfigApiClient();
      service.debugSetApi(ConfigRustApi(fake));
      await service.ensureReady();
    });

    tearDown(() async {
      await service.resetForTest();
      await fake.close();
    });

    test('ensureReady hydrates Rust metadata for synchronous reads (C2)',
        () async {
      expect(service.has(_themeModeKey), isTrue);
      expect(service.has(_downloadConcurrentKey), isTrue);
      expect(service.has('theme_mode'), isFalse,
          reason: 'legacy keys are replaced by the Rust wire registry');
      expect(service.has('no.such.key'), isFalse);

      final entry = service.entry(_themeModeKey);
      if (entry == null) fail('theme.mode metadata missing after ensureReady');
      expect(entry.type, ConfigValueType.int);
      expect(entry.defaultValue, 0);
      expect(entry.enumValues, <String>['0', '1', '2']);
      expect(entry.category, 'theme');

      expect(service.isAgentAccessible(_themeModeKey), isTrue);
      expect(service.isAgentAccessible(_webdavPasswordKey), isFalse);
      expect(service.hasModule('theme'), isTrue);
      expect(service.hasModule('download'), isTrue);
      expect(service.hasModule('nope'), isFalse);
      expect(service.moduleNames, containsAll(<String>['theme', 'download']));

      final keys = service.list().map((e) => e.key).toList();
      expect(keys, List<String>.of(keys)..sort());
      expect(keys, contains(_themeModeKey));
    });

    test('set validates known keys and unknown keys fail (no swallowing)',
        () async {
      final unknown = await service.set('no.such.key', 1);
      expect(unknown.success, isFalse);
      expect(unknown.message, contains('未知配置项'));

      final wrongType = await service.set(_themeModeKey, 'not-an-int');
      expect(wrongType.success, isFalse);
      expect(wrongType.message, contains('整数'));

      final tooBig = await service.set(_downloadConcurrentKey, 99);
      expect(tooBig.success, isFalse);
      expect(tooBig.message, contains('不能大于'));

      expect(await service.get('no.such.key'), isNull);
      expect(await service.getRaw('no.such.key'), isNull);
    });

    test('set(theme.mode,2) -> getT<int> == 2 and onChange fires once',
        () async {
      final events = <ConfigChangeEvent>[];
      final sub = service.onChange.listen(events.add);
      await _settle();

      final result = await service.set(_themeModeKey, 2);
      expect(result.success, isTrue, reason: result.message);
      expect(result.key, _themeModeKey);
      expect(result.value, 2);
      expect(result.defaultValue, 0);

      expect(await service.getT<int>(_themeModeKey), 2);
      await _settle();

      final themeEvents =
          events.where((e) => e.key == _themeModeKey).toList();
      expect(themeEvents, hasLength(1),
          reason: 'mirror must not duplicate the global event');
      expect(themeEvents.single.oldValue, isNull);
      expect(themeEvents.single.newValue, 2);
      await sub.cancel();
    });

    test('set(download.max_concurrent,2) then getT<int> returns 2', () async {
      await service.set(_downloadConcurrentKey, 2);
      expect(await service.getT<int>(_downloadConcurrentKey), 2);
    });

    test('wrong getT type returns null instead of throwing', () async {
      await service.set(_themeModeKey, 2);
      expect(await service.getT<String>(_themeModeKey), isNull);
    });

    test('secret masked by get, readable by getRaw, never cached in mirror (C3)',
        () async {
      const marker = 'super-secret-marker-91c2';
      final events = <ConfigChangeEvent>[];
      final sub = service.onChange.listen(events.add);
      await _settle();

      // Populate the mirror with a non-sensitive value first; otherwise the
      // secret-absence loop below iterates an empty map and proves nothing.
      expect(await service.getT<int>(_downloadConcurrentKey), 3);
      expect(service.debugMirror, isNotEmpty);

      final result = await service.set(_webdavPasswordKey, marker);
      expect(result.success, isTrue, reason: result.message);

      expect(await service.get(_webdavPasswordKey), '***');
      expect(await service.get(_webdavPasswordKey, masked: false), marker);
      expect(await service.getRaw(_webdavPasswordKey), marker);
      await _settle();

      // The mirror must never contain the raw secret marker (and must be
      // non-empty, proving the scan is not vacuous).
      expect(service.debugMirror, isNotEmpty);
      for (final value in service.debugMirror.values) {
        expect(value.toString(), isNot(contains(marker)));
      }
      // Events are masked by Rust, so the marker never reaches Dart listeners.
      for (final event in events) {
        expect(event.newValue.toString(), isNot(contains(marker)));
        expect(event.oldValue.toString(), isNot(contains(marker)));
      }
      await sub.cancel();
    });

    test('filtered subscriptions are pushed to ConfigApi.watch, not Dart',
        () async {
      final moduleEvents = <ConfigChangeEvent>[];
      final keyEvents = <ConfigChangeEvent>[];
      final themeEvents = <ConfigChangeEvent>[];
      fake.watchFilters.clear();

      final moduleSub = service.watchModule('download').listen(moduleEvents.add);
      final keySub = service.watch(_downloadConcurrentKey).listen(keyEvents.add);
      final themeSub = service.watchModule('theme').listen(themeEvents.add);
      await _settle();

      await service.set(_downloadConcurrentKey, 2);
      await service.set(_downloadWifiKey, true);
      await service.set(_themeModeKey, 2);
      await _settle();

      expect(
        moduleEvents.map((e) => e.key).toSet(),
        <String>{_downloadConcurrentKey, _downloadWifiKey},
        reason: 'watchModule(download) must never receive theme.*',
      );
      expect(
        keyEvents.map((e) => e.key).toList(),
        <String>[_downloadConcurrentKey],
      );
      expect(
        themeEvents.map((e) => e.key).toList(),
        <String>[_themeModeKey],
      );
      expect(
        fake.watchFilters,
        containsAll(<String>[
          'download/*',
          'download/max_concurrent',
          'theme/*',
        ]),
        reason: 'filters must be evaluated by the client/Rust, not by a Dart '
            'global-firehose where()',
      );

      unawaited(moduleSub.cancel());
      unawaited(keySub.cancel());
      unawaited(themeSub.cancel());
    });

    test('watchMany listens to each exact key only', () async {
      final seen = <String>[];
      final sub = service
          .watchMany(<String>[_themeModeKey, _downloadConcurrentKey])
          .listen((e) => seen.add(e.key));
      await _settle();

      await service.set(_themeModeKey, 2);
      await service.set(_downloadWifiKey, true);
      await service.set(_downloadConcurrentKey, 2);
      await _settle();

      expect(seen, <String>[_themeModeKey, _downloadConcurrentKey]);
      await sub.cancel();
    });

    test('clear captures oldValue before clearing (C26)', () async {
      await service.set(_themeModeKey, 2);
      await _settle();

      final events = <ConfigChangeEvent>[];
      final sub = service.onChange.listen(events.add);
      await _settle();

      final result = await service.clear(_themeModeKey);
      expect(result.success, isTrue, reason: result.message);
      await _settle();

      final event = events.singleWhere((e) => e.key == _themeModeKey);
      expect(event.oldValue, 2,
          reason: 'oldValue must be captured before the row is removed');
      expect(event.newValue, isNull);
      // Rust clear falls back to the registry default on the next read.
      expect(await service.getT<int>(_themeModeKey), 0);
      await sub.cancel();
    });

    test('reset restores the registry default and updates the mirror',
        () async {
      await service.set(_themeModeKey, 2);
      final result = await service.reset(_themeModeKey);
      expect(result.success, isTrue, reason: result.message);
      expect(await service.getT<int>(_themeModeKey), 0);
      expect(service.debugMirror[_themeModeKey], 0);
    });

    test('external/host write refreshes the mirror via the global stream',
        () async {
      await service.set(_themeModeKey, 1);
      expect(await service.getT<int>(_themeModeKey), 1);

      // Another subsystem/host writes straight through Rust, bypassing
      // ConfigService.set. The module-scoped global subscription must refresh
      // the Dart mirror so a later read is not stale.
      await fake.set(
        module: 'theme',
        key: 'mode',
        valueJson: '2',
        source: 'internal',
      );
      await _settle();
      expect(await service.getT<int>(_themeModeKey), 2);
      expect(service.debugMirror[_themeModeKey], 2);
    });

    test('JSON string input is decoded and event typing is normalized (C26/C6)',
        () async {
      final events = <ConfigChangeEvent>[];
      final sub = service.onChange.listen(events.add);
      await _settle();

      final result = await service.set(_themeConfigKey, '{"fontStyle":3}');
      expect(result.success, isTrue, reason: result.message);

      final raw = await service.getRaw(_themeConfigKey);
      expect(raw, isA<Map<String, dynamic>>());
      final rawMap = raw as Map<String, dynamic>;
      expect(rawMap['fontStyle'], 3);
      expect(await service.getT<Map<String, dynamic>>(_themeConfigKey),
          <String, dynamic>{'fontStyle': 3});
      await _settle();

      final event = events.singleWhere((e) => e.key == _themeConfigKey);
      expect(event.newValue, isA<Map<String, dynamic>>());

      final invalid = await service.set(_themeConfigKey, 'not-json{{{');
      expect(invalid.success, isFalse);
      expect(invalid.message, contains('JSON'));
      await sub.cancel();
    });

    test('stringList events and getT<List<String>> stay strongly typed',
        () async {
      final events = <ConfigChangeEvent>[];
      final sub = service.onChange.listen(events.add);
      await _settle();

      final result =
          await service.set(_selectedChannelsKey, <String>['alpha', 'beta']);
      expect(result.success, isTrue, reason: result.message);

      final typed = await service.getT<List<String>>(_selectedChannelsKey);
      expect(typed, <String>['alpha', 'beta']);
      expect(typed, isA<List<String>>());
      await _settle();

      final event = events.singleWhere((e) => e.key == _selectedChannelsKey);
      expect(event.newValue, isA<List<String>>());
      expect(event.newValue, <String>['alpha', 'beta']);
      await sub.cancel();
    });

    test('snapshot carries metadata; unset value is null; secrets masked',
        () async {
      final unset = await service.snapshot(_proxyUrlKey);
      if (unset == null) fail('proxy_url snapshot missing');
      expect(unset.key, _proxyUrlKey);
      expect(unset.value, isNull);
      expect(unset.defaultValue, '');
      expect(unset.type, 'string');

      await service.set(_themeModeKey, 2);
      final snap = await service.snapshot(_themeModeKey);
      if (snap == null) fail('theme.mode snapshot missing');
      expect(snap.value, 2);
      expect(snap.defaultValue, 0);
      expect(snap.enumValues, <String>['0', '1', '2']);
      expect(snap.category, 'theme');
      expect(snap.agentAccessible, isTrue);
      expect(snap.sensitive, isFalse);

      await service.set(_webdavPasswordKey, 'secret');
      final secret = await service.snapshot(_webdavPasswordKey);
      if (secret == null) fail('webdav.password snapshot missing');
      expect(secret.sensitive, isTrue);
      expect(secret.value, '***');

      expect(await service.snapshot('no.such.key'), isNull);

      final all = await service.snapshots();
      expect(all, isNotEmpty);
      final keys = all.map((s) => s.key).toList();
      expect(keys, List<String>.of(keys)..sort());
    });

    test('register/registerModule are no-ops after hydration (C2)', () async {
      service.register(const ConfigEntry(
        key: 'custom.key',
        type: ConfigValueType.int,
      ));
      expect(service.has('custom.key'), isFalse);
      expect(service.has(_themeModeKey), isTrue);

      final before = service.moduleNames;
      service.registerModule(_NoopModule());
      expect(service.hasModule('noop_module'), isFalse);
      expect(service.moduleNames, before);
    });

    test('cancel then relisten works (no dead subscription)', () async {
      final first = <ConfigChangeEvent>[];
      final firstSub = service.watch(_themeModeKey).listen(first.add);
      await _settle();
      await service.set(_themeModeKey, 1);
      await _settle();
      expect(first, hasLength(1));
      await firstSub.cancel();

      await service.set(_themeModeKey, 2);
      await _settle();
      expect(first, hasLength(1), reason: 'cancelled listener stays cancelled');

      final second = <ConfigChangeEvent>[];
      final secondSub = service.watch(_themeModeKey).listen(second.add);
      await _settle();
      await service.set(_themeModeKey, 1);
      await _settle();
      expect(second, hasLength(1));
      expect(second.single.newValue, 1);
      await secondSub.cancel();
    });

    test('register before hydration populates synchronous metadata', () async {
      await service.resetForTest();
      final localFake = _FakeConfigApiClient();
      service.debugSetApi(ConfigRustApi(localFake));

      service.register(const ConfigEntry(
        key: 'legacy.key',
        type: ConfigValueType.string,
        defaultValue: 'x',
      ));
      expect(service.has('legacy.key'), isTrue);
      expect(service.entry('legacy.key')?.type, ConfigValueType.string);
      expect(service.isAgentAccessible('legacy.key'), isFalse);

      // Hydration replaces the legacy metadata with the Rust registry.
      await service.ensureReady();
      expect(service.has('legacy.key'), isFalse);
      expect(service.has(_themeModeKey), isTrue);
      await service.resetForTest();
      await localFake.close();
    });
  });

  // Real native FRB harness (opt-in, mirrors config_rust_api_watch_test.dart).
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

  group('ConfigService native round-trip', skip: skipReason, () {
    late Directory root;
    late generated.CoreApi core;

    setUpAll(() async {
      RustBridge.debugForceUnavailable = false;
      root = await Directory.systemTemp.createTemp('gstore_config_service_');
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
      await service.resetForTest();
      await service.ensureReady();
    });

    tearDownAll(() async {
      await service.resetForTest();
      core.dispose();
      CoreApiFacade.resetForTest();
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('real ConfigApi round-trip, filtered streams, secret redaction, clear',
        () async {
      final global = <ConfigChangeEvent>[];
      final downloadModule = <ConfigChangeEvent>[];
      final concurrentKey = <ConfigChangeEvent>[];
      final globalSub = service.onChange.listen(global.add);
      final moduleSub =
          service.watchModule('download').listen(downloadModule.add);
      final keySub =
          service.watch(_downloadConcurrentKey).listen(concurrentKey.add);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final themeSet = await service.set(_themeModeKey, 2,
          source: ConfigChangeSource.user);
      print('set(theme.mode,2) success=${themeSet.success} '
          'value=${themeSet.value}');
      final concurrentSet = await service.set(_downloadConcurrentKey, 2,
          source: ConfigChangeSource.user);
      print('set(download.max_concurrent,2) success=${concurrentSet.success} '
          'value=${concurrentSet.value}');

      final themeTyped = await service.getT<int>(_themeModeKey);
      final concurrentTyped = await service.getT<int>(_downloadConcurrentKey);
      print('getT<int>(theme.mode) = $themeTyped');
      print('getT<int>(download.max_concurrent) = $concurrentTyped');

      await Future<void>.delayed(const Duration(milliseconds: 600));

      print('onChange -> ${global.map((e) => e.key).toList()}');
      print('watchModule(download) -> '
          '${downloadModule.map((e) => e.key).toList()}');
      print('watch(download.max_concurrent) -> '
          '${concurrentKey.map((e) => e.key).toList()}');

      expect(themeTyped, 2);
      expect(concurrentTyped, 2);
      expect(
        downloadModule.map((e) => e.key).toSet(),
        <String>{_downloadConcurrentKey},
        reason: 'watchModule(download) must never receive theme.*',
      );
      expect(
        concurrentKey.map((e) => e.key).toList(),
        <String>[_downloadConcurrentKey],
      );
      expect(global.map((e) => e.key).toSet(), containsAll(<String>[
        _themeModeKey,
        _downloadConcurrentKey,
      ]));

      // --- secret redaction ---
      final secretSet = await service.set(_webdavPasswordKey, _rawSecretMarker);
      final masked = await service.get(_webdavPasswordKey);
      final raw = await service.getRaw(_webdavPasswordKey);
      print('set(webdav.password) success=${secretSet.success}');
      print('get(webdav.password) = $masked');
      print('getRaw(webdav.password) = $raw');
      expect(masked, '***');
      expect(raw, _rawSecretMarker);

      var mirrorLeak = false;
      expect(service.debugMirror, isNotEmpty,
          reason: 'non-sensitive reads above must populate the mirror');
      for (final value in service.debugMirror.values) {
        if (value.toString().contains(_rawSecretMarker)) mirrorLeak = true;
      }
      print('mirror size = ${service.debugMirror.length}');
      print('mirror contains raw secret = $mirrorLeak');
      expect(mirrorLeak, isFalse,
          reason: 'secret plaintext must never enter the Dart mirror (C3)');

      await Future<void>.delayed(const Duration(milliseconds: 300));
      for (final event in global) {
        expect(event.newValue.toString(), isNot(contains(_rawSecretMarker)));
        expect(event.oldValue.toString(), isNot(contains(_rawSecretMarker)));
      }

      // --- clear captures oldValue ---
      await service.set(_themeModeKey, 1,
          source: ConfigChangeSource.user);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      global.clear();
      final cleared = await service.clear(_themeModeKey);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final clearEvents =
          global.where((e) => e.key == _themeModeKey).toList();
      print('clear(theme.mode) success=${cleared.success}');
      print('clear events -> ${clearEvents.map((e) => e.toString()).toList()}');
      expect(clearEvents, isNotEmpty);
      expect(clearEvents.last.oldValue, 1,
          reason: 'oldValue captured before clearing (C26)');
      expect(clearEvents.last.newValue, isNull);

      unawaited(globalSub.cancel());
      unawaited(moduleSub.cancel());
      unawaited(keySub.cancel());
    });
  });
}

class _NoopModule extends ConfigModule {
  @override
  String get moduleName => 'noop_module';

  @override
  List<ConfigEntry> get configs => const <ConfigEntry>[];
}

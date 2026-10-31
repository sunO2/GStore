// Todo 19: F-Droid + discovery config call sites use grouped keys and typed
// JSON / string-list values (C6 / C26).
//
// Storage goes through the `ConfigStore.initialize({storages})` seam (C17);
// ConfigStore and ConfigService share the same in-memory backend, mirroring the
// `ConfigService.getRaw` / `getT` paths used by FdroidRepoManager and the
// discovery notifier.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';

const List<String> _scannedRuntimeDirs = <String>[
  'lib/core/agent',
  'lib/core/perf',
  'lib/core/fdroid',
  'lib/page/home/tab/discovery',
];

/// Quoted key literals that runtime code in the scanned directories must not use.
///
/// This is a **secondary guard only — not the gate**:
///   * the primary gate is that every runtime key is a `ConfigKeys` constant
///     (which `test/config_keys_grouped_test.dart` checks against the Rust
///     registry fixture), plus the behavioral tests above;
///   * this scan catches copy-pasted string literals that bypass `ConfigKeys`.
/// Scope: `lib/core/agent`, `lib/core/perf`, `lib/core/fdroid`,
/// `lib/page/home/tab/discovery`; only `.dart` files; comments are not stripped,
/// so only quoted literals are matched (docs use backticks).
const List<String> _forbiddenKeyLiterals = <String>[
  // Legacy bare keys (migration-only; live in config_registry tables).
  "'agent_models'",
  '"agent_models"',
  "'agent_selected_model_id'",
  '"agent_selected_model_id"',
  "'agent_model_catalog'",
  '"agent_model_catalog"',
  "'fdroid_sources'",
  '"fdroid_sources"',
  "'last_source_id'",
  '"last_source_id"',
  "'selected_channels'",
  '"selected_channels"',
  // Grouped wire keys must come from ConfigKeys, never be hardcoded at a call
  // site (e.g. the history gate key below).
  "'perf.history.enabled'",
  '"perf.history.enabled"',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = ConfigStore.instance;
  final service = ConfigService.instance;

  setUp(() async {
    store.resetForTest();
    await store.initialize(storages: <ConfigStorage>[MemoryConfigStorage()]);
    await service.ensureReady();
  });

  tearDown(() async {
    await service.resetForTest();
    store.resetForTest();
  });

  group('fdroid / discovery keys are grouped', () {
    test('ConfigKeys expose module.key wire names', () {
      expect(ConfigKeys.fdroidSources, 'fdroid.sources');
      expect(ConfigKeys.lastSourceId, 'fdroid.last_source_id');
      expect(ConfigKeys.selectedChannels, 'discovery.selected_channels');
      expect(service.has(ConfigKeys.fdroidSources), isTrue);
      expect(service.has(ConfigKeys.lastSourceId), isTrue);
      expect(service.has(ConfigKeys.selectedChannels), isTrue);
      // Legacy bare spellings are not runtime keys.
      expect(service.has('fdroid_sources'), isFalse);
      expect(service.has('last_source_id'), isFalse);
      expect(service.has('selected_channels'), isFalse);
    });
  });

  group('F-Droid sources (fdroid.sources)', () {
    test('typed List<Map> round-trip through the raw read used by the manager',
        () async {
      final sources = <Map<String, Object?>>[
        <String, Object?>{
          'id': 'official',
          'name': '官方源',
          'repoUrl': 'https://f-droid.org/repo',
          'enabled': true,
        },
        <String, Object?>{
          'id': 'tuna',
          'name': '清华镜像',
          'repoUrl': 'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo',
          'enabled': false,
        },
      ];
      final result = await service.set(
        ConfigKeys.fdroidSources,
        sources,
        source: ConfigChangeSource.internal,
      );
      expect(result.success, isTrue, reason: result.message);

      // FdroidRepoManager._loadSources reads via getRaw and expects a List.
      final raw = await service.getRaw(ConfigKeys.fdroidSources);
      expect(raw, isA<List>());
      final list = (raw as List).cast<Map>();
      expect(list, hasLength(2));
      expect(list.first['id'], 'official');
      expect(list.last['repoUrl'], contains('tuna'));

      // Stored backend value stays typed JSON (not a Dart toString string).
      final stored = await store.readValue(ConfigKeys.fdroidSources);
      expect(stored, isA<List>());
      final text = await store.readString(ConfigKeys.fdroidSources);
      expect(jsonDecode(text!), isA<List>());
    });

    test('JSON-encoded string input is normalized to a typed list', () async {
      final encoded = jsonEncode(<Map<String, Object?>>[
        <String, Object?>{'id': 'x', 'repoUrl': 'https://example.com/repo'},
      ]);
      final result = await service.set(ConfigKeys.fdroidSources, encoded);
      expect(result.success, isTrue, reason: result.message);
      expect(await service.getRaw(ConfigKeys.fdroidSources), isA<List>());
    });

    test('last_source_id reads via getT<String> from fdroid.last_source_id',
        () async {
      expect(await service.getT<String>(ConfigKeys.lastSourceId), isEmpty);
      await service.set(ConfigKeys.lastSourceId, 'tuna');
      expect(await service.getT<String>(ConfigKeys.lastSourceId), 'tuna');
      expect(await service.getRaw('last_source_id'), isNull,
          reason: 'legacy bare key must not resolve at runtime');
    });
  });

  group('discovery selected channels (C26)', () {
    test('round-trips a typed List<String> (not List<dynamic>)', () async {
      final result = await service.set(
        ConfigKeys.selectedChannels,
        <String>['fdroid', 'github'],
        source: ConfigChangeSource.user,
      );
      expect(result.success, isTrue, reason: result.message);

      final saved = await service.getT<List<String>>(ConfigKeys.selectedChannels);
      expect(saved, isNotNull);
      expect(saved, equals(<String>['fdroid', 'github']));
      expect(saved, isA<List<String>>(),
          reason: 'C26: getT<List<String>> must not silently fail');

      expect(await service.getRaw(ConfigKeys.selectedChannels),
          equals(<String>['fdroid', 'github']));
    });

    test('ConfigStore.readStringList returns a typed List<String>', () async {
      await service.set(
        ConfigKeys.selectedChannels,
        <String>['fdroid', 'github'],
      );
      final value =
          await ConfigStore.instance.readStringList(ConfigKeys.selectedChannels);
      expect(value, equals(<String>['fdroid', 'github']));
      expect(value, isA<List<String>>());
    });

    test('empty list keeps the default fallback semantics', () async {
      await service.set(ConfigKeys.selectedChannels, <String>[]);
      final saved = await service.getT<List<String>>(ConfigKeys.selectedChannels);
      // The discovery notifier falls back to ['fdroid'] for empty values.
      expect(saved, isEmpty);
    });
  });

  group('static guard: no bare runtime key literals (secondary)', () {
    test('agent/perf/fdroid/discovery sources only use ConfigKeys', () {
      final offenders = <String>[];
      var filesScanned = 0;
      for (final dir in _scannedRuntimeDirs) {
        final directory = Directory(dir);
        expect(directory.existsSync(), isTrue, reason: 'missing $dir');
        for (final entity in directory.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          filesScanned++;
          final text = entity.readAsStringSync();
          for (final banned in _forbiddenKeyLiterals) {
            if (text.contains(banned)) {
              offenders.add('${entity.path}: $banned');
            }
          }
        }
      }
      // Non-vacuous: the scan must actually have visited runtime sources.
      expect(filesScanned, greaterThan(10),
          reason: 'static guard must scan real runtime files');
      expect(offenders, isEmpty,
          reason: 'runtime code must use ConfigKeys, found:\n${offenders.join('\n')}');
    });
  });
}

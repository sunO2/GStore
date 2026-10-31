// Todo 19: perf call sites (PerfProfileStore / battery history gate /
// PerfMonitorModule) use the grouped ConfigKeys and typed JSON.
//
// Storage goes through the `ConfigStore.initialize({storages})` seam (C17);
// ConfigStore and ConfigService share the same in-memory backend.
// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/perf/battery_history_gate.dart';
import 'package:gstore/core/perf/perf_profile.dart';
import 'package:gstore/core/perf/perf_profile_store.dart';

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

  group('perf keys are grouped', () {
    test('ConfigKeys expose module.key wire names', () {
      expect(ConfigKeys.perfProfiles, 'perf.profiles');
      expect(ConfigKeys.perfProfilesEnabled, 'perf.profiles.enabled');
      expect(ConfigKeys.perfHistoryEnabled, 'perf.history.enabled');
      expect(service.has(ConfigKeys.perfProfiles), isTrue);
      expect(service.has(ConfigKeys.perfProfilesEnabled), isTrue);
      expect(service.has(ConfigKeys.perfHistoryEnabled), isTrue);
      // Legacy bare spellings are not runtime keys.
      expect(service.has('perf_profiles'), isFalse);
      expect(service.has('perf_profiles_enabled'), isFalse);
      expect(service.has('perf_history_enabled'), isFalse);
    });
  });

  group('ConfigPerfProfileStore', () {
    const profileStore = ConfigPerfProfileStore();

    test('saves a typed Map (not a JSON string) and round-trips profiles',
        () async {
      const profile = PerfProfile(
        package: 'com.example.app',
        enabled: true,
        gpuLevel: 2,
        cpuset: 'top-app',
        mode: PerfMode.performance,
      );
      expect(await profileStore.save(profile), isTrue);

      final stored = await store.readValue(ConfigKeys.perfProfiles);
      expect(stored, isA<Map>(), reason: 'perf.profiles must be a typed Map');
      expect((stored as Map)['com.example.app'], isA<Map>());
      expect(stored['com.example.app']['gpu_level'], 2);

      final loaded = await profileStore.loadAll();
      expect(loaded.keys, contains('com.example.app'));
      expect(loaded['com.example.app']!.mode, PerfMode.performance);
      expect(loaded['com.example.app']!.enabled, isTrue);

      // Public masked view is not sensitive but still decodes to Map.
      expect(await service.getRaw(ConfigKeys.perfProfiles), isA<Map>());
    });

    test('mode-only convenience write keeps other fields', () async {
      await profileStore.save(const PerfProfile(
        package: 'com.example.app',
        gpuLevel: 1,
        mode: PerfMode.powersave,
      ));
      expect(await profileStore.saveMode('com.example.app', PerfMode.fast),
          isTrue);
      final loaded = await profileStore.load('com.example.app');
      expect(loaded!.mode, PerfMode.fast);
      expect(loaded.gpuLevel, 1);
    });

    test('malformed stored JSON falls back to empty profiles (never throws)',
        () async {
      final storage = MemoryConfigStorage();
      await storage.setString(ConfigKeys.perfProfiles, 'not-json');
      store.resetForTest();
      await store.initialize(storages: <ConfigStorage>[storage]);

      expect(await profileStore.loadAll(), isEmpty);
      expect(await profileStore.remove('com.example.app'), isTrue);
    });
  });

  group('perf enable flags', () {
    test('profiles master switch reads/writes via perf.profiles.enabled',
        () async {
      expect(await store.readBool(ConfigKeys.perfProfilesEnabled), isFalse,
          reason: 'default OFF (fail-closed)');

      expect(await store.write(ConfigKeys.perfProfilesEnabled, true), isTrue);
      expect(await store.readBool(ConfigKeys.perfProfilesEnabled), isTrue);
      expect(await service.getRaw(ConfigKeys.perfProfilesEnabled), isTrue);

      // Legacy bare key cannot be used to read the new value.
      expect(await service.getRaw('perf_profiles_enabled'), isNull);
    });

    test('battery history gate reads perf.history.enabled (default OFF)',
        () async {
      expect(await readBatteryHistoryEnabled(), isFalse);

      expect(await store.write(ConfigKeys.perfHistoryEnabled, true), isTrue);
      expect(await readBatteryHistoryEnabled(), isTrue);

      // Disabled / unset never constructs the recorder (no Rust PerfModule).
      var constructed = false;
      final started = await startBatteryHistoryRecorderIfEnabled(
        readEnabled: () async => false,
        recorder: () {
          constructed = true;
          throw StateError('recorder must not be constructed when disabled');
        },
        log: (_) {},
      );
      expect(started, isFalse);
      expect(constructed, isFalse);
    });

    test('history gate swallows reader failures (stays off)', () async {
      final started = await startBatteryHistoryRecorderIfEnabled(
        readEnabled: () async => throw StateError('config unavailable'),
        recorder: () => throw StateError('must not construct'),
        log: (_) {},
      );
      expect(started, isFalse);
    });
  });

  group('PerfProfile JSON shape', () {
    test('stored value jsonDecodes as a Map (C6)', () async {
      await store.write(ConfigKeys.perfProfiles, <String, Object?>{
        'com.example.app': const PerfProfile(
          package: 'com.example.app',
          mode: PerfMode.balance,
        ).toJson(),
      });
      final raw = await store.readString(ConfigKeys.perfProfiles);
      expect(raw, isNotNull);
      expect(jsonDecode(raw!), isA<Map>());
    });
  });
}

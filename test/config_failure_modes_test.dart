// Todo 37: Dart-side failure-mode tests (plan C19).
//
// Covers the surfaces that only exist in Dart:
//  * the in-memory mirror / events / snapshots / Agent tool output never carry
//    a secret plaintext, while `getRaw` and `exportRaw` still return it;
//  * two independent watchers on the same `(module, key)` both receive every
//    event and neither leaks the other key's changes;
//  * the full 11 proxy keys and 11 module toggles are registered, while
//    unregistered/legacy keys are rejected without throwing.
//
// Storage is the `ConfigStore.initialize({storages})` fake seam (C17), which
// shares one in-memory backend with `ConfigService`.

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';

const String _secretMarker = 'task37-dart-secret-marker-4b8e';

const List<String> _proxyKeys = <String>[
  ConfigKeys.proxyEngineStack,
  ConfigKeys.proxyEngineMtu,
  ConfigKeys.proxyRoutingMode,
  ConfigKeys.proxyRunMode,
  ConfigKeys.proxyActiveNodeLabel,
  ConfigKeys.proxyActiveProfileId,
  ConfigKeys.proxySheetViewMode,
  ConfigKeys.proxySplitMode,
  ConfigKeys.proxySplitApps,
  ConfigKeys.proxyAlwaysOnIntent,
  ConfigKeys.proxyLogLevel,
];

const List<String> _moduleToggles = <String>[
  ConfigKeys.moduleChannelEnabled,
  ConfigKeys.moduleDownloadEnabled,
  ConfigKeys.moduleBackupEnabled,
  ConfigKeys.moduleWebdavEnabled,
  ConfigKeys.moduleFdroidEnabled,
  ConfigKeys.moduleThemeEnabled,
  ConfigKeys.moduleInstallEnabled,
  ConfigKeys.moduleAggregateEnabled,
  ConfigKeys.moduleAgentToolsEnabled,
  ConfigKeys.moduleUpdateEnabled,
  ConfigKeys.moduleBadgeEnabled,
];

Future<void> _initFakeBackend() async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(
    storages: <ConfigStorage>[MemoryConfigStorage(), MemoryConfigStorage()],
  );
  await ConfigService.instance.ensureReady();
}

Future<void> _settle([int ms = 25]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = ConfigStore.instance;
  final service = ConfigService.instance;

  setUp(_initFakeBackend);

  tearDown(() async {
    await service.resetForTest();
    store.resetForTest();
  });

  test('secret is absent from mirror/events/snapshots/tool output while raw '
      'reads and the backup export still return it', () async {
    final globalEvents = <ConfigChangeEvent>[];
    final keyEvents = <ConfigChangeEvent>[];
    final globalSub = service.onChange.listen(globalEvents.add);
    final keySub =
        service.watch(ConfigKeys.webdavPassword).listen(keyEvents.add);

    // Populate the mirror with a non-sensitive value first: a mirror that never
    // received a value would make the secret-absence assertion vacuous.
    expect(await service.getT<int>(ConfigKeys.downloadMaxConcurrent), 3);
    expect(
      service.debugMirror.containsKey(ConfigKeys.downloadMaxConcurrent),
      isTrue,
      reason: 'the non-sensitive read above must populate the mirror',
    );
    expect(service.debugMirror, isNotEmpty);
    debugPrint(
      'task37 mirror populated before secret: keys=${service.debugMirror.keys.toList()} '
      'size=${service.debugMirror.length}',
    );

    final result = await service.set(
      ConfigKeys.webdavPassword,
      _secretMarker,
      source: ConfigChangeSource.user,
    );
    expect(result.success, isTrue, reason: result.message);
    await _settle();

    // Masked façade, mirror, snapshots, events, Agent tool output.
    expect(await service.get(ConfigKeys.webdavPassword), '***');
    expect(service.debugMirror, isNotEmpty,
        reason: 'the mirror must still hold the non-sensitive value');
    expect(
      service.debugMirror.values.toString(),
      isNot(contains(_secretMarker)),
      reason: 'the Dart mirror must never cache secret plaintext',
    );
    debugPrint(
      'task37 mirror after secret: keys=${service.debugMirror.keys.toList()} '
      'size=${service.debugMirror.length}',
    );

    final snapshot = await service.snapshot(ConfigKeys.webdavPassword);
    expect(snapshot, isNotNull);
    expect(snapshot!.value, '***');
    expect(jsonEncode(snapshot.toJson()), isNot(contains(_secretMarker)));

    final snapshots = await service.snapshots();
    expect(
      jsonEncode(snapshots.map((item) => item.toJson()).toList()),
      isNot(contains(_secretMarker)),
      reason: 'snapshots() must stay masked',
    );

    expect(globalEvents, isNotEmpty);
    expect(keyEvents, isNotEmpty);
    for (final event in <ConfigChangeEvent>[...globalEvents, ...keyEvents]) {
      expect(
        '${event.oldValue}|${event.newValue}',
        isNot(contains(_secretMarker)),
        reason: 'change events must stay masked',
      );
    }

    final tool = AgentService();
    final listOut = await tool.runTool(
      AgentService.configManagerToolName,
      <String, dynamic>{'action': 'list'},
    );
    expect(listOut, isNot(contains(_secretMarker)),
        reason: 'Agent tool output must never contain the secret');

    // Trusted in-app paths keep the raw value.
    expect(await service.getRaw(ConfigKeys.webdavPassword), _secretMarker,
        reason: 'getRaw is the trusted WebDAV path (C3)');
    expect(await store.readString(ConfigKeys.webdavPassword), _secretMarker,
        reason: 'ConfigStore adapter reads raw for the owner');
    final exported = await service.exportRaw();
    final secretEntry = exported
        .firstWhere((entry) => entry.wireKey == ConfigKeys.webdavPassword);
    expect(secretEntry.value, _secretMarker,
        reason: 'the backup export is the one intentional raw artifact');

    await globalSub.cancel();
    await keySub.cancel();
  });

  test('two Dart watchers on one (module,key) both receive every change and '
      'ignore unrelated keys', () async {
    final first = <ConfigChangeEvent>[];
    final second = <ConfigChangeEvent>[];
    final firstSub =
        service.watch(ConfigKeys.downloadMaxConcurrent).listen(first.add);
    final secondSub =
        service.watch(ConfigKeys.downloadMaxConcurrent).listen(second.add);

    await service.set(ConfigKeys.downloadMaxConcurrent, 5,
        source: ConfigChangeSource.user);
    await service.set(ConfigKeys.downloadWifiOnly, true,
        source: ConfigChangeSource.user);
    await service.set(ConfigKeys.downloadMaxConcurrent, 8,
        source: ConfigChangeSource.user);
    await _settle();

    expect(first.map((event) => event.key),
        <String>[ConfigKeys.downloadMaxConcurrent, ConfigKeys.downloadMaxConcurrent]);
    expect(second.map((event) => event.key),
        <String>[ConfigKeys.downloadMaxConcurrent, ConfigKeys.downloadMaxConcurrent]);
    expect(first.map((event) => event.newValue), <Object?>[5, 8]);
    expect(second.map((event) => event.newValue), <Object?>[5, 8],
        reason: 'one failing/slow listener must not starve the other');

    await firstSub.cancel();
    await secondSub.cancel();
  });

  test('all 11 proxy keys and 11 module toggles are registered; unregistered '
      'and legacy keys are rejected', () async {
    expect(_proxyKeys.length, 11);
    expect(_moduleToggles.length, 11);

    for (final key in _proxyKeys) {
      expect(service.has(key), isTrue, reason: '$key must be registered');
      expect(service.entry(key), isNotNull, reason: '$key needs metadata');
    }
    for (final key in _moduleToggles) {
      expect(service.has(key), isTrue, reason: '$key must be registered');
      final entry = service.entry(key);
      expect(entry, isNotNull, reason: '$key needs metadata');
      expect(entry!.defaultValue, isTrue, reason: '$key defaults to enabled');
    }
    expect(
      service.list().where((entry) => entry.key.startsWith('proxy.')).length,
      11,
      reason: 'the proxy namespace must expose exactly the 11 persisted keys',
    );
    expect(
      service
          .list()
          .where((entry) =>
              entry.key.startsWith('module.') &&
              entry.key.endsWith('.enabled'))
          .length,
      11,
      reason: 'the module namespace must expose exactly the 11 toggles',
    );

    for (final key in <String>[
      'proxy.engine_stak',
      'proxy.routing_mod',
      'module.chanel.enabled',
      'module.download.enable',
      'theme_mode',
      'config_proxy_url',
    ]) {
      expect(service.has(key), isFalse, reason: '$key must stay unregistered');
      expect(service.entry(key), isNull);
    }

    // Rejected writes do not throw and do not persist.
    expect(await store.write('proxy.engine_stak', 'system'), isFalse);
    expect(await store.readString('proxy.engine_stak'), isNull);
    final rejected =
        await service.set('proxy.engine_stak', 'system');
    expect(rejected.success, isFalse);

    // A registered key still writes after the scan.
    expect(await store.write(ConfigKeys.proxyEngineStack, 'system'), isTrue);
    expect(await service.getRaw(ConfigKeys.proxyEngineStack), 'system');
  });
}

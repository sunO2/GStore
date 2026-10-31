// Todo 19: agent config call sites use grouped keys + typed JSON (C6) and
// agent tool output is masked for the sensitive `agent.models` key (C3).
//
// Storage is driven through the `ConfigStore.initialize({storages})` test seam
// (C17), which shares one in-memory backend between ConfigStore and
// ConfigService — the same seam the LLM client (`AgentModelStore.load`) and the
// agent tool (`configManager`) use in production.
// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/openai_model_catalog.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';

const String _apiKeyMarker = 'sk-agent-secret-marker-19a7';

class _CountingMemoryStorage extends MemoryConfigStorage {
  int modelWrites = 0;

  @override
  Future<bool> setValue(String key, Object? value) {
    if (key == ConfigKeys.agentModels) modelWrites++;
    return super.setValue(key, value);
  }
}

Map<String, Object?> _modelJson({String id = 'm1', String? apiKey}) {
  return <String, Object?>{
    'id': id,
    'name': '模型$id',
    'provider': 'openai',
    'apiKey': apiKey ?? _apiKeyMarker,
    'model': 'gpt-4o-mini',
    'baseUrl': 'https://api.example.com/v1',
    'toolsEnabled': true,
    'showReasoning': true,
  };
}

/// Encodes [value] as JSON [times] times (1 = normal JSON string).
String _encodeTimes(Object? value, int times) {
  var text = jsonEncode(value);
  for (var i = 1; i < times; i++) {
    text = jsonEncode(text);
  }
  return text;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = ConfigStore.instance;
  final service = ConfigService.instance;

  group('AgentModelStore typed JSON (C6)', () {
    late _CountingMemoryStorage storage;

    setUp(() async {
      storage = _CountingMemoryStorage();
      store.resetForTest();
      await store.initialize(storages: <ConfigStorage>[storage]);
      await service.ensureReady();
    });

    tearDown(() async {
      await service.resetForTest();
      store.resetForTest();
    });

    test('save/load round-trips a typed List<Map> and keeps the raw API key',
        () async {
      final models = await AgentModelStore.load();
      await models.add(AgentModel(
        id: 'm1',
        name: '模型1',
        provider: AgentLlmProvider.openai,
        apiKey: _apiKeyMarker,
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
      ));

      // 1. Stored shape is typed JSON, not a JSON-encoded string.
      final stored = await store.readValue(ConfigKeys.agentModels);
      expect(stored, isA<List>(), reason: 'agent.models must be List<Map>');
      final first = (stored as List).single;
      expect(first, isA<Map>());
      expect((first as Map)['apiKey'], _apiKeyMarker,
          reason: 'raw read must keep the API key for the LLM client');
      expect(await storage.getValue(ConfigKeys.agentModels), isA<List>(),
          reason: 'backend must store typed JSON, not a String');

      // 2. Reload (the LLM client path) sees the raw key and selected model.
      final reloaded = await AgentModelStore.load();
      expect(reloaded.models, hasLength(1));
      expect(reloaded.models.single.apiKey, _apiKeyMarker);
      expect(reloaded.selectedId, 'm1');
    });

    test('legacy double-encoded string is readable without duplicating models',
        () async {
      // 历史 `writeString(jsonEncode(...))` 加一层编码。
      await storage.setString(
        ConfigKeys.agentModels,
        _encodeTimes(<Map<String, Object?>>[_modelJson(apiKey: 'sk-legacy')], 2),
      );

      final first = await AgentModelStore.load();
      expect(first.models, hasLength(1));
      expect(first.models.single.apiKey, 'sk-legacy');

      final second = await AgentModelStore.load();
      expect(second.models, hasLength(1),
          reason: 'reloading a legacy value must not duplicate entries');
      expect(second.models.single.apiKey, 'sk-legacy');
    });

    test('legacy value that arrives as a String is migrated exactly once',
        () async {
      // ConfigStore un-nests up to 3 JSON layers; a legacy value beyond that
      // still reaches the call site as a String and must be migrated there.
      await storage.setString(
        ConfigKeys.agentModels,
        _encodeTimes(<Map<String, Object?>>[_modelJson(apiKey: 'sk-deep')], 4),
      );
      storage.modelWrites = 0;

      final first = await AgentModelStore.load();
      expect(first.models.single.apiKey, 'sk-deep');
      expect(storage.modelWrites, 1, reason: 'legacy value migrated once');
      expect(await store.readValue(ConfigKeys.agentModels), isA<List>(),
          reason: 'migration must write typed List<Map>');

      final second = await AgentModelStore.load();
      expect(second.models.single.apiKey, 'sk-deep');
      expect(storage.modelWrites, 1,
          reason: 'second run must not rewrite the migrated value');
    });

    test('malformed values are ignored and never rewritten', () async {
      await storage.setString(ConfigKeys.agentModels, 'not-json');
      storage.modelWrites = 0;

      final loaded = await AgentModelStore.load();
      expect(loaded.models, isEmpty);

      // Wrong list shape (non-map entries) → skipped.
      await storage.setString(
        ConfigKeys.agentModels,
        jsonEncode(<Object?>[42, 'nope']),
      );
      expect((await AgentModelStore.load()).models, isEmpty);

      // Corrupt entries inside a valid list are skipped individually.
      await storage.setString(
        ConfigKeys.agentModels,
        jsonEncode(<Object?>[
          _modelJson(id: 'ok', apiKey: 'sk-ok'),
          <String, Object?>{'name': 'missing id'},
        ]),
      );
      final mixed = await AgentModelStore.load();
      expect(mixed.models, hasLength(1));
      expect(mixed.models.single.id, 'ok');
    });
  });

  group('openai model catalog typed JSON (C6)', () {
    late _CountingMemoryStorage storage;

    setUp(() async {
      storage = _CountingMemoryStorage();
      store.resetForTest();
      await store.initialize(storages: <ConfigStorage>[storage]);
      await service.ensureReady();
    });

    tearDown(() async {
      await service.resetForTest();
      store.resetForTest();
    });

    test('cacheModelIds writes a typed Map and reads it back', () async {
      await cacheModelIds('https://api.example.com/v1', <String>['a', 'b']);
      final stored = await store.readValue(ConfigKeys.agentModelCatalog);
      expect(stored, isA<Map>(), reason: 'catalog must be typed JSON');
      expect((stored as Map)['https://api.example.com/v1'], <String>['a', 'b']);

      final cache = await loadModelCatalogCache();
      expect(cache['https://api.example.com/v1'], <String>['a', 'b']);
    });

    test('legacy JSON string cache is readable and normalized once', () async {
      await storage.setString(
        ConfigKeys.agentModelCatalog,
        _encodeTimes(<String, Object?>{
          'https://api.example.com/v1': <String>['legacy-model'],
        }, 4),
      );
      final cache = await loadModelCatalogCache();
      expect(cache['https://api.example.com/v1'], <String>['legacy-model']);
      expect(await store.readValue(ConfigKeys.agentModelCatalog), isA<Map>(),
          reason: 'legacy string cache must be migrated to typed Map');

      // Second read sees the migrated typed value.
      final again = await loadModelCatalogCache();
      expect(again['https://api.example.com/v1'], <String>['legacy-model']);
    });

    test('malformed cache returns an empty map and never throws', () async {
      await storage.setString(ConfigKeys.agentModelCatalog, 'not-json');
      expect(await loadModelCatalogCache(), isEmpty);
    });
  });

  group('agent configManager tool output (C3)', () {
    setUp(() async {
      store.resetForTest();
      await store.initialize(storages: <ConfigStorage>[MemoryConfigStorage()]);
      await service.ensureReady();
    });

    tearDown(() async {
      await service.resetForTest();
      store.resetForTest();
    });

    test('list returns grouped keys + Rust descriptions and masks agent.models',
        () async {
      final events = <ConfigChangeEvent>[];
      final sub = service.onChange.listen(events.add);

      final result = await service.set(
        ConfigKeys.agentModels,
        <Map<String, Object?>>[_modelJson()],
        source: ConfigChangeSource.user,
      );
      expect(result.success, isTrue, reason: result.message);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Raw read for the trusted LLM client path.
      final raw = await service.getRaw(ConfigKeys.agentModels);
      expect(raw, isA<List>());
      expect(((raw as List).single as Map)['apiKey'], _apiKeyMarker);
      final clientModels = await AgentModelStore.load();
      expect(clientModels.models.single.apiKey, _apiKeyMarker,
          reason: 'LLM client must receive the raw API key');

      // Masked façade read + no plaintext in the Dart mirror.
      expect(await service.get(ConfigKeys.agentModels), '***');
      expect(service.debugMirror.values.toString(), isNot(contains(_apiKeyMarker)));

      // No plaintext in snapshots.
      final snapshot = await service.snapshot(ConfigKeys.agentModels);
      expect(snapshot, isNotNull);
      expect(snapshot!.value, '***');
      expect(jsonEncode(snapshot.toJson()), isNot(contains(_apiKeyMarker)));

      // No plaintext in change events.
      expect(events, isNotEmpty);
      for (final event in events) {
        expect(
          '${event.oldValue}|${event.newValue}',
          isNot(contains(_apiKeyMarker)),
        );
      }

      // Agent tool `list`: grouped key, Rust zh/en descriptions, masked value.
      final tool = AgentService();
      final listOut = await tool.runTool(
        AgentService.configManagerToolName,
        <String, dynamic>{'action': 'list'},
      );
      final entries = (jsonDecode(listOut) as List).cast<Map<String, dynamic>>();
      final agentEntry =
          entries.firstWhere((e) => e['key'] == ConfigKeys.agentModels);
      expect(agentEntry['value'], '***');
      expect(agentEntry['sensitive'], isTrue);
      expect(agentEntry['description'], contains('Agent 模型列表'));
      expect(agentEntry['descriptionEn'], contains('Agent model list'));
      expect(agentEntry['category'], 'agent');
      expect(listOut, isNot(contains(_apiKeyMarker)),
          reason: 'tool output must never leak the API key');

      // Agent tool `get` cannot read the owner-only secret.
      final getOut = await tool.runTool(
        AgentService.configManagerToolName,
        <String, dynamic>{'action': 'get', 'key': ConfigKeys.agentModels},
      );
      expect(getOut, contains('不允许'));
      expect(getOut, isNot(contains(_apiKeyMarker)));

      await sub.cancel();
    });

    test('set/get/clear keep the tool schema and use grouped keys', () async {
      final tool = AgentService();

      final setOut = await tool.runTool(
        AgentService.configManagerToolName,
        <String, dynamic>{
          'action': 'set',
          'key': ConfigKeys.downloadMaxConcurrent,
          'value': 2,
        },
      );
      final setJson = jsonDecode(setOut) as Map<String, dynamic>;
      expect(setJson['success'], isTrue, reason: setOut);
      expect(setJson['key'], ConfigKeys.downloadMaxConcurrent);
      expect(setJson['value'], 2);
      expect(await service.getRaw(ConfigKeys.downloadMaxConcurrent), 2);

      final getOut = await tool.runTool(
        AgentService.configManagerToolName,
        <String, dynamic>{
          'action': 'get',
          'key': ConfigKeys.downloadMaxConcurrent,
        },
      );
      final getJson = jsonDecode(getOut) as Map<String, dynamic>;
      expect(getJson['key'], ConfigKeys.downloadMaxConcurrent);
      expect(getJson['value'], 2);

      final clearOut = await tool.runTool(
        AgentService.configManagerToolName,
        <String, dynamic>{
          'action': 'clear',
          'key': ConfigKeys.downloadMaxConcurrent,
        },
      );
      expect((jsonDecode(clearOut) as Map<String, dynamic>)['success'], isTrue);

      // Agent-permission denial for the WebDAV password is masked, not echoed.
      await service.set(ConfigKeys.webdavPassword, 'dav-plaintext-marker');
      final secretOut = await tool.runTool(
        AgentService.configManagerToolName,
        <String, dynamic>{'action': 'get', 'key': ConfigKeys.webdavPassword},
      );
      expect(secretOut, isNot(contains('dav-plaintext-marker')));
      expect(secretOut, contains('不允许'));
    });
  });
}

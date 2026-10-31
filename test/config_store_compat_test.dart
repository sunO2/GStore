import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_key_index.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';

/// Todo 16：`ConfigStore` 兼容适配器契约。
///
/// 使用 `initialize({storages})` 的内存 fake 后端（与 17 个存量测试同一条接缝），
/// 验证 raw 读取、C6 JSON 兼容、11 个代理别名、未注册 key 拒绝、过滤 watch、
/// 全局事件映射、敏感标记与迁移。
Future<void> initStore([List<ConfigStorage>? storages]) async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(
    storages: storages ??
        <ConfigStorage>[MemoryConfigStorage(), MemoryConfigStorage()],
  );
  // 水合后为 no-op；保留存量测试的调用习惯。
  ConfigRegistry.registerAll(ConfigService.instance);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = ConfigStore.instance;
  final service = ConfigService.instance;

  setUp(() async {
    await initStore();
  });

  group('initialize({storages}) 兼容接缝', () {
    test('ConfigStore 与 ConfigService 共享同一 fake 存储', () async {
      await store.write(ConfigKeys.themeMode, 2);
      expect(await service.getRaw(ConfigKeys.themeMode), 2);

      await service.set(ConfigKeys.downloadWifiOnly, true);
      expect(await store.readBool(ConfigKeys.downloadWifiOnly), true);

      expect(await store.contains(ConfigKeys.themeMode), true);
      await store.remove(ConfigKeys.themeMode);
      expect(await store.contains(ConfigKeys.themeMode), false);
    });

    test('无参 initialize 幂等：保留已写入数据（仅重建 fake 接线）', () async {
      await store.write(ConfigKeys.themeMode, 1);
      await store.initialize();
      expect(await store.readInt(ConfigKeys.themeMode), 1);
    });

    test('再次传入 storages：重建后端，不泄漏上一个存储的值', () async {
      await store.write(ConfigKeys.themeMode, 2);
      expect(await store.contains(ConfigKeys.themeMode), true);

      await store.initialize(storages: <ConfigStorage>[MemoryConfigStorage()]);

      expect(await store.contains(ConfigKeys.themeMode), false);
      expect(await store.readInt(ConfigKeys.themeMode), 0);
      expect(await service.getRaw(ConfigKeys.themeMode), 0);
    });
  });

  group('未设置 key 与 Rust 默认值一致', () {
    test('getRaw/getT 返回注册默认值（string/int/json）', () async {
      expect(await service.getRaw(ConfigKeys.lastSourceId), '');
      expect(await service.getT<String>(ConfigKeys.lastSourceId), '');
      expect(await service.getRaw(ConfigKeys.proxyEngineMtu), 1500);
      expect(await service.getT<int>(ConfigKeys.proxyEngineMtu), 1500);
      expect(await service.get(ConfigKeys.agentModels), <Object?>[]);
    });
  });

  group('raw 读取与 C6 JSON 兼容', () {
    test('agent.models API key 经 readString/writeString 往返不脱敏', () async {
      const secret = 'sk-super-secret';
      final payload = <Map<String, Object?>>[
        {
          'id': 'm1',
          'name': '模型1',
          'provider': 'openai',
          'apiKey': secret,
          'model': 'gpt-4o-mini',
          'baseUrl': 'https://api.example.com/v1',
        },
      ];

      expect(
        await store.writeString(ConfigKeys.agentModels, jsonEncode(payload)),
        true,
      );

      final raw = await store.readString(ConfigKeys.agentModels);
      expect(raw, isNotNull);
      expect(raw, isNot(contains('***')));
      final decoded = jsonDecode(raw!) as List;
      expect((decoded.first as Map)['apiKey'], secret);

      final typed = await store.readValue(ConfigKeys.agentModels);
      expect(typed, isA<List>());
      expect(((typed as List).first as Map)['apiKey'], secret);

      // 对外脱敏读取仍是 '***'；Dart 镜像不含明文。
      expect(await service.get(ConfigKeys.agentModels), '***');
      expect(service.debugMirror.values.toString(), isNot(contains(secret)));
    });

    test('旧双重编码 JSON 字符串在 readString 时解码一次', () async {
      final storage = MemoryConfigStorage();
      final doubleEncoded = jsonEncode(
        jsonEncode(<Map<String, Object?>>[
          {'id': 'legacy', 'apiKey': 'sk-old'},
        ]),
      );
      await storage.setString(ConfigKeys.agentModels, doubleEncoded);
      await initStore(<ConfigStorage>[storage, MemoryConfigStorage()]);

      final raw = await store.readString(ConfigKeys.agentModels);
      expect(raw, isNotNull);
      expect(jsonDecode(raw!), isA<List>());
      expect((jsonDecode(raw) as List).first['apiKey'], 'sk-old');

      final typed = await store.readValue(ConfigKeys.agentModels);
      expect(typed, isA<List>());
      expect((typed as List).first['apiKey'], 'sk-old');
    });

    test('json 配置写入字符串被强制转换为 typed JSON', () async {
      await store.writeString(
        ConfigKeys.themeConfig,
        '{"fontStyle":3}',
      );
      final value = await store.readValue(ConfigKeys.themeConfig);
      expect(value, isA<Map>());
      expect((value as Map)['fontStyle'], 3);
      expect(await store.readString(ConfigKeys.themeConfig), '{"fontStyle":3}');
    });

    test('非法 JSON 字符串返回 false 而不是抛异常', () async {
      expect(await store.writeString(ConfigKeys.themeConfig, 'not-json'), false);
    });
  });

  group('类型化读写', () {
    test('bool / int / stringList', () async {
      await store.write(ConfigKeys.perfProfilesEnabled, true);
      expect(await store.readBool(ConfigKeys.perfProfilesEnabled), true);
      await store.remove(ConfigKeys.perfProfilesEnabled);
      // 清除后回落到注册默认值 false（QA happy path）。
      expect(await store.readBool(ConfigKeys.perfProfilesEnabled), false);

      await store.write('proxy_engine_mtu', 1400);
      expect(await store.readInt('proxy_engine_mtu'), 1400);
      expect(await store.readInt('proxy.engine_mtu'), 1400);

      await store.write('proxy_split_apps', <String>['com.a', 'com.b']);
      expect(await store.readStringList('proxy_split_apps'), ['com.a', 'com.b']);
      expect(await store.readValue('proxy.split_apps'), ['com.a', 'com.b']);
    });

    test('错误类型读取返回 null（不抛）', () async {
      await store.write('proxy_engine_mtu', 1400);
      expect(await store.readDouble('proxy_engine_mtu'), isNull);
      expect(await store.readBool('proxy_engine_mtu'), isNull);
      expect(await store.readInt('proxy_engine_stack'), isNull);
    });
  });

  group('ConfigKeyIndex：11 个代理别名', () {
    const samples = <String, Object>{
      'proxy_engine_stack': 'system',
      'proxy_engine_mtu': 1400,
      'proxy_routing_mode': 'global',
      'proxy_run_mode': 'lanProxy',
      'proxy_active_node_label': <String, Object>{'group': 'g', 'node': 'n'},
      'proxy_active_profile_id': 'profile-1',
      'proxy_sheet_view_mode': 'grid',
      'proxy_split_mode': 'allow',
      'proxy_split_apps': <String>['com.a'],
      'proxy_always_on_intent': true,
      'proxy_log_level': 'debug',
    };

    test('全部 11 个别名映射到已注册 wire key', () {
      expect(ConfigKeyIndex.proxyAliases.length, 11);
      for (final entry in ConfigKeyIndex.proxyAliases.entries) {
        expect(
          ConfigKeyIndex.resolve(entry.key, isRegistered: service.has),
          entry.value,
          reason: entry.key,
        );
        expect(service.has(entry.value), isTrue, reason: entry.value);
      }
    });

    test('通过别名写入后可用别名与 wire key 读回', () async {
      for (final entry in samples.entries) {
        expect(await store.write(entry.key, entry.value), true, reason: entry.key);
      }
      for (final entry in ConfigKeyIndex.proxyAliases.entries) {
        final expected = samples[entry.key]!;
        final viaAlias = await store.readValue(entry.key);
        final viaWire = await service.getRaw(entry.value);
        expect(viaAlias, expected, reason: entry.key);
        expect(viaWire, expected, reason: entry.value);
      }
    });
  });

  group('未注册 key：记录日志并返回 false/null', () {
    test('write/read/contains 全部拒绝', () async {
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = original);

      expect(await store.write('not_registered_key', true), false);
      expect(await store.readString('not_registered_key'), isNull);
      expect(await store.readValue('not_registered_key'), isNull);
      expect(await store.contains('not_registered_key'), false);
      expect(await store.remove('not_registered_key'), false);

      expect(logs.where((line) => line.contains('未注册')).length, greaterThanOrEqualTo(4));
    });
  });

  group('watch 与 changes', () {
    test('watch(alias) 只收到该 key（Rust/fake 已过滤）', () async {
      final seen = <String>[];
      final sub = store.watch('proxy_log_level').listen((event) => seen.add(event.key));

      await store.write('proxy_log_level', 'debug');
      await store.write('proxy_sheet_view_mode', 'grid');
      await pumpEventQueue();

      expect(seen, [ConfigKeys.proxyLogLevel]);
      await sub.cancel();
    });

    test('changes 映射全局 ConfigChangeEvent → StorageChangeEvent', () async {
      final events = <StorageChangeEvent>[];
      final sub = store.changes.listen(events.add);

      await store.write(ConfigKeys.perfProfilesEnabled, true);
      await pumpEventQueue();

      expect(events, isNotEmpty);
      final event = events.last;
      expect(event.key, ConfigKeys.perfProfilesEnabled);
      expect(event.value, true);
      expect(event.storageType, StorageType.normal);
      await sub.cancel();
    });

    test('敏感项事件不泄露明文', () async {
      const secret = 'sk-event-secret';
      final payload = jsonEncode(<Map<String, Object?>>[
        {'id': 'm1', 'apiKey': secret},
      ]);
      final values = <Object?>[];
      final sub = store.changes.listen((event) => values.add(event.value));

      await store.writeString(ConfigKeys.agentModels, payload);
      await pumpEventQueue();

      expect(values.toString(), isNot(contains(secret)));
      await sub.cancel();
    });
  });

  group('敏感标记与 resetForTest', () {
    test('markSensitive / isSensitive / sensitiveKeys / resetForTest', () async {
      store.markSensitive(ConfigKeys.webdavPassword);
      expect(store.isSensitive(ConfigKeys.webdavPassword), true);
      expect(store.sensitiveKeys, contains(ConfigKeys.webdavPassword));

      store.resetForTest();
      expect(store.isSensitive(ConfigKeys.webdavPassword), false);
      expect(store.sensitiveKeys, isEmpty);

      // 复位后读取应提示未初始化（不静默成功）。
      expect(store.readString(ConfigKeys.themeMode), throwsStateError);
    });
  });

  group('migrate', () {
    test('旧 key → 新 key：写入并删除旧 key', () async {
      await store.writeString('proxy_run_mode', 'off');
      expect(
        await store.migrate('proxy_run_mode', 'proxy_active_profile_id'),
        true,
      );
      expect(await store.readString('proxy_active_profile_id'), 'off');
      expect(await store.contains('proxy_run_mode'), false);
    });

    test('别名与 wire key 解析为同一 wire key 时幂等', () async {
      await store.writeString('proxy_log_level', 'warn');
      expect(
        await store.migrate('proxy_log_level', ConfigKeys.proxyLogLevel),
        true,
      );
      expect(await store.readString('proxy_log_level'), 'warn');
    });
  });
}
